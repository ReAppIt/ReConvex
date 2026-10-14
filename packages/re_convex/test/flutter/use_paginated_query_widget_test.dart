@Tags(['widget'])
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/use_paginated_query.dart';
import 'package:re_convex/src/flutter/use_paginated_query2.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/pagination.dart';
import 'package:re_convex/src/values/value.dart';

import '../support/fakes.dart';

// address is expected not to exist
const _address = 'https://127.0.0.1:30001';

typedef _Query = PaginatedQueryReference<Map<String, Value>, Object?>;

_Query _query(String name) =>
    makeFunctionReference<
      QueryType,
      Map<String, Value>,
      PaginationResult<Object?>
    >(name);

UsePaginatedQueryResult<Object?> _hookBased(
  _Query query,
  Map<String, Value>? args, {
  required int initialNumItems,
  bool skip = false,
}) => usePaginatedQuery(
  query,
  args,
  initialNumItems: initialNumItems,
  skip: skip,
);

UsePaginatedQueryResult<Object?> _clientBased(
  _Query query,
  Map<String, Value>? args, {
  required int initialNumItems,
  bool skip = false,
}) => usePaginatedQuery_experimental(
  query,
  args,
  initialNumItems: initialNumItems,
  skip: skip,
);

/// A watch whose result is always [error].
class _ErrorWatch<T> implements Watch<T> {
  _ErrorWatch(this.error);

  final Error error;

  @override
  void Function() onUpdate(void Function() callback) => () {};

  @override
  ({T value})? localQueryResult() => throw error;

  @override
  List<String>? localQueryLogs() => null;

  @override
  QueryJournal journal() => null;
}

/// Records the watches the hooks create.
class _SpyClient extends ConvexReactClient {
  _SpyClient()
    : super(
        _address,
        ConvexReactClientOptions(
          webSocketConstructor: offlineWebSocketConstructor,
          logger: instantiateNoopLogger(),
        ),
      );

  final List<(String, Map<String, Value>)> watchQueryCalls = [];
  final List<String> watchPaginatedQueryCalls = [];

  /// Every query fails with this, when set.
  Error? queryError;

  @override
  Watch<R> watchQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args, {
    QueryJournal journal,
    String? componentPath,
  }) {
    watchQueryCalls.add((getFunctionName(query), parseArgs(args)));
    final error = queryError;
    if (error != null) {
      return _ErrorWatch<R>(error);
    }
    return super.watchQuery(
      query,
      args,
      journal: journal,
      componentPath: componentPath,
    );
  }

  @override
  PaginatedWatch<Item> watchPaginatedQuery<A, Item>(
    FunctionReference<QueryType, A, Object?> query,
    A args, {
    required int initialNumItems,
    required int id,
    String? componentPath,
  }) {
    watchPaginatedQueryCalls.add(getFunctionName(query));
    return super.watchPaginatedQuery(
      query,
      args,
      initialNumItems: initialNumItems,
      id: id,
      componentPath: componentPath,
    );
  }
}

