import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' hide Transition;
import 'package:re_convex/src/browser/sync/protocol.dart'
    as wire
    show Transition;
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/vendor/long.dart';

import '../../support/client_node_test_helpers.dart';
import '../../support/fakes.dart';
import '../../support/jwt.dart';

BaseConvexClient _client(
  InMemoryWebSocket ws, [
  void Function(BaseConvexClient client, List<QueryToken> tokens)? onTransition,
]) {
  late final BaseConvexClient client;
  client = BaseConvexClient(
    ws.address,
    (tokens) => onTransition?.call(client, tokens),
    BaseConvexClientOptions(
      webSocketConstructor: ws.webSocketConstructor,
      verbose: true,
    ),
  );
  return client;
}

JsonMap _transition(
  ({int querySet, int identity, int ts}) start,
  ({int querySet, int identity, int ts}) end, [
  List<JsonMap> modifications = const [],
]) => transition(
  startVersion: stateVersion(
    querySet: start.querySet,
    identity: start.identity,
    ts: start.ts,
  ),
  endVersion: stateVersion(
    querySet: end.querySet,
    identity: end.identity,
    ts: end.ts,
  ),
  modifications: modifications,
).json;

JsonMap _actionSuccess(int requestId) => {
  'type': 'ActionResponse',
  'requestId': requestId,
  'success': true,
  'result': 42,
  'logLines': <String>[],
};

