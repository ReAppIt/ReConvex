import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show JsonMap;
import 'package:re_convex/src/flutter/client.dart';

import '../support/client_node_test_helpers.dart';
import '../support/fakes.dart';
import '../support/jwt.dart';

class _RecordingLogger implements ConvexLogger {
  final List<String> errors = [];

  @override
  void error(String message) => errors.add(message);

  @override
  void log(String message) {}

  @override
  void logVerbose(String message) {}

  @override
  void warn(String message) {}
}

ConvexReactClient _testReactClient(
  InMemoryWebSocket ws, {
  bool expectAuth = false,
  ConvexLogger? logger,
  Duration authRefreshTokenLeeway = const Duration(seconds: 10),
}) => ConvexReactClient(
  ws.address,
  ConvexReactClientOptions(
    webSocketConstructor: ws.webSocketConstructor,
    expectAuth: expectAuth,
    logger: logger,
    authRefreshTokenLeeway: authRefreshTokenLeeway,
  ),
);

class _TokenFetcher {
  _TokenFetcher(this._fetch);

  final Future<String?> Function(bool forceRefreshToken) _fetch;
  final List<bool> calls = [];

  Future<String?> call({required bool forceRefreshToken}) {
    calls.add(forceRefreshToken);
    return _fetch(forceRefreshToken);
  }
}

void _assertAuthenticateMessage(
  JsonMap message, {
  required int baseVersion,
  required String token,
}) {
  expect(message['type'], 'Authenticate');
  expect(message['baseVersion'], baseVersion);
  expect(message['tokenType'], 'User');
  expect(message['value'], token);
}

Future<void> _assertReconnectWithAuth(
  InMemoryWebSocket ws, {
  required int baseVersion,
  required String token,
}) async {
  expect((await ws.receive())['type'], 'Connect');
  _assertAuthenticateMessage(
    await ws.receive(),
    baseVersion: baseVersion,
    token: token,
  );
  expect((await ws.receive())['type'], 'ModifyQuerySet');
}

void _simulateAuthError(
  InMemoryWebSocket ws, {
  required String error,
  required int baseVersion,
  required bool authUpdateAttempted,
}) {
  ws
    ..send({
      'type': 'AuthError',
      'error': error,
      'baseVersion': baseVersion,
      'authUpdateAttempted': authUpdateAttempted,
    })
    // The server always closes the connection after an AuthError
    ..close();
}

// The server's version right after a (re)connect, before any transition.
JsonMap _identityTransition(int from, int to) => transition(
  startVersion: stateVersion(identity: from, ts: 0),
  endVersion: stateVersion(identity: to, ts: 0),
).json;

int _nowSeconds() => (DateTime.now().millisecondsSinceEpoch / 1000).ceil();

