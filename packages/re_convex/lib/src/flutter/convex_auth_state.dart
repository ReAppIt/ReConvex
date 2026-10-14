// Ported from convex/src/react/ConvexAuthState.tsx (Apache-2.0); modified for Dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:re_convex/src/browser/sync/authentication_manager.dart';
import 'package:re_convex/src/flutter/client.dart';

/// The part of `ConvexReactClient` that [ConvexProviderWithAuth] uses.
abstract interface class IConvexReactClient {
  /// Sets the source of auth tokens.
  void setAuth(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]);

  /// Clears the auth token.
  void clearAuth();
}

/// The state of an auth integration with Convex, from [useConvexAuth].
@immutable
class ConvexAuthState {
  /// Creates a state.
  const ConvexAuthState({
    required this.isLoading,
    required this.isAuthenticated,
    required this.isRefreshing,
  });

  /// Whether the initial auth state is still resolving and the server has
  /// yet to confirm the token.
  final bool isLoading;

  /// Whether the server confirmed the current token.
  final bool isAuthenticated;

  /// Whether the server rejected a confirmed token and the socket waits for
  /// a new one; only `true` while [isAuthenticated].
  final bool isRefreshing;

  @override
  bool operator ==(Object other) =>
      other is ConvexAuthState &&
      other.isLoading == isLoading &&
      other.isAuthenticated == isAuthenticated &&
      other.isRefreshing == isRefreshing;

  @override
  int get hashCode => Object.hash(isLoading, isAuthenticated, isRefreshing);
}

/// What an auth provider's `useAuth` hook reports to
/// [ConvexProviderWithAuth].
@immutable
class ConvexAuthProviderState {
  /// Creates a provider state.
  const ConvexAuthProviderState({
    required this.isLoading,
    required this.isAuthenticated,
    required this.fetchAccessToken,
  });

  /// Whether the provider is still resolving the user.
  final bool isLoading;

  /// Whether a user is signed in.
  final bool isAuthenticated;

  /// Fetches the JWT; a new function makes Convex authenticate again.
  final AuthTokenFetcher fetchAccessToken;

  @override
  bool operator ==(Object other) =>
      other is ConvexAuthProviderState &&
      other.isLoading == isLoading &&
      other.isAuthenticated == isAuthenticated &&
      other.fetchAccessToken == fetchAccessToken;

  @override
  int get hashCode => Object.hash(isLoading, isAuthenticated, fetchAccessToken);
}

typedef _EffectDeps = ({
  bool authenticated,
  bool loading,
  AuthTokenFetcher fetchAccessToken,
});

/// The state and effects of [ConvexProviderWithAuth] without widgets: it
/// authenticates [client] while [auth] has a user and publishes [state].
class ConvexAuthController {
  /// Follows [auth]; [scheduleEffects] runs effects after [state] listeners
  /// reacted, so Convex auth is cleared only once signed-in UI is gone.
  ConvexAuthController({
    required this.client,
    required this.auth,
    void Function(VoidCallback effects)? scheduleEffects,
  }) : _scheduleEffects = scheduleEffects ?? _runNow {
    auth.addListener(_render);
    _render();
  }

  static void _runNow(VoidCallback effects) => effects();

  /// The Convex client's auth calls.
  final IConvexReactClient client;

  /// The auth provider's state.
  final ValueListenable<ConvexAuthProviderState> auth;

  final void Function(VoidCallback effects) _scheduleEffects;
  final ValueNotifier<ConvexAuthState> _state = ValueNotifier<ConvexAuthState>(
    const ConvexAuthState(
      isLoading: true,
      isAuthenticated: false,
      isRefreshing: false,
    ),
  );
  bool? _isConvexAuthenticated;
  bool _isRefreshing = false;
  _EffectDeps? _effectDeps;
  VoidCallback? _firstEffectCleanup;
  VoidCallback? _lastEffectCleanup;
  bool _effectsScheduled = false;
  bool _disposed = false;

  /// The state [useConvexAuth] returns.
  ValueListenable<ConvexAuthState> get state => _state;

  bool _depsChanged(ConvexAuthProviderState provider) {
    final deps = _effectDeps;
    return deps == null ||
        deps.authenticated != provider.isAuthenticated ||
        deps.loading != provider.isLoading ||
        deps.fetchAccessToken != provider.fetchAccessToken;
  }

