@Tags(['widget'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/authentication_manager.dart';
import 'package:re_convex/src/flutter/auth_helpers.dart';
import 'package:re_convex/src/flutter/convex_auth_state.dart';

class _FakeConvexClient implements IConvexReactClient {
  void Function(bool isAuthenticated)? onChange;
  void Function(bool isRefreshing)? onRefreshChange;

  @override
  void setAuth(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]) {
    this.onChange = onChange;
    this.onRefreshChange = onRefreshChange;
  }

  @override
  void clearAuth() {}
}

Future<String?> _fetch({required bool forceRefreshToken}) async => 'token';

const _helpers = Directionality(
  textDirection: TextDirection.ltr,
  child: Column(
    children: [
      Authenticated(child: Text('Yay')),
      Unauthenticated(child: Text('Nay')),
      AuthLoading(child: Text('???')),
      AuthRefreshing(child: Text('Refreshing')),
    ],
  ),
);

void main() {
  testWidgets('Helpers show their child in their state', (tester) async {
    final client = _FakeConvexClient();
    var provider = const ConvexAuthProviderState(
      isLoading: true,
      isAuthenticated: false,
      fetchAccessToken: _fetch,
    );
    Widget app() => ConvexProviderWithAuth(
      client: client,
      useAuth: () => provider,
      child: _helpers,
    );
    void expectShown(List<String> shown) {
      for (final text in ['Yay', 'Nay', '???', 'Refreshing']) {
        expect(
          find.text(text),
          shown.contains(text) ? findsOneWidget : findsNothing,
          reason: text,
        );
      }
    }

    await tester.pumpWidget(app());
    expectShown(['???']);

    provider = const ConvexAuthProviderState(
      isLoading: false,
      isAuthenticated: true,
      fetchAccessToken: _fetch,
    );
    await tester.pumpWidget(app());
    expectShown(['???']);

    client.onChange!(true);
    await tester.pump();
    expectShown(['Yay']);

    client.onRefreshChange!(true);
    await tester.pump();
    expectShown(['Yay', 'Refreshing']);

    provider = const ConvexAuthProviderState(
      isLoading: false,
      isAuthenticated: false,
      fetchAccessToken: _fetch,
    );
    await tester.pumpWidget(app());
    expectShown(['Nay']);

    await tester.pumpWidget(const SizedBox());
  });
}