void main() {
  group('auth websocket tests', () {
    // The usual page load after signing in, with a constant token provider.
    test('Authenticate via valid static token', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        final tokenFetcher = _TokenFetcher(
          (_) async => jwtEncode({'iat': 1234500, 'exp': 1244500}),
        );
        final onAuthChange = <bool>[];
        client.setAuth(tokenFetcher.call, onAuthChange.add);

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'Authenticate');
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        // Client started at 0; the good token advanced to 1.
        ws.send(_identityTransition(0, 1));

        await waitFor(() => onAuthChange.isNotEmpty);
        await client.close();

        expect(tokenFetcher.calls.first, isFalse);
        expect(onAuthChange, [true]);
      });
    });

    // A user opens a page after their cached token expired.
    test('Reauthenticate after token expiration with versioning', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        var token = jwtEncode({'iat': 1234500, 'exp': 1244500, 'n': 1});
        final tokenFetcher = _TokenFetcher((_) async => token);
        final onAuthChange = <bool>[];
        client.setAuth(tokenFetcher.call, onAuthChange.add);

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: token);

        // Token must change, otherwise client will not try to reauthenticate
        token = jwtEncode({'iat': 1234500, 'exp': 1244500, 'n': 2});

        _simulateAuthError(
          ws,
          error: 'bla',
          baseVersion: 0,
          authUpdateAttempted: true,
        );

        // The client reconnects automatically
        await _assertReconnectWithAuth(ws, baseVersion: 0, token: token);

        // Server accepts new token
        ws.send(_identityTransition(0, 1));

        await waitFor(() => onAuthChange.isNotEmpty);
        await client.close();

        expect(tokenFetcher.calls.take(2), [false, true]);
        expect(onAuthChange, contains(true));
      });
    });

    // A page opened without a cached token (e.g. tracking prevention).
    test('Reauthenticate after token cache failure', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        final freshToken = jwtEncode({'iat': 1234500, 'exp': 1244500});
        final tokenFetcher = _TokenFetcher(
          (forceRefreshToken) async => forceRefreshToken ? freshToken : null,
        );
        final onAuthChange = <bool>[];
        client.setAuth(tokenFetcher.call, onAuthChange.add);

        // The client authenticates after the token refetch
        await _assertReconnectWithAuth(ws, baseVersion: 0, token: freshToken);

        // Server accepts new token
        ws.send(_identityTransition(0, 1));

        await waitFor(() => onAuthChange.isNotEmpty);
        await client.close();

        expect(tokenFetcher.calls.take(2), [false, true]);
        expect(onAuthChange, contains(true));
      });
    });

    // Usually a misconfigured server rejecting any token.
    test('Fail when tokens are always rejected', () async {
      await withInMemoryWebSocket((ws) async {
        final logger = _RecordingLogger();
        final client = _testReactClient(ws, logger: logger);

        final tokens = [
          for (var i = 1; i <= 4; i++)
            jwtEncode({'iat': 1234500, 'exp': 1244500, 'n': i}),
        ];
        final remaining = [...tokens];

        final tokenFetcher = _TokenFetcher(
          (_) async => remaining.isEmpty ? null : remaining.removeAt(0),
        );
        final onAuthChange = <bool>[];
        client.setAuth(tokenFetcher.call, onAuthChange.add);

        expect((await ws.receive())['type'], 'Connect');
        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 0,
          token: tokens[0],
        );
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        _simulateAuthError(
          ws,
          error: 'bla',
          baseVersion: 0,
          authUpdateAttempted: true,
        );

        // The client reconnects automatically and retries twice
        const authErrorMessage = 'bada boom';
        for (final token in tokens.skip(1)) {
          expect((await ws.receive())['type'], 'Connect');
          _assertAuthenticateMessage(
            await ws.receive(),
            baseVersion: 0,
            token: token,
          );
          expect((await ws.receive())['type'], 'ModifyQuerySet');

          _simulateAuthError(
            ws,
            error: authErrorMessage,
            baseVersion: 0,
            authUpdateAttempted: true,
          );
        }

        // The client reconnects automatically (but without auth)
        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'ModifyQuerySet');
        await client.close();

        expect(onAuthChange, [false]);
        expect(
          logger.errors,
          contains(
            'Failed to authenticate: "$authErrorMessage", check your server '
            'auth config',
          ),
        );
      });
    });

    // Expired refresh tokens: signed in, but no token can be fetched.
    test('Fail when tokens cannot be fetched', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);
        final tokenFetcher = _TokenFetcher((_) async => null);
        final onAuthChange = <bool>[];
        client.setAuth(tokenFetcher.call, onAuthChange.add);

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'ModifyQuerySet');

        await waitFor(() => onAuthChange.isNotEmpty);
        await client.close();

        expect(onAuthChange, [false]);
      });
    });

    test('Client is protected against token rejection race', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        final badToken = jwtEncode({'iat': 1234500, 'exp': 1244500, 'n': 1});
        final firstOnChange = <bool>[];
        client.setAuth(
          ({required forceRefreshToken}) async => badToken,
          firstOnChange.add,
        );

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: badToken);

        final goodToken = jwtEncode({'iat': 1234500, 'exp': 1244500, 'n': 2});
        final secondOnChange = <bool>[];
        client.setAuth(
          ({required forceRefreshToken}) async => goodToken,
          secondOnChange.add,
        );

        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 1,
          token: goodToken,
        );

        // The server's AuthError sequence: a message, then a close.
        _simulateAuthError(
          ws,
          error: 'bla',
          baseVersion: 0,
          authUpdateAttempted: true,
        );

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: goodToken);

        // Client started at 0 after reconnect; good token advanced to 1.
        ws.send(_identityTransition(0, 1));

        await waitFor(() => secondOnChange.isNotEmpty);
        await client.close();

        expect(firstOnChange, isEmpty);
        expect(secondOnChange, [true]);
      });
    });

    // A late non-auth error arrives while a new token awaits validation.
    test('Client ignores non-auth responses for token validation', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);
        final ts = _nowSeconds();
        final initialToken = jwtEncode({'iat': ts, 'exp': ts + 1000, 'n': 1});
        final freshToken = jwtEncode({'iat': ts, 'exp': ts + 1000, 'n': 2});
        final tokens = [initialToken, freshToken];
        final onChange = <bool>[];
        // Sends `initialToken` at once (as if cached), then `freshToken`.
        client.setAuth(
          ({required forceRefreshToken}) async => tokens.removeAt(0),
          onChange.add,
        );

        // Messages for initial connection + handling `initialToken`
        await _assertReconnectWithAuth(ws, baseVersion: 0, token: initialToken);

        ws.send(_identityTransition(0, 1));

        // Message from the client containing `freshToken`
        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 1,
          token: freshToken,
        );

        // A query can hit the old auth before the new one is processed.
        _simulateAuthError(
          ws,
          error: 'bla',
          baseVersion: 1,
          authUpdateAttempted: false,
        );

        // However, on the next reconnect, it should send `freshToken` to complete the token exchange.
        await _assertReconnectWithAuth(ws, baseVersion: 0, token: freshToken);

        ws.send(_identityTransition(0, 1));

        await Future<void>.delayed(const Duration(milliseconds: 50));
        await client.close();

        // Upstream expects a 2nd `true`; `hadAuth` reports none, never `false`.
        expect(onChange, [true]);
      });
    });

    // A refetch overtaking a reauthentication fetch must restart the socket.
    test(
      'Client maintains connection when refetch occurs during reauth attempt',
      () {
        fakeAsync((async) {
          final ws = InMemoryWebSocket();
          // Upstream's comments assume a 2s leeway; its default is now 10s.
          final client = _testReactClient(
            ws,
            authRefreshTokenLeeway: const Duration(seconds: 2),
          );
          final now = _nowSeconds();
          // Existing token; its times don't matter as a fresh one follows.
          final initialToken = jwtEncode({'iat': now - 10, 'exp': now + 10});
          // fresh token, fetched at ts=1
          final freshToken = jwtEncode({'iat': now + 1, 'exp': now + 4});
          // scheduled refetch at ts=2, finishing at ts=3
          final scheduledRefetchToken = jwtEncode({
            'iat': now + 3,
            'exp': now + 6,
          });
          // fetched at ts 1.5 in response to an auth error, issued at ts=2.5
          final reauthToken = jwtEncode({'iat': now + 2.5, 'exp': now + 5.5});
          final tokens = [
            initialToken,
            freshToken,
            reauthToken,
            scheduledRefetchToken,
          ];
          final onChange = <bool>[];
          // Forced fetches take a second.
          client.setAuth(({required forceRefreshToken}) {
            final token = tokens.removeAt(0);
            if (!forceRefreshToken) {
              expect(token, initialToken);
              return Future.value(token);
            }
            return Future.delayed(const Duration(seconds: 1), () => token);
          }, onChange.add);

          List<JsonMap> drain() {
            async.flushMicrotasks();
            final messages = <JsonMap>[];
            for (var m = ws.tryReceive(); m != null; m = ws.tryReceive()) {
              messages.add(m);
            }
            return messages;
          }

          // Initial connection, sending `initialToken` (ts=0)
          var messages = drain();
          expect(
            [for (final m in messages) m['type']],
            ['Connect', 'Authenticate', 'ModifyQuerySet'],
          );
          expect(messages[1]['value'], initialToken);

          ws.send(_identityTransition(0, 1));

          // A fresh token arrives at ts=1; its refetch is due at ts=2.
          async.elapse(const Duration(seconds: 1));
          messages = drain();
          _assertAuthenticateMessage(
            messages.single,
            baseVersion: 1,
            token: freshToken,
          );

          // Server confirms `freshToken` and transitions to version 2
          ws.send(_identityTransition(1, 2));
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500));

          // ts=1.5: the server hits an AuthError before the scheduled refetch.
          _simulateAuthError(
            ws,
            error: 'bla',
            baseVersion: 2,
            authUpdateAttempted: false,
          );

          // The reauth fetch (ts 1.5-2.5) loses to the refetch (ts 2-3).
          async.elapse(const Duration(milliseconds: 1600));
          messages = drain();
          expect(
            [for (final m in messages) m['type']],
            ['Connect', 'Authenticate', 'ModifyQuerySet'],
          );
          _assertAuthenticateMessage(
            messages[1],
            baseVersion: 0,
            token: scheduledRefetchToken,
          );

          ws.send(_identityTransition(0, 1));
          async.flushMicrotasks();

          unawaited(client.close());
          async.flushMicrotasks();

          // The refetched token keeps the client authenticated throughout.
          expect(onChange, [true]);
        });
      },
    );

    // The app slept through the Transition; the token expired meanwhile.
    test('Client retries token validation on error', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);
        final ts = _nowSeconds();
        final tokens = [
          for (var i = 1; i <= 3; i++)
            jwtEncode({'iat': ts, 'exp': ts + 60, 'n': i}),
        ];
        final remaining = [...tokens];
        final tokenFetcher = _TokenFetcher((_) async => remaining.removeAt(0));
        final onChange = <bool>[];
        client.setAuth(tokenFetcher.call, onChange.add);

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: tokens[0]);

        ws.send(_identityTransition(0, 1));

        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 1,
          token: tokens[1],
        );

        // An auth error while a fresh token awaits server confirmation.
        _simulateAuthError(
          ws,
          error: 'bla',
          baseVersion: 1,
          authUpdateAttempted: true,
        );
        // The client should reattempt reauthentication.
        await _assertReconnectWithAuth(ws, baseVersion: 0, token: tokens[2]);
        ws.send(_identityTransition(0, 1));

        await waitFor(() => onChange.length == 2);
        await client.close();

        // Initial setConfig, the fresh token fetch and the reauth attempt.
        expect(tokenFetcher.calls, [false, true, true]);
        expect(onChange, [true, true]);
      });
    });

    test('Authentication runs first', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        final token1 = jwtEncode({'iat': 1234500, 'exp': 1244500});
        client.setAuth(({required forceRefreshToken}) async => token1);

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: token1);

        // Client started at 0; the good token advanced to 1.
        ws.send(_identityTransition(0, 1));

        final token2 = jwtEncode({'iat': 1234550, 'exp': 1244550});
        client.setAuth(({required forceRefreshToken}) async => token2);
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});

        // Crucially Authenticate comes first!
        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 1,
          token: token2,
        );
        expect((await ws.receive())['type'], 'ModifyQuerySet');
        await client.close();
      });
    });

    test("Auth pause doesn't prevent unsubscribing from queries", () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        final token1 = jwtEncode({'iat': 1234500, 'exp': 1244500});
        client.setAuth(({required forceRefreshToken}) async => token1);

        final unsubscribe = client
            .watchQuery(anyQuery('myQuery'), noArgs)
            .onUpdate(() {});

        await _assertReconnectWithAuth(ws, baseVersion: 0, token: token1);

        ws.send(
          transition(
            startVersion: stateVersion(ts: 0),
            endVersion: stateVersion(querySet: 1, identity: 1, ts: 1),
            modifications: [queryUpdated(0, 42)],
          ).json,
        );
        await waitFor(
          () =>
              client
                  .watchQuery(anyQuery('myQuery'), noArgs)
                  .localQueryResult() !=
              null,
        );

        final resolve = Completer<String>();
        // Set new auth
        client.setAuth(({required forceRefreshToken}) => resolve.future);

        // Unsubscribe
        unsubscribe();

        // Finish fetching the token
        final token2 = jwtEncode({'iat': 1234550, 'exp': 1244550});
        resolve.complete(token2);

        // Crucially Authenticate comes first!
        _assertAuthenticateMessage(
          await ws.receive(),
          baseVersion: 1,
          token: token2,
        );
        final remove = await ws.receive();
        expect(remove['type'], 'ModifyQuerySet');
        expect(remove['baseVersion'], 1);
        expect(remove['modifications'], [
          {'type': 'Remove', 'queryId': 0},
        ]);

        // Make sure we are now unpaused
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});

        final add1 = await ws.receive();
        expect(add1['baseVersion'], 2);
        expect(((add1['modifications']! as List).single as Map)['queryId'], 1);

        client.watchQuery(anyQuery('myQuery:foo'), noArgs).onUpdate(() {});

        final add2 = await ws.receive();
        expect(add2['baseVersion'], 3);
        expect(((add2['modifications']! as List).single as Map)['queryId'], 2);
        await client.close();
      });
    });

    test("Local state resume doesn't cause duplicate AddQuery", () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        // First we subscribe
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});

        expect((await ws.receive())['type'], 'Connect');
        final add = await ws.receive();
        expect(add['baseVersion'], 0);
        expect(((add['modifications']! as List).single as Map)['queryId'], 0);

        // Setting auth before the server confirms pauses and unpauses.
        client.setAuth(
          ({required forceRefreshToken}) async =>
              jwtEncode({'iat': 1234500, 'exp': 1244500}),
        );

        // Only Authenticate, since the Add modification already went out.
        final authenticate = await ws.receive();
        expect(authenticate['type'], 'Authenticate');
        expect(authenticate['baseVersion'], 0);

        // Subscribe again
        client.watchQuery(anyQuery('myQuery'), {'foo': 'bla'}).onUpdate(() {});
        // Now we're sending the second query, not the first!
        final add2 = await ws.receive();
        expect(add2['baseVersion'], 1);
        expect(((add2['modifications']! as List).single as Map)['queryId'], 1);
        await client.close();
      });
    });

    test("Local state resume doesn't send both Add and Remove", () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        // First we subscribe to kick off connect.
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['baseVersion'], 0);

        // Set slow auth, causing pause
        final resolve = Completer<String>();
        client.setAuth(({required forceRefreshToken}) => resolve.future);

        // Subscribe to second query, while paused
        final unsubscribe = client
            .watchQuery(anyQuery('myQuery'), {'foo': 'bla'})
            .onUpdate(() {});

        // Subscribe third query, while paused
        client.watchQuery(anyQuery('myQuery'), {'foo': 'da'}).onUpdate(() {});

        // Unsubscribe from second query, while paused
        unsubscribe();

        // Unpause ie resume
        resolve.complete(jwtEncode({'iat': 1234550, 'exp': 1244550}));

        // We authenticate first
        final authenticate = await ws.receive();
        expect(authenticate['type'], 'Authenticate');
        expect(authenticate['baseVersion'], 0);

        // We subscribe to the third query only!
        final add = await ws.receive();
        expect(add['baseVersion'], 1);
        expect(((add['modifications']! as List).single as Map)['queryId'], 2);
        await client.close();
      });
    });

    test('Local state resume refcounts', () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        // First we subscribe to kick off connect.
        client.watchQuery(anyQuery('myQuery'), noArgs).onUpdate(() {});

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['baseVersion'], 0);

        // Set slow auth, causing pause
        final resolve = Completer<String>();
        client.setAuth(({required forceRefreshToken}) => resolve.future);

        // Subscribe to second query, while paused
        final unsubscribe = client
            .watchQuery(anyQuery('myQuery'), {'foo': 'bla'})
            .onUpdate(() {});

        // Subscribe to the same query, while paused
        client.watchQuery(anyQuery('myQuery'), {'foo': 'bla'}).onUpdate(() {});

        // Unsubscribe once from the second query, while paused
        unsubscribe();

        // Unpause ie resume
        resolve.complete(jwtEncode({'iat': 1234550, 'exp': 1244550}));

        // We authenticate first
        final authenticate = await ws.receive();
        expect(authenticate['type'], 'Authenticate');
        expect(authenticate['baseVersion'], 0);

        // There's still one subscriber on the second query.
        final add = await ws.receive();
        expect(add['baseVersion'], 1);
        expect(((add['modifications']! as List).single as Map)['queryId'], 1);
        await client.close();
      });
    });

    test("Local state restart doesn't send both Add and Remove", () async {
      await withInMemoryWebSocket((ws) async {
        final client = _testReactClient(ws);

        // Set slow auth, causing pause while connecting
        final resolve = Completer<String>();
        client.setAuth(({required forceRefreshToken}) => resolve.future);

        // Subscribe while paused and connecting
        final unsubscribe = client
            .watchQuery(anyQuery('myQuery'), noArgs)
            .onUpdate(() {});

        // Unsubscribe while paused and connecting
        unsubscribe();

        // Unpause
        resolve.complete(jwtEncode({'iat': 1234550, 'exp': 1244550}));

        expect((await ws.receive())['type'], 'Connect');
        expect((await ws.receive())['type'], 'Authenticate');
        final querySet = await ws.receive();
        expect(querySet['type'], 'ModifyQuerySet');
        expect(querySet['baseVersion'], 0);
        expect(querySet['modifications'], isEmpty);
        await client.close();
      });
    });
  });

  // Clients can't always set auth right away: libraries need setup.
  group('authMode WebSocket', () {
    for (final expectAuth in [false, true]) {
      test('expectAuth: $expectAuth', () async {
        await withInMemoryWebSocket((ws) async {
          final client = _testReactClient(ws, expectAuth: expectAuth);

          // Connecting is lazy: subscribe or request to make it happen.
          unawaited(
            client
                .mutation(anyMutation('myMutation'), noArgs)
                .then((_) {}, onError: (_) {}),
          );

          // If expectAuth isn't enabled, this kicks off connect etc.
          if (!expectAuth) {
            expect((await ws.receive())['type'], 'Connect');
            expect((await ws.receive())['type'], 'ModifyQuerySet');
            expect((await ws.receive())['type'], 'Mutation');
          }
          // but *nothing* happens if expectAuth is set.

          final resolve = Completer<String>();
          final onAuthChange = <bool>[];
          client.setAuth(
            ({required forceRefreshToken}) => resolve.future,
            onAuthChange.add,
          );

          resolve.complete(jwtEncode({'iat': 1234550, 'exp': 1244550}));

          if (!expectAuth) {
            expect((await ws.receive())['type'], 'Authenticate');
          } else {
            // We're still paused until auth is returned
            expect((await ws.receive())['type'], 'Connect');
            expect((await ws.receive())['type'], 'Authenticate');
            expect((await ws.receive())['type'], 'ModifyQuerySet');
            expect((await ws.receive())['type'], 'Mutation');
          }

          await client.close();
        });
      });
    }
  });
}
