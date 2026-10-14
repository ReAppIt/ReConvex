import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/query_options.dart';
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/server/api.dart';

import '../support/client_node_test_helpers.dart';
import '../support/fakes.dart';

class _RecordingLogger implements ConvexLogger {
  final List<String> warnings = [];

  @override
  void error(String message) {}

  @override
  void log(String message) {}

  @override
  void logVerbose(String message) {}

  @override
  void warn(String message) => warnings.add(message);
}

const _address = 'https://127.0.0.1:3001';

ConvexReactClient _testConvexReactClient({ConvexLogger? logger}) =>
    ConvexReactClient(
      _address,
      ConvexReactClientOptions(
        webSocketConstructor: offlineWebSocketConstructor,
        logger: logger ?? instantiateNoopLogger(),
      ),
    );

void main() {
  final clients = <ConvexReactClient>[];
  ConvexReactClient testClient({ConvexLogger? logger}) {
    final client = _testConvexReactClient(logger: logger);
    clients.add(client);
    return client;
  }

  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
  });

  group('ConvexReactClient', () {
    test('can be constructed', () {
      expect(testClient(), isNotNull);
    });
  });

  group('createMutation', () {
    test('Optimistic updates can be created', () {
      final client = testClient();
      createMutation(anyMutation('myMutation'), client).withOptimisticUpdate((
        _,
        _,
      ) {
        // no update
      });
    });

    test('Specifying an optimistic update twice produces an error', () {
      final client = testClient();
      final mutation = createMutation(
        anyMutation('myMutation'),
        client,
      ).withOptimisticUpdate((_, _) {});
      expect(
        () => mutation.withOptimisticUpdate((_, _) {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Already specified optimistic update for mutation myMutation',
          ),
        ),
      );
    });

    test("Optimistic update handlers can't be async", () {
      final logger = _RecordingLogger();
      final client = testClient(logger: logger);
      final mutation = createMutation(
        anyMutation('myMutation'),
        client,
      ).withOptimisticUpdate((_, _) async {});

      // Calling the mutation should warn
      unawaited(mutation(noArgs).then((_) {}, onError: (_) {}));
      expect(logger.warnings, [
        'Optimistic update handler returned a Promise. Optimistic updates '
            'should be synchronous.',
      ]);
    });
  });

  group('async query fetch', () {
    late ConvexReactClient client;
    setUp(() => client = testClient());

    void optimisticUpdate() {
      // Use an optimistic update to set up a query to have a result.
      unawaited(
        client
            .mutation(
              anyMutation('myMutation'),
              noArgs,
              optimisticUpdate: (localStore, _) {
                localStore.setQuery(anyQuery('myQuery'), noArgs, (
                  value: 'queryResult',
                ));
              },
            )
            .then((_) {}, onError: (_) {}),
      );
    }

    test('returns after optimistic update', () async {
      final queryResult = client.query(anyQuery('myQuery'), noArgs);
      optimisticUpdate();
      expect(await queryResult, 'queryResult');
    });

    test('returns existing result', () async {
      optimisticUpdate();
      final queryResult = client.query(anyQuery('myQuery'), noArgs);
      expect(await queryResult, 'queryResult');
    });

    test('returns a null result instead of waiting', () async {
      unawaited(
        client
            .mutation(
              anyMutation('myMutation'),
              noArgs,
              optimisticUpdate: (localStore, _) {
                localStore.setQuery(anyQuery('myQuery'), noArgs, (value: null));
              },
            )
            .then((_) {}, onError: (_) {}),
      );
      expect(await client.query(anyQuery('myQuery'), noArgs), isNull);
    });
  });

  group('prewarmQuery types', () {
    test('accepts QueryOptions shape', () {
      final client = testClient();
      final opts = convexQueryOptions(
        query: makeFunctionReference<QueryType, Map<String, Object?>, String>(
          'myQuery',
        ),
        args: {'name': 'hi'},
      );
      client.prewarmQuery(opts);
    });

    test('accepts extendSubscriptionFor on prewarmQuery', () {
      final client = testClient();
      client.prewarmQuery(
        QueryOptions(
          query: makeFunctionReference<QueryType, Map<String, Object?>, String>(
            'myQuery',
          ),
          args: {'name': 'hi'},
        ),
        extendSubscriptionFor: const Duration(seconds: 10),
      );
    });
  });

  // Widget tests fail on timers left after the tree is gone.
  group('close', () {
    test('cancels every timer of an offline client', () {
      fakeAsync((async) {
        final client = _testConvexReactClient();
        final unsubscribe = client
            .watchQuery(anyQuery('myQuery'), noArgs)
            .onUpdate(() {});
        async.elapse(const Duration(seconds: 3));
        unsubscribe();
        unawaited(client.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('cancels every timer of a connected client', () {
      fakeAsync((async) {
        final ws = InMemoryWebSocket();
        final client = ConvexReactClient(
          ws.address,
          ConvexReactClientOptions(
            webSocketConstructor: ws.webSocketConstructor,
            logger: instantiateNoopLogger(),
          ),
        );
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});
        async.flushMicrotasks();
        expect(ws.tryReceive()?['type'], 'Connect');
        expect(async.pendingTimers, isNotEmpty);
        unawaited(client.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