  void _render() {
    if (_disposed) return;
    final provider = auth.value;
    // A provider back to loading goes to loading, not through signed out.
    if (provider.isLoading && _isConvexAuthenticated != null) {
      _isConvexAuthenticated = null;
      _isRefreshing = false;
    }
    if (!provider.isLoading &&
        !provider.isAuthenticated &&
        _isConvexAuthenticated != false) {
      _isConvexAuthenticated = false;
      _isRefreshing = false;
    }
    final isAuthenticated =
        provider.isAuthenticated && (_isConvexAuthenticated ?? false);
    _state.value = ConvexAuthState(
      isLoading: _isConvexAuthenticated == null,
      isAuthenticated: isAuthenticated,
      isRefreshing: _isRefreshing && isAuthenticated,
    );
    if (_effectsScheduled || !_depsChanged(provider)) return;
    _effectsScheduled = true;
    _scheduleEffects(_runEffects);
  }

  void _runEffects() {
    _effectsScheduled = false;
    if (_disposed) return;
    final provider = auth.value;
    if (!_depsChanged(provider)) return;
    _effectDeps = (
      authenticated: provider.isAuthenticated,
      loading: provider.isLoading,
      fetchAccessToken: provider.fetchAccessToken,
    );
    _cleanupEffects();
    if (!provider.isAuthenticated) return;
    var isThisEffectRelevant = true;
    client.setAuth(
      provider.fetchAccessToken,
      (backendReportsIsAuthenticated) {
        if (!isThisEffectRelevant) return;
        _isConvexAuthenticated = backendReportsIsAuthenticated;
        _render();
      },
      (isRefreshing) {
        if (!isThisEffectRelevant) return;
        _isRefreshing = isRefreshing;
        _render();
      },
    );
    _firstEffectCleanup = () {
      isThisEffectRelevant = false;
      // A token fetch cut short must not end in a loaded state.
      _isConvexAuthenticated = (_isConvexAuthenticated ?? false) ? false : null;
      _isRefreshing = false;
    };
    _lastEffectCleanup = () {
      client.clearAuth();
      // A new fetcher can mean a new auth context, so load again.
      _isConvexAuthenticated = null;
      _isRefreshing = false;
    };
  }

  void _cleanupEffects() {
    final first = _firstEffectCleanup;
    final last = _lastEffectCleanup;
    _firstEffectCleanup = null;
    _lastEffectCleanup = null;
    if (first == null && last == null) return;
    first?.call();
    last?.call();
    _render();
  }

  /// Stops following [auth] and clears Convex auth if it was set.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    auth.removeListener(_render);
    _cleanupEffects();
    _state.dispose();
  }
}

/// A [ConvexProvider] that also authenticates [client] while the [useAuth]
/// hook reports a user, and provides [useConvexAuth] to [child]. Memoize
/// `fetchAccessToken`: a new function authenticates again.
class ConvexProviderWithAuth extends HookWidget {
  /// Creates the provider.
  const ConvexProviderWithAuth({
    super.key,
    required this.client,
    required this.useAuth,
    required this.child,
  });

  /// The Convex client; a `ConvexReactClient` is also provided to [child].
  final IConvexReactClient client;

  /// The auth provider's hook.
  final ConvexAuthProviderState Function() useAuth;

  /// The subtree.
  final Widget child;

  // Post-frame, so signed-in subtrees unsubscribe before `clearAuth`.
  static void _afterFrame(VoidCallback effects) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => effects())
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final provider = useAuth();
    final auth = useMemoized(() => ValueNotifier(provider));
    useEffect(() => auth.dispose, [auth]);
    auth.value = provider;
    final client = this.client;
    final controller = useMemoized(
      () => ConvexAuthController(
        client: client,
        auth: auth,
        scheduleEffects: _afterFrame,
      ),
      [client],
    );
    useEffect(() => controller.dispose, [controller]);
    return _ConvexAuthScope(
      notifier: controller.state,
      child: client is ConvexReactClient
          ? ConvexProvider(client: client, child: child)
          : child,
    );
  }
}

class _ConvexAuthScope
    extends InheritedNotifier<ValueListenable<ConvexAuthState>> {
  const _ConvexAuthScope({required super.notifier, required super.child});
}

/// The [ConvexAuthState] of the nearest [ConvexProviderWithAuth],
/// rebuilding when it changes.
ConvexAuthState useConvexAuth() {
  final scope = useContext()
      .dependOnInheritedWidgetOfExactType<_ConvexAuthScope>();
  if (scope == null) {
    throw StateError(
      'Could not find `ConvexProviderWithAuth` as an ancestor widget. This '
      'widget may be missing.',
    );
  }
  return scope.notifier!.value;
}