void main() {
  test('BaseConvexClient protocol in node', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);

      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');
      // The server checks the npm client version in the path.
      expect(
        ws.connectedUris.single.toString(),
        'ws://127.0.0.1:3210/api/1.46.0/sync',
      );

      await client.close();
    });
  });

  // Upstream checks the process exits; here no timer may be left behind.
  test('BaseConvexClient closes cleanly', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final client = _client(ws);
      async.flushMicrotasks();
      expect(ws.socket(), isNotNull);

      var closed = false;
      unawaited(client.close().then((_) => closed = true));
      async.flushMicrotasks();

      expect(closed, isTrue);
      expect(ws.socket()!.closedByClient, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('Tests can encode longs in server messages', () {
    final orig = _transition(
      (querySet: 0, identity: 0, ts: 0),
      (querySet: 1, identity: 0, ts: 1),
      [
        {
          'type': 'QueryUpdated',
          'queryId': 0,
          'value': 0.0,
          'logLines': ["[LOG] 'Got stuff'"],
          'journal': null,
        },
      ],
    );
    final decoded = wire.Transition(
      parseServerMessage(jsonDecode(jsonEncode(orig)) as JsonMap).json,
    );
    expect(decoded.json, orig);
    expect(decoded.endVersion.ts, Long.fromNumber(1));
  });

  // Actions sent before the WebSocket connects must not fail on connect.
  test('Actions can be called immediately', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      final actionP = client.action('myAction', {});

      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');
      final actionRequest = await ws.receive();
      expect(actionRequest['type'], 'Action');
      final requestId = actionRequest['requestId']! as int;

      ws.send(_actionSuccess(requestId));
      expect(await actionP, 42);
      await client.close();
    });
  });

  test('maxObservedTimestamp is updated on mutation and transition', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);

      expect(client.getMaxObservedTimestamp(), isNull);

      final mutationP = client.mutation('myMutation', {});

      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');
      final mutationRequest = await ws.receive();
      expect(mutationRequest['type'], 'Mutation');
      final requestId = mutationRequest['requestId']! as int;

      // Send a mutation, should update the max observed timestamp.
      ws.send(mutationSuccess(requestId, result: 42, ts: 1000));
      await waitFor(() => client.getMaxObservedTimestamp() != null);
      expect(client.getMaxObservedTimestamp(), Long.fromNumber(1000));

      // A transition from before the mutation doesn't resolve it.
      ws.send(
        _transition(
          (querySet: 0, identity: 0, ts: 0),
          (querySet: 0, identity: 0, ts: 500),
        ),
      );

      // Wait a bit and confirm the max timestamp has not been updated.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(client.getMaxObservedTimestamp(), Long.fromNumber(1000));

      // A later transition resolves it and advances the max timestamp.
      ws.send(
        _transition(
          (querySet: 0, identity: 0, ts: 500),
          (querySet: 0, identity: 0, ts: 2000),
        ),
      );
      // Wait until the mutation is resolved.
      expect(await mutationP, 42);
      expect(client.getMaxObservedTimestamp(), Long.fromNumber(2000));

      await client.close();
    });
  });

  // Regression: optimistic a and b, then a server update for a only.
  test(
    'Setting optimistic updates for queries that have not yet been subscribed to',
    () async {
      await withInMemoryWebSocket((ws) async {
        final q = UpdateQueue(10);
        final client = _client(
          ws,
          (client, tokens) => q.onTransition(client)(tokens),
        );

        client.subscribe('queries:a', {});

        expect((await ws.receive())['type'], 'Connect');
        final modify = await ws.receive();

        expect(modify['type'], 'ModifyQuerySet');
        expect(modify['modifications'], [
          {
            'type': 'Add',
            'queryId': 0,
            'udfPath': 'queries:a',
            'args': [<String, Object?>{}],
          },
        ]);

        // Subscribed to queries:a, run a mutation changing q1 and q2.
        final mutP = client.mutation(
          'mutations:z',
          {},
          optimisticUpdate: (localStore, _) {
            final curA = localStore.getQuery(anyQuery('queries:a'), noArgs);
            localStore.setQuery(anyQuery('queries:a'), noArgs, (
              value: curA == null
                  ? 'a local'
                  : '${curA.value} with a local applied',
            ));
            final curB = localStore.getQuery(anyQuery('queries:b'), noArgs);
            localStore.setQuery(anyQuery('queries:b'), noArgs, (
              value: curB == null
                  ? 'b local'
                  : '${curB.value} with b local applied',
            ));
          },
        );

        // Synchronously, the local store should update and the changes should be broadcast.
        expect(client.localQueryResult('queries:a', {}), (value: 'a local'));
        // We haven't actually subscribed to this query but it had a value set in an optimistic update.
        expect(client.localQueryResult('queries:b', {}), (value: 'b local'));
        final update1 = await q.updatePromise(0);
        expect(q.updates, hasLength(1));
        expect(update1, {
          token('queries:a'): (value: 'a local'),
          token('queries:b'): (value: 'b local'),
        });

        // A transition with only query a; this used to crash.
        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 100),
            [queryUpdated(0, 'a server')],
          ),
        );

        final update2 = await q.updatePromise(1);
        expect(update2, {
          token('queries:a'): (value: 'a server with a local applied'),
          token('queries:b'): (value: 'b local'),
        });
        expect(q.allResults, {
          token('queries:a'): (value: 'a server with a local applied'),
          token('queries:b'): (value: 'b local'),
        });
        expect(q.updates, hasLength(2));

        final mutationRequest = await ws.receive();
        expect(mutationRequest, {
          'type': 'Mutation',
          'requestId': 0,
          'udfPath': 'mutations:z',
          'args': [<String, Object?>{}],
        });

        // Now the server sends: 1. the MutationResponse
        ws
          ..send(mutationSuccess(0, ts: 200))
          // 2. Transition bringing us up to date with the mutation
          ..send(
            _transition(
              (querySet: 1, identity: 0, ts: 100),
              (querySet: 1, identity: 0, ts: 200),
              [queryUpdated(0, 'a server')],
            ),
          );

        // No optimistic b anymore, so it isn't reported.
        expect(await q.updatePromise(2), {
          token('queries:a'): (value: 'a server'),
        });

        // After all that the mutation should resolve.
        await mutP;

        await client.close();
      });
    },
  );

  // Regression: slow query a, fast query b, an update for b without a.
  test(
    'Query results coming back out of order (fast query first, slower query later)',
    () async {
      await withInMemoryWebSocket((ws) async {
        final q = UpdateQueue(10);
        final client = _client(
          ws,
          (client, tokens) => q.onTransition(client)(tokens),
        );

        client.subscribe('queries:slow', {});

        expect((await ws.receive())['type'], 'Connect');
        final modify = await ws.receive();
        expect(modify['type'], 'ModifyQuerySet');
        expect(modify['modifications'], [
          {
            'type': 'Add',
            'queryId': 0,
            'udfPath': 'queries:slow',
            'args': [<String, Object?>{}],
          },
        ]);

        // Later we subscribe to a fast query
        client.subscribe('queries:fast', {});

        final modify2 = await ws.receive();
        expect(modify2['type'], 'ModifyQuerySet');
        expect(modify2['modifications'], [
          {
            'type': 'Add',
            'queryId': 1,
            'udfPath': 'queries:fast',
            'args': [<String, Object?>{}],
          },
        ]);

        // The server may acknowledge the slow query without a value.
        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 100),
          ),
        );

        // apparently this triggers an update???
        final update1 = await q.awaitPromiseAtIndexWithTimeout(0);
        expect(update1, isEmpty);

        // Later the server sends a fast result
        ws.send(
          _transition(
            (querySet: 1, identity: 0, ts: 100),
            (querySet: 2, identity: 0, ts: 200),
            [queryUpdated(1, 'fast result')],
          ),
        );
        final update2 = await q.awaitPromiseAtIndexWithTimeout(1);

        expect(update2, {token('queries:fast'): (value: 'fast result')});
        expect(q.allResults, {token('queries:fast'): (value: 'fast result')});
        expect(q.updates, hasLength(2));

        expect(client.localQueryResult('queries:fast', {}), (
          value: 'fast result',
        ));
        expect(client.localQueryResult('queries:slow', {}), isNull);

        // Later the server sends a slow result
        ws.send(
          _transition(
            (querySet: 2, identity: 0, ts: 200),
            (querySet: 2, identity: 0, ts: 300),
            [queryUpdated(0, 'slow result')],
          ),
        );
        final update3 = await q.awaitPromiseAtIndexWithTimeout(2);

        expect(update3, {token('queries:slow'): (value: 'slow result')});
        expect(q.allResults, {
          token('queries:fast'): (value: 'fast result'),
          token('queries:slow'): (value: 'slow result'),
        });
        expect(q.updates, hasLength(3));

        expect(client.localQueryResult('queries:fast', {}), (
          value: 'fast result',
        ));
        expect(client.localQueryResult('queries:slow', {}), (
          value: 'slow result',
        ));

        await client.close();
      });
    },
  );

  // A protocol error that happens to work: a result from a later query set.
  test(
    'Transition contains result for query not in purported query set version',
    () async {
      await withInMemoryWebSocket((ws) async {
        final q = UpdateQueue(10);
        final client = _client(
          ws,
          (client, tokens) => q.onTransition(client)(tokens),
        );

        // Subscribe to slow query first
        client.subscribe('queries:slow', {});

        expect((await ws.receive())['type'], 'Connect');
        final modify1 = await ws.receive();
        expect(modify1['modifications'], [
          {
            'type': 'Add',
            'queryId': 0,
            'udfPath': 'queries:slow',
            'args': [<String, Object?>{}],
          },
        ]);

        // Then subscribe to fast query
        client.subscribe('queries:fast', {});

        final modify2 = await ws.receive();
        expect(modify2['modifications'], [
          {
            'type': 'Add',
            'queryId': 1,
            'udfPath': 'queries:fast',
            'args': [<String, Object?>{}],
          },
        ]);

        // Malformed: query set 1 with the result of queryId 1, from set 2.
        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 100),
            [queryUpdated(1, 'fast result from malformed transition')],
          ),
        );

        // Client should still process the result (the client is forgiving)
        final update1 = await q.awaitPromiseAtIndexWithTimeout(0);
        expect(update1, {
          token('queries:fast'): (
            value: 'fast result from malformed transition',
          ),
        });

        // The fast query result should be available
        expect(client.localQueryResult('queries:fast', {}), (
          value: 'fast result from malformed transition',
        ));
        expect(client.localQueryResult('queries:slow', {}), isNull);

        // Next transition should work normally
        ws.send(
          _transition(
            (querySet: 1, identity: 0, ts: 100),
            (querySet: 2, identity: 0, ts: 200),
            [queryUpdated(0, 'slow result')],
          ),
        );

        final update2 = await q.awaitPromiseAtIndexWithTimeout(1);
        expect(update2, {token('queries:slow'): (value: 'slow result')});

        // Both results should be available and the fast query result should persist
        expect(client.localQueryResult('queries:fast', {}), (
          value: 'fast result from malformed transition',
        ));
        expect(client.localQueryResult('queries:slow', {}), (
          value: 'slow result',
        ));

        await client.close();
      });
    },
  );

  // After QueryRemoved, the client drops the query; listeners aren't told.
  test('Query unsubscription triggers empty transition for listeners', () async {
    await withInMemoryWebSocket((ws) async {
      final q = UpdateQueue(10);
      final client = _client(
        ws,
        (client, tokens) => q.onTransition(client)(tokens),
      );

      client.subscribe('queries:test', {});

      expect((await ws.receive())['type'], 'Connect');
      final modify1 = await ws.receive();
      expect(modify1['modifications'], [
        {
          'type': 'Add',
          'queryId': 0,
          'udfPath': 'queries:test',
          'args': [<String, Object?>{}],
        },
      ]);

      // Server sends result for the query
      ws.send(
        _transition(
          (querySet: 0, identity: 0, ts: 0),
          (querySet: 1, identity: 0, ts: 100),
          [queryUpdated(0, 'test result')],
        ),
      );

      final update1 = await q.awaitPromiseAtIndexWithTimeout(0);
      expect(update1, {token('queries:test'): (value: 'test result')});
      expect(q.allResults, {token('queries:test'): (value: 'test result')});
      expect(client.localQueryResult('queries:test', {}), (
        value: 'test result',
      ));

      // "QueryRemoved" from the server communicates that this query is now in an loading state.
      ws.send(
        _transition(
          (querySet: 1, identity: 0, ts: 100),
          (querySet: 1, identity: 0, ts: 200),
          [
            {'type': 'QueryRemoved', 'queryId': 0},
          ],
        ),
      );

      // The update is empty: nothing says it went back to undefined!
      final update2 = await q.awaitPromiseAtIndexWithTimeout(1);
      expect(update2, isEmpty);

      expect(q.updates, hasLength(2));

      // The query result is no longer available locally after removal...
      expect(client.localQueryResult('queries:test', {}), isNull);

      // ...but anyone listening won't have been updated.
      expect(q.allResults, {token('queries:test'): (value: 'test result')});

      // What if we set a result again?
      ws.send(
        _transition(
          (querySet: 1, identity: 0, ts: 200),
          (querySet: 1, identity: 0, ts: 300),
          [queryUpdated(0, 'new test result')],
        ),
      );
      // Checked before the client processes the message, as upstream does.
      expect(q.updates, hasLength(2));

      // This result is no longer tracked!
      expect(client.localQueryResult('queries:test', {}), isNull);

      await client.close();
    });
  });

  test('TransitionChunk messages are assembled into a Transition', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      final fullTransition = _transition(
        (querySet: 0, identity: 0, ts: 0),
        (querySet: 1, identity: 0, ts: 1000),
        [
          queryUpdated(0, {'result': 'chunk test data'}),
        ],
      );

      final fullJson = jsonEncode(fullTransition);
      final midpoint = fullJson.length ~/ 2;
      final chunk1 = fullJson.substring(0, midpoint);
      final chunk2 = fullJson.substring(midpoint);

      const transitionId = '12345';

      ws.send({
        'type': 'TransitionChunk',
        'chunk': chunk1,
        'partNumber': 0,
        'totalParts': 2,
        'transitionId': transitionId,
      });

      expect(client.getMaxObservedTimestamp(), isNull);

      ws.send({
        'type': 'TransitionChunk',
        'chunk': chunk2,
        'partNumber': 1,
        'totalParts': 2,
        'transitionId': transitionId,
      });

      // synchronously, it's still undefined
      expect(client.getMaxObservedTimestamp(), isNull);

      await waitFor(() => client.getMaxObservedTimestamp() != null);

      expect(client.getMaxObservedTimestamp(), Long.fromNumber(1000));

      await client.close();
    });
  });

  test(
    'Backoff does not reset when queries synced but mutation is still inflight',
    () async {
      await withInMemoryWebSocket((ws) async {
        final client = _client(ws);

        client.subscribe('queries:myQuery', {});

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 100),
            [queryUpdated(0, 'result')],
          ),
        );

        await waitFor(
          () =>
              client.localQueryResult('queries:myQuery', {})?.value == 'result',
        );
        expect(client.connectionState().connectionRetries, 0);

        // Start a mutation, then server closes while it's inflight
        final mutP = client.mutation('myMutation', {});
        final mutReq = await ws.receive();
        expect(mutReq['type'], 'Mutation');
        final requestId = mutReq['requestId']! as int;

        ws.close();

        expect((await ws.receive())['type'], 'Connect');
        expect(client.connectionState().connectionRetries, greaterThan(0));
        expect((await ws.receive())['type'], 'ModifyQuerySet');
        expect((await ws.receive())['type'], 'Mutation');

        // Server sends query results but NOT mutation response
        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 200),
            [queryUpdated(0, 'result 2')],
          ),
        );

        await waitFor(
          () =>
              client.localQueryResult('queries:myQuery', {})?.value ==
              'result 2',
        );

        // Retries should NOT reset — mutation is still inflight
        expect(client.connectionState().connectionRetries, greaterThan(0));

        // Now complete the mutation
        ws
          ..send(mutationSuccess(requestId, ts: 300))
          ..send(
            _transition(
              (querySet: 1, identity: 0, ts: 200),
              (querySet: 1, identity: 0, ts: 400),
            ),
          );

        await mutP;

        // Both queries and mutations synced — retries should reset
        expect(client.connectionState().connectionRetries, 0);

        await client.close();
      });
    },
  );

  test(
    'Backoff does not reset for idle client until server re-confirms queries',
    () async {
      await withInMemoryWebSocket((ws) async {
        final client = _client(ws);

        client.subscribe('queries:myQuery', {});

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 100),
            [queryUpdated(0, 'result')],
          ),
        );

        await waitFor(
          () =>
              client.localQueryResult('queries:myQuery', {})?.value == 'result',
        );
        expect(client.connectionState().connectionRetries, 0);

        // Server closes (idle client, no mutations in flight)
        ws.close();

        expect((await ws.receive())['type'], 'Connect');
        expect(client.connectionState().connectionRetries, greaterThan(0));
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        // Empty transition — query not re-confirmed yet, retries should hold
        ws.send(
          _transition(
            (querySet: 0, identity: 0, ts: 0),
            (querySet: 1, identity: 0, ts: 150),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(client.connectionState().connectionRetries, greaterThan(0));

        // Server re-confirms the query
        ws.send(
          _transition(
            (querySet: 1, identity: 0, ts: 150),
            (querySet: 1, identity: 0, ts: 200),
            [queryUpdated(0, 'result refreshed')],
          ),
        );

        await waitFor(
          () =>
              client.localQueryResult('queries:myQuery', {})?.value ==
              'result refreshed',
        );

        // Query re-confirmed — retries should reset
        expect(client.connectionState().connectionRetries, 0);

        await client.close();
      });
    },
  );

  // An authenticated client used to never reset its retry count.
  test("Retries do not increase across connections for auth'd clients", () async {
    await withInMemoryWebSocket((ws) async {
      final client = _client(ws);

      // Setup auth
      final iat = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final exp = iat + 3600;
      final token = jwtEncode({'sub': 'user_123', 'exp': exp, 'iat': iat});
      client.setAuth(({required forceRefreshToken}) async => token, (_) {});

      // Verify client handshake on "server" side.
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'Authenticate');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      // Respond to the handshake noting that the identity was accepted (increased version).
      ws.send(
        _transition(
          (querySet: 0, identity: 0, ts: 0),
          (querySet: 0, identity: 1, ts: 100),
        ),
      );

      // Subscribe to a query and verify the "server" receives it.
      client.subscribe('queries:myQuery', {});
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      // Respond to the subscription with a result.
      ws.send(
        _transition(
          (querySet: 0, identity: 1, ts: 100),
          (querySet: 1, identity: 1, ts: 200),
          [queryUpdated(0, 'result')],
        ),
      );

      // Verify the client gets the subscription result.
      await waitFor(
        () => client.localQueryResult('queries:myQuery', {})?.value == 'result',
      );
      expect(client.localQueryResult('queries:myQuery', {}), (value: 'result'));

      // Unceremoniously drop the connection.
      ws.close();

      // The "server" should see the client handshake for a reconnect.
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['type'], 'Authenticate');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      // The client should record that it has begun a retry.
      expect(client.connectionState().connectionRetries, 1);

      // Respond to the handshake noting that the identity was accepted (increased version).
      ws.send(
        _transition(
          (querySet: 0, identity: 0, ts: 0),
          (querySet: 0, identity: 1, ts: 100),
        ),
      );
      // Let client handle the transition.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Respond to the re-subscription with a result.
      ws.send(
        _transition(
          (querySet: 0, identity: 1, ts: 100),
          (querySet: 1, identity: 1, ts: 200),
          [queryUpdated(0, 'updated result')],
        ),
      );

      await waitFor(
        () =>
            client.localQueryResult('queries:myQuery', {})?.value ==
            'updated result',
      );
      // Verify the client gets the subscription result.
      expect(client.localQueryResult('queries:myQuery', {}), (
        value: 'updated result',
      ));

      // Client has resynced - should be at 0 retries
      expect(client.connectionState().connectionRetries, 0);

      await client.close();
    });
  });
}
