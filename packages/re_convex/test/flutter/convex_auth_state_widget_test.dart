@Tags(['widget'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show JsonMap;
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/convex_auth_state.dart';

import '../support/client_node_test_helpers.dart';
import '../support/fakes.dart';
import '../support/jwt.dart';

// This is our fake ProviderX state
typedef _ProviderXState = ({
  bool isLoading,
  bool isAuthenticated,
  Future<String?> Function({required bool ignoreCache}) getToken,
});

class _AuthProviderXContext extends InheritedWidget {
  const _AuthProviderXContext({required this.value, required super.child});

  final _ProviderXState value;

  @override
  bool updateShouldNotify(_AuthProviderXContext oldWidget) =>
      value != oldWidget.value;
}

// Fake ProviderX hook
_ProviderXState _useProviderXAuth() => useContext()
    .dependOnInheritedWidgetOfExactType<_AuthProviderXContext>()!
    .value;

// What our users would have to write.
ConvexAuthProviderState _useAuthFromProviderX() {
  final (:isLoading, :isAuthenticated, :getToken) = _useProviderXAuth();
  final fetchAccessToken = useCallback(
    // Make sure to fetch a new token when `forceRefreshToken` is true
    ({required bool forceRefreshToken}) =>
        getToken(ignoreCache: forceRefreshToken),
    [getToken],
  );
  return useMemoized(
    () => ConvexAuthProviderState(
      isLoading: isLoading,
      isAuthenticated: isAuthenticated,
      fetchAccessToken: fetchAccessToken,
    ),
    [isLoading, isAuthenticated, fetchAccessToken],
  );
}

// Our app will mirror the Convex auth state
class _App extends HookWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    final ConvexAuthState(:isLoading, :isAuthenticated) = useConvexAuth();
    return Text(
      isLoading
          ? 'Loading...'
          : isAuthenticated
          ? 'Authenticated'
          : 'Unauthenticated',
      textDirection: TextDirection.ltr,
    );
  }
}

JsonMap _identityTransition(int from, int to) => transition(
  startVersion: stateVersion(identity: from, ts: 0),
  endVersion: stateVersion(identity: to, ts: 0),
).json;

void main() {
  testWidgets('ConvexProviderWithAuth works', (tester) async {
    final ws = InMemoryWebSocket();
    final convex = ConvexReactClient(
      ws.address,
      ConvexReactClientOptions(
        webSocketConstructor: ws.webSocketConstructor,
        logger: instantiateNoopLogger(),
      ),
    );

    Widget element(_ProviderXState value) => _AuthProviderXContext(
      value: value,
      child: ConvexProviderWithAuth(
        client: convex,
        useAuth: _useAuthFromProviderX,
        child: const _App(),
      ),
    );

    await tester.pumpWidget(
      element((
        isLoading: true,
        isAuthenticated: false,
        getToken: ({required ignoreCache}) async => null,
      )),
    );
    expect(find.text('Loading...'), findsOneWidget);

    final token = jwtEncode({'iat': 1234500, 'exp': 1234500 + 30});
    await tester.pumpWidget(
      element((
        isLoading: false,
        isAuthenticated: true,
        getToken: ({required ignoreCache}) async => token,
      )),
    );
    expect(find.text('Loading...'), findsOneWidget);

    // The effects ran after that frame; the token went out.
    await tester.pump();
    final sent = [
      for (var m = ws.tryReceive(); m != null; m = ws.tryReceive()) m,
    ];
    expect(
      sent.where((m) => m['type'] == 'Authenticate').map((m) => m['value']),
      [token],
    );

    // The server confirms the token.
    ws.send(_identityTransition(0, 1));
    await tester.pump();
    await tester.pump();

    expect(find.text('Authenticated'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await convex.close();
  });

  testWidgets('useConvexAuth throws without ConvexProviderWithAuth', (
    tester,
  ) async {
    await tester.pumpWidget(const _App());
    expect(
      tester.takeException(),
      isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('ConvexProviderWithAuth'),
      ),
    );
  });
}
