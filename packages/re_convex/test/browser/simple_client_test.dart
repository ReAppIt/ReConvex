import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/browser.dart';
import 'package:re_convex/server.dart';

import '../support/client_node_test_helpers.dart';
import '../support/fakes.dart';

final apiQueryFunc =
    makeFunctionReference<QueryType, Map<String, Object?>, String>(
      'jeans style',
    );
final apiMutationFunc =
    makeFunctionReference<MutationType, Map<String, Object?>, String>(
      'jeans style',
    );

ConvexClient _client(InMemoryWebSocket ws) => ConvexClient(
  ws.address,
  ConvexClientOptions(webSocketConstructor: ws.webSocketConstructor),
);

void main() {
  test('Subscriptions are deduplicated', () async {
    // The actual implementation of this dedupliation logic is in BaseConvexClient.
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      final unsub1 = client.onUpdate(apiQueryFunc, noArgs, (_) {});
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      // The second subscribe to the same query should not send another query request.
      final unsub2 = client.onUpdate(apiQueryFunc, noArgs, (_) {});
      unsub1();
      unawaited(client.mutation(apiMutationFunc, noArgs).then((_) {}));
      // Receiving a mutation next means no third or fourth ModifyQuerySet.
      expect((await ws.receive())['type'], 'Mutation');

      // Unsubscribing the second time should trigger the unsubscribe.
      unsub2.unsubscribe();
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      await client.close();
    });
  });

  test('Optimistic updates are applied', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      var updateCount = 0;
      var updateValue = '';
      var optimisticUpdateRan = 0;

      // Subscribe to a query, which *does not* immediately trigger an update.
      final unsubscribe = client.onUpdate(apiQueryFunc, noArgs, (value) {
        updateCount++;
        updateValue = value;
      });
      expect((await ws.receive())['type'], 'ModifyQuerySet');
      expect(
        client.client.localQueryResult(getFunctionName(apiQueryFunc)),
        isNull,
      );

      unawaited(
        client
            .mutation(
              apiMutationFunc,
              noArgs,
              optimisticUpdate: (localStore, _) {
                optimisticUpdateRan++;
                localStore.setQuery(apiQueryFunc, noArgs, (
                  value: 'optimisticValue',
                ));
              },
            )
            .then((_) {}),
      );
      expect((await ws.receive())['type'], 'Mutation');

      // The mutation also updates the local cache
      expect(optimisticUpdateRan, 1);
      expect(updateCount, 1);
      expect(updateValue, 'optimisticValue');
      expect(client.client.localQueryResult(getFunctionName(apiQueryFunc)), (
        value: 'optimisticValue',
      ));

      unsubscribe();
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      await client.close();
    });
  });

  // dartvex served one-shot queries from results kept after unsubscribe.
  test('query() after an unsubscribe waits for a fresh result', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      final first = client.query(apiQueryFunc, noArgs);
      final add = await ws.receive();
      ws.send(
        transition(
          startVersion: stateVersion(ts: 0),
          endVersion: stateVersion(querySet: 1, ts: 1),
          modifications: [queryUpdated(0, 'old')],
        ).json,
      );
      expect(await first, 'old');
      expect(add['type'], 'ModifyQuerySet');
      // The one-shot query unsubscribed.
      expect(((await ws.receive())['modifications']! as List).single, {
        'type': 'Remove',
        'queryId': 0,
      });
      ws.send(
        transition(
          startVersion: stateVersion(querySet: 1, ts: 1),
          endVersion: stateVersion(querySet: 2, ts: 2),
          modifications: [
            {'type': 'QueryRemoved', 'queryId': 0},
          ],
        ).json,
      );
      await waitFor(
        () =>
            client.client.localQueryResult(getFunctionName(apiQueryFunc)) ==
            null,
      );

      final second = client.query(apiQueryFunc, noArgs);
      var settled = false;
      unawaited(second.then((_) => settled = true));
      expect((await ws.receive())['type'], 'ModifyQuerySet');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settled, isFalse);

      ws.send(
        transition(
          startVersion: stateVersion(querySet: 2, ts: 2),
          endVersion: stateVersion(querySet: 3, ts: 3),
          modifications: [queryUpdated(1, 'new')],
        ).json,
      );
      expect(await second, 'new');

      await client.close();
    });
  });

  test('onUpdate calls back soon with a result already in memory', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      final values = <String>[];
      client.onUpdate(apiQueryFunc, noArgs, values.add);
      await ws.receive();
      ws.send(
        transition(
          startVersion: stateVersion(ts: 0),
          endVersion: stateVersion(querySet: 1, ts: 1),
          modifications: [queryUpdated(0, 'value')],
        ).json,
      );
      await waitFor(() => values.isNotEmpty);

      final later = <String>[];
      final unsubscribe = client.onUpdate(apiQueryFunc, noArgs, later.add);
      expect(later, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(later, ['value']);
      expect(unsubscribe.getCurrentValue(), (value: 'value'));

      await client.close();
    });
  });

  test('a disabled client never connects', () {
    final client = ConvexClient(
      'https://happy-animal-123.convex.cloud',
      const ConvexClientOptions(disabled: true),
    );
    final unsubscribe = client.onUpdate(apiQueryFunc, noArgs, (_) {});
    expect(unsubscribe.getCurrentValue(), isNull);
    expect(() => client.client, throwsStateError);
    expect(() => client.query(apiQueryFunc, noArgs), throwsStateError);
  });
}
