import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/paginated_query_client.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' hide Transition;

import '../../support/client_node_test_helpers.dart';
import '../../support/fakes.dart';

const _initialNumItems = 3;
const _id = 1;

({BaseConvexClient client, PaginatedQueryClient paginatedClient}) _clients(
  UpdateQueue q,
  BaseConvexClientOptions options,
  String address,
) {
  final client = BaseConvexClient(
    address,
    (_) {}, // use the paginated client for all transitions
    options,
  );
  late final PaginatedQueryClient paginatedClient;
  paginatedClient = PaginatedQueryClient(
    client,
    (transition) => q.onTransition(client, paginatedClient)([
      for (final t in transition.queries) t.token,
      for (final t in transition.paginatedQueries) t.token,
    ]),
  );
  return (client: client, paginatedClient: paginatedClient);
}

JsonMap _page(
  List<String> page, {
  required String continueCursor,
  bool isDone = false,
  String? splitCursor,
  String? pageStatus,
}) => {
  'page': page,
  'isDone': isDone,
  'continueCursor': continueCursor,
  'splitCursor': splitCursor,
  'pageStatus': pageStatus,
};

void main() {
  group('BaseConvexClient paginated queries with server mocked at ws level', () {
    test('Subscribing and adding a page', () async {
      await withInMemoryWebSocket((ws) async {
        final q = UpdateQueue();
        final (:client, :paginatedClient) = _clients(
          q,
          BaseConvexClientOptions(
            webSocketConstructor: ws.webSocketConstructor,
          ),
          ws.address,
        );

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        final subscribeResult = paginatedClient.subscribe(
          'myQuery',
          {'channel': 'general'},
          initialNumItems: _initialNumItems,
          id: _id,
        );
        expect(subscribeResult.paginatedQueryToken, isNotEmpty);

        // Query for the first page
        final queryMessage = await ws.receive();
        expect(queryMessage['type'], 'ModifyQuerySet');
        final add = (queryMessage['modifications']! as List).single as JsonMap;
        expect(add['type'], 'Add');
        expect(add['udfPath'], 'myQuery:default');

        // Should include pagination options in args
        final args = (add['args']! as List).single! as JsonMap;
        expect(args['channel'], 'general');
        expect((args['paginationOpts']! as JsonMap)['cursor'], isNull);

        PaginatedQueryResult<Object?>? local() =>
            paginatedClient.localQueryResult(
              'myQuery',
              {'channel': 'general'},
              initialNumItems: _initialNumItems,
              id: _id,
            );

        final result1 = local();
        expect(result1?.results, isEmpty);
        expect(result1?.status, PaginationStatus.loadingFirstPage);

        ws.send(
          transition(
            startVersion: stateVersion(ts: 0),
            endVersion: stateVersion(querySet: 1, ts: 100),
            modifications: [
              queryUpdated(
                add['queryId']! as int,
                _page(['a', 'b', 'c'], continueCursor: 'start after c'),
              ),
            ],
          ).json,
        );

        // That send should be enough to kick off a transition if we just wait for it.
        var i = 0;
        await q.awaitPromiseAtIndexWithTimeout(i++);

        final result2 = local();
        expect(result2?.results, ['a', 'b', 'c']);
        expect(result2?.status, PaginationStatus.canLoadMore);

        result2!.loadMore(5);

        // just calling loadMore causes an update: now we're in LoadingMore state.
        final update2 = await q.awaitPromiseAtIndexWithTimeout(i++);
        expect(update2, hasLength(1));
        expect(
          (update2.values.single!.value! as PaginatedQueryResult<Object?>)
              .status,
          PaginationStatus.loadingMore,
        );

        // Query for the second page
        final queryMessage2 = await ws.receive();
        final add2 =
            (queryMessage2['modifications']! as List).single as JsonMap;
        expect(add2['type'], 'Add');
        expect(add2['udfPath'], 'myQuery:default');
        expect((add2['args']! as List).single, {
          'channel': 'general',
          'paginationOpts': {'cursor': 'start after c', 'numItems': 5, 'id': 1},
        });

        final localQueryResult = local();
        expect(localQueryResult?.status, PaginationStatus.loadingMore);
        expect(localQueryResult?.results, ['a', 'b', 'c']);

        ws.send(
          transition(
            startVersion: stateVersion(querySet: 1, ts: 100),
            endVersion: stateVersion(querySet: 2, ts: 200),
            modifications: [
              queryUpdated(
                add2['queryId']! as int,
                _page(['d', 'e', 'f'], continueCursor: 'start after f'),
              ),
            ],
          ).json,
        );

        final update3 = await q.awaitPromiseAtIndexWithTimeout(i++);
        // Both the page query and the paginated query are updated
        expect(update3, hasLength(2));

        // Let's add some elements
        ws.send(
          transition(
            startVersion: stateVersion(querySet: 2, ts: 200),
            endVersion: stateVersion(querySet: 2, ts: 300),
            modifications: [
              queryUpdated(
                add['queryId']! as int,
                _page(
                  ['a', 'b', 'ba', 'bb', 'c'],
                  continueCursor: 'start after c',
                  splitCursor: 'after ba',
                  pageStatus: 'SplitRecommended',
                ),
              ),
            ],
          ).json,
        );
        final update4 = await q.awaitPromiseAtIndexWithTimeout(i++);
        // Both the page query and the paginated query are updated
        expect(update4, hasLength(2));

        final actual = local();
        expect(actual?.results, ['a', 'b', 'ba', 'bb', 'c', 'd', 'e', 'f']);
        expect(actual?.status, PaginationStatus.canLoadMore);

        await client.close();
      });
    });
  });

  group('BaseConvexClient paginated queries without connecting', () {
    test('Page splitting with optimistic updates', () async {
      // A client that can't connect keeps its optimistic updates.
      final q = UpdateQueue();
      final (:client, :paginatedClient) = _clients(
        q,
        const BaseConvexClientOptions(
          webSocketConstructor: offlineWebSocketConstructor,
        ),
        'https://127.0.0.1:3001',
      );

      void mockPage(JsonMap opts, JsonMap retval) {
        // Use an optimistic mutation to set query results
        unawaited(
          client
              .mutation(
                'myMutation',
                {},
                optimisticUpdate: (localStore, _) {
                  localStore.setQuery(
                    anyQuery('myQuery'),
                    {
                      'channel': 'general',
                      'paginationOpts': {...opts, 'id': _id.toDouble()},
                    },
                    (value: retval),
                  );
                },
              )
              .then((_) {}, onError: (_) {}),
        );
      }

      PaginatedQueryResult<Object?>? local() =>
          paginatedClient.localQueryResult(
            'myQuery',
            {'channel': 'general'},
            initialNumItems: _initialNumItems,
            id: _id,
          );

      // Subscribe to a paginated query
      final subscribeResult = paginatedClient.subscribe(
        'myQuery',
        {'channel': 'general'},
        initialNumItems: _initialNumItems,
        id: _id,
      );
      expect(subscribeResult.paginatedQueryToken, isNotEmpty);

      // Initially should be loading
      expect(local()?.status, PaginationStatus.loadingFirstPage);

      // Mock first page - this should trigger a page split due to splitCursor
      mockPage(
        {'numItems': 3.0, 'cursor': null},
        _page(
          ['item1', 'item2', 'item3', 'item4', 'item5'],
          continueCursor: 'after5',
          splitCursor: 'after3',
          pageStatus: 'SplitRecommended',
        ),
      );

      // Wait for the transition to process
      await q.awaitPromiseAtIndexWithTimeout(0);

      // The splitting logic should have been triggered
      var result = local();
      expect(result?.results, ['item1', 'item2', 'item3', 'item4', 'item5']);
      expect(result?.status, PaginationStatus.canLoadMore);

      // Mock the split pages - first half
      mockPage(
        {'numItems': 3.0, 'cursor': null, 'endCursor': 'after3'},
        {
          'page': ['item1S', 'item2S', 'item3S'],
          'continueCursor': 'after3',
          'isDone': false,
        },
      );

      // Mock the split pages - second half
      mockPage(
        {'numItems': 3.0, 'cursor': 'after3', 'endCursor': 'after5'},
        {
          'page': ['item4S', 'item5S'],
          'continueCursor': 'after5',
          'isDone': false,
        },
      );

      await q.awaitPromiseAtIndexWithTimeout(1);
      await q.awaitPromiseAtIndexWithTimeout(2);

      result = local();
      expect(result?.results, [
        'item1S',
        'item2S',
        'item3S',
        'item4S',
        'item5S',
      ]);
      expect(result?.status, PaginationStatus.canLoadMore);

      await client.close();
    });
  });
}