void main() {
  for (final (version, usePaginatedQuery, resetPaginationId) in [
    ('hook-based logic', _hookBased, resetPaginationId),
    ('client-based logic', _clientBased, resetPaginationId2),
  ]) {
    group('usePaginatedQuery $version', () {
      late _SpyClient client;
      UsePaginatedQueryResult<Object?>? result;

      Future<void> render(
        WidgetTester tester,
        UsePaginatedQueryResult<Object?> Function() hook,
      ) => tester.pumpWidget(
        ConvexProvider(
          client: client,
          child: HookBuilder(
            builder: (context) {
              result = hook();
              return const SizedBox();
            },
          ),
        ),
      );

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await client.close();
      }

      setUp(() {
        client = _SpyClient();
        result = null;
        resetPaginationId();
      });

      testWidgets('Throws an error when initialNumItems is -1', (tester) async {
        await render(
          tester,
          () =>
              usePaginatedQuery(_query('myQuery'), noArgs, initialNumItems: -1),
        );
        expect(
          tester.takeException(),
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            '`options.initialNumItems` must be a positive number. Received '
                '`-1`.',
          ),
        );
        await unmount(tester);
      });

      testWidgets('Positional form continues throwing on errors', (
        tester,
      ) async {
        if (version == 'client-based logic') {
          return;
        }
        client.queryError = StateError('boom-positional');
        await render(
          tester,
          () =>
              usePaginatedQuery(_query('myQuery'), noArgs, initialNumItems: 10),
        );
        expect(
          tester.takeException(),
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'boom-positional',
          ),
        );
        await unmount(tester);
      });

      testWidgets("Returns nothing when args are 'skip'", (tester) async {
        await render(
          tester,
          () => usePaginatedQuery(
            _query('myQuery'),
            null,
            initialNumItems: 10,
            skip: true,
          ),
        );

        expect(client.watchQueryCalls, isEmpty);
        expect(client.watchPaginatedQueryCalls, isEmpty);
        expect(result!.isLoading, isTrue);
        expect(result!.results, isEmpty);
        expect(result!.status, PaginationStatus.loadingFirstPage);
        await unmount(tester);
      });

      testWidgets('Initially returns LoadingFirstPage', (tester) async {
        await render(
          tester,
          () =>
              usePaginatedQuery(_query('myQuery'), noArgs, initialNumItems: 10),
        );

        if (version == 'hook-based logic') {
          final (name, args) = client.watchQueryCalls.first;
          expect(name, 'myQuery');
          expect(args, {
            'paginationOpts': {
              'cursor': null,
              'id': isA<double>(),
              'numItems': 10.0,
            },
          });
        }
        expect(result!.isLoading, isTrue);
        expect(result!.results, isEmpty);
        expect(result!.status, PaginationStatus.loadingFirstPage);
        await unmount(tester);
      });

      testWidgets('Updates to a new query if query name or args change', (
        tester,
      ) async {
        var query = _query('myQuery');
        var args = <String, Value>{};
        Future<void> rerender() => render(
          tester,
          () => usePaginatedQuery(query, args, initialNumItems: 10),
        );
        void expectLastWatch(String name, Map<String, Value> extraArgs) {
          if (version != 'hook-based logic') return;
          final (lastName, lastArgs) = client.watchQueryCalls.last;
          expect(lastName, name);
          expect(lastArgs, {
            'paginationOpts': {
              'cursor': null,
              'id': isA<double>(),
              'numItems': 10.0,
            },
            ...extraArgs,
          });
        }

        // Starts with just the initial query.
        await rerender();
        expectLastWatch('myQuery', {});

        // If we change the query name, we get a new call.
        query = _query('myQuery2');
        await rerender();
        expectLastWatch('myQuery2', {});

        // If we add an arg, it also updates.
        args = {'someArg': 123.0};
        await rerender();
        expectLastWatch('myQuery2', {'someArg': 123.0});

        // An equal new args object creates no new watches.
        final calls = client.watchQueryCalls.length;
        final paginatedCalls = client.watchPaginatedQueryCalls.length;
        args = {'someArg': 123.0};
        await rerender();
        expect(client.watchQueryCalls, hasLength(calls));
        expect(client.watchPaginatedQueryCalls, hasLength(paginatedCalls));
        await unmount(tester);
      });

      group('usePaginatedQuery pages', () {
        final query = _query('myQuery');

        Future<void> mockPage(
          WidgetTester tester,
          Map<String, Value> opts,
          Map<String, Value> retval,
        ) async {
          // The mutation never goes through, so its optimistic update persists.
          unawaited(
            client
                .mutation(
                  anyMutation('myMutation'),
                  noArgs,
                  optimisticUpdate: (localStore, _) {
                    localStore.setQuery(
                      anyQuery('myQuery'),
                      {
                        'paginationOpts': {...opts, 'id': 1.0},
                      },
                      (value: retval),
                    );
                  },
                )
                .then((_) {}, onError: (_) {}),
          );
          await tester.pumpAndSettle();
        }

        testWidgets('loadMore', (tester) async {
          await render(
            tester,
            () => usePaginatedQuery(query, noArgs, initialNumItems: 1),
          );
          expect(result!.status, PaginationStatus.loadingFirstPage);
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': null},
            {
              'page': ['item1'],
              'continueCursor': 'abc',
              'isDone': false,
            },
          );
          expect(result!.status, PaginationStatus.canLoadMore);
          expect(result!.results, ['item1']);
          await mockPage(
            tester,
            {'numItems': 2.0, 'cursor': 'abc'},
            {
              'page': ['item2'],
              'continueCursor': 'def',
              'isDone': true,
            },
          );
          result!.loadMore(2);
          await tester.pumpAndSettle();
          expect(result!.status, PaginationStatus.exhausted);
          expect(result!.results, ['item1', 'item2']);
          await unmount(tester);
        });

        testWidgets('single page updating', (tester) async {
          await render(
            tester,
            () => usePaginatedQuery(query, noArgs, initialNumItems: 1),
          );
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': null},
            {
              'page': ['item1'],
              'continueCursor': 'abc',
              'isDone': true,
            },
          );
          expect(result!.status, PaginationStatus.exhausted);
          expect(result!.results, ['item1']);
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': null},
            {
              'page': ['item2', 'item3'],
              'continueCursor': 'def',
              'isDone': true,
            },
          );
          expect(result!.status, PaginationStatus.exhausted);
          expect(result!.results, ['item2', 'item3']);
          await unmount(tester);
        });

        testWidgets('page split', (tester) async {
          await render(
            tester,
            () => usePaginatedQuery(query, noArgs, initialNumItems: 1),
          );
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': null},
            {
              'page': ['item1', 'item2', 'item3', 'item4'],
              'continueCursor': 'abc',
              'splitCursor': 'mid',
              'isDone': true,
            },
          );
          expect(result!.status, PaginationStatus.exhausted);
          expect(result!.results, ['item1', 'item2', 'item3', 'item4']);
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': null, 'endCursor': 'mid'},
            {
              'page': ['item1S', 'item2S'],
              'continueCursor': 'mid',
              'isDone': false,
            },
          );
          await mockPage(
            tester,
            {'numItems': 1.0, 'cursor': 'mid', 'endCursor': 'abc'},
            {
              'page': ['item3S', 'item4S'],
              'continueCursor': 'abc',
              'isDone': true,
            },
          );
          expect(result!.status, PaginationStatus.exhausted);
          expect(result!.results, ['item1S', 'item2S', 'item3S', 'item4S']);
          await unmount(tester);
        });
      });
    });
  }
}
