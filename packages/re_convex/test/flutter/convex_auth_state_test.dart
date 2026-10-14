import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/authentication_manager.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show JsonMap;
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/convex_auth_state.dart';

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
  ConvexLogger? logger,
}) => ConvexReactClient(
  ws.address,
  ConvexReactClientOptions(
    webSocketConstructor: ws.webSocketConstructor,
    logger: logger ?? instantiateNoopLogger(),
  ),
);

JsonMap _identityTransition(int from, int to) => transition(
  startVersion: stateVersion(identity: from, ts: 0),
  endVersion: stateVersion(identity: to, ts: 0),
).json;

/// Records `setAuth`/`clearAuth` into [events] and keeps the last callbacks.
class _FakeConvexClient implements IConvexReactClient {
  _FakeConvexClient(this.events);

  final List<String> events;
  AuthTokenFetcher? fetchToken;
  void Function(bool isAuthenticated)? onChange;
  void Function(bool isRefreshing)? onRefreshChange;

  @override
  void setAuth(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]) {
    events.add('setAuth');
    this.fetchToken = fetchToken;
    this.onChange = onChange;
    this.onRefreshChange = onRefreshChange;
  }

  @override
  void clearAuth() => events.add('clearAuth');
}

Future<String?> _fetchA({required bool forceRefreshToken}) async => 'a';
Future<String?> _fetchB({required bool forceRefreshToken}) async => 'b';

ConvexAuthProviderState _provider({
  bool loading = false,
  bool authenticated = false,
  AuthTokenFetcher fetch = _fetchA,
}) => ConvexAuthProviderState(
  isLoading: loading,
  isAuthenticated: authenticated,
  fetchAccessToken: fetch,
);

ConvexAuthState _state({
  bool loading = false,
  bool authenticated = false,
  bool refreshing = false,
}) => ConvexAuthState(
  isLoading: loading,
  isAuthenticated: authenticated,
  isRefreshing: refreshing,
);

void main() {
  test("setAuth without callbacks doesn't throw", () async {
    final convex = ConvexReactClient(
      'https://127.0.0.1:3001',
      ConvexReactClientOptions(
        webSocketConstructor: offlineWebSocketConstructor,
        logger: instantiateNoopLogger(),
      ),
    );
    convex.setAuth(({required forceRefreshToken}) async => 'foo');
    await convex.close();
  });

  // This is no longer really possible, because the server requires JWTs.
  test('Tokens must be valid JWT', () async {
    await withInMemoryWebSocket((ws) async {
      final logger = _RecordingLogger();
      final client = _testReactClient(ws, logger: logger);

      var tokenId = 0;
      // simulate a new token on every fetch
      client.setAuth(
        ({required forceRefreshToken}) async => 'foo${tokenId++}',
        (_) {},
      );

      // Wait for token
      expect((await ws.receive())['type'], 'Connect');
      expect((await ws.receive())['value'], 'foo0');
      expect((await ws.receive())['type'], 'ModifyQuerySet');

      // Server confirms it
      ws.send(_identityTransition(0, 1));

      // Wait for token with `forceRefreshToken: true`
      expect((await ws.receive())['value'], 'foo1');

      // Server confirms it
      ws.send(_identityTransition(1, 2));

      await waitFor(() => logger.errors.isNotEmpty);
      await client.close();
      expect(
        logger.errors,
        contains('Auth token is not a valid JWT, cannot refetch the token'),
      );
    });
  });

  test('Tokens are used to schedule refetch', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final client = _testReactClient(ws);
      const tokenLifetimeSeconds = 60;
      var tokenId = 0;
      var fetches = 0;
      client.setAuth(({required forceRefreshToken}) async {
        fetches++;
        return jwtEncode({
          'iat': 1234500,
          'exp': 1234500 + tokenLifetimeSeconds,
          // simulate a new token on every fetch
          'n': tokenId++,
        });
      }, (_) {});

      // Wait for token
      async.flushMicrotasks();

      // Server confirms it
      ws.send(_identityTransition(0, 1));

      // Wait for token with `forceRefreshToken: true`
      async.flushMicrotasks();

      // Confirm refetched token
      ws.send(_identityTransition(1, 2));
      async.flushMicrotasks();

      expect(fetches, 2);

      // Check that next refetch happens in time
      async.elapse(const Duration(seconds: tokenLifetimeSeconds));
      expect(fetches, 3);

      unawaited(client.close());
      async.flushMicrotasks();
    });
  });

  group('ConvexAuthController', () {
    late List<String> events;
    late _FakeConvexClient client;

    setUp(() {
      events = <String>[];
      client = _FakeConvexClient(events);
    });

    test('stays loading until the provider resolves a signed-out user', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(loading: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      expect(controller.state.value, _state(loading: true));

      auth.value = _provider();
      expect(controller.state.value, _state());
      expect(events, isEmpty);
    });

    test('authenticates a signed-in user and follows the backend', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      expect(events, <String>['setAuth']);
      expect(client.fetchToken, same(_fetchA));
      expect(controller.state.value, _state(loading: true));

      client.onChange!(true);
      expect(controller.state.value, _state(authenticated: true));
      client.onChange!(false);
      expect(controller.state.value, _state());
    });

    test('publishes the sign-out before clearing Convex auth', () {
      final effects = <VoidCallback>[];
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(
        client: client,
        auth: auth,
        scheduleEffects: effects.add,
      );
      effects.removeAt(0)();
      client.onChange!(true);
      controller.state.addListener(
        () => events.add(
          'authenticated: ${controller.state.value.isAuthenticated}',
        ),
      );

      auth.value = _provider();
      expect(events, <String>['setAuth', 'authenticated: false']);
      effects.removeAt(0)();
      expect(events, <String>['setAuth', 'authenticated: false', 'clearAuth']);
      expect(controller.state.value, _state());
    });

    test('authenticates again when the token fetcher changes', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      final staleOnChange = client.onChange!;
      staleOnChange(true);

      auth.value = _provider(authenticated: true, fetch: _fetchB);
      expect(events, <String>['setAuth', 'clearAuth', 'setAuth']);
      expect(client.fetchToken, same(_fetchB));
      expect(controller.state.value, _state(loading: true));

      staleOnChange(true);
      expect(controller.state.value, _state(loading: true));
      client.onChange!(true);
      expect(controller.state.value, _state(authenticated: true));
    });

    test('reports refreshing only while authenticated', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      client
        ..onChange!(true)
        ..onRefreshChange!(true);
      expect(
        controller.state.value,
        _state(authenticated: true, refreshing: true),
      );

      client.onChange!(false);
      expect(controller.state.value, _state());
    });

    test('goes back to loading while the provider reloads', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      client.onChange!(true);

      auth.value = _provider(loading: true, authenticated: true);
      expect(controller.state.value.isLoading, isTrue);
    });

    test('dispose clears Convex auth and ignores late answers', () {
      final auth = ValueNotifier<ConvexAuthProviderState>(
        _provider(authenticated: true),
      );
      final controller = ConvexAuthController(client: client, auth: auth);
      final onChange = client.onChange!;

      controller.dispose();
      expect(events, <String>['setAuth', 'clearAuth']);
      onChange(true);
      auth.value = _provider();
      expect(events, <String>['setAuth', 'clearAuth']);
    });
  });
}
