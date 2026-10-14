// Ported from convex/src/react/auth_helpers.tsx (Apache-2.0); modified for Dart.
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:re_convex/src/flutter/convex_auth_state.dart';

/// Shows [child] if the client is authenticated.
class Authenticated extends HookWidget {
  /// Creates the gate.
  const Authenticated({super.key, required this.child});

  /// Shown while authenticated.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConvexAuthState(:isLoading, :isAuthenticated) = useConvexAuth();
    if (isLoading || !isAuthenticated) {
      return const SizedBox.shrink();
    }
    return child;
  }
}

/// Shows [child] if the client is using authentication but is not
/// authenticated.
class Unauthenticated extends HookWidget {
  /// Creates the gate.
  const Unauthenticated({super.key, required this.child});

  /// Shown while unauthenticated.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConvexAuthState(:isLoading, :isAuthenticated) = useConvexAuth();
    if (isLoading || isAuthenticated) {
      return const SizedBox.shrink();
    }
    return child;
  }
}

/// Shows [child] while the client is authenticating.
class AuthLoading extends HookWidget {
  /// Creates the gate.
  const AuthLoading({super.key, required this.child});

  /// Shown while loading.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConvexAuthState(:isLoading) = useConvexAuth();
    if (!isLoading) {
      return const SizedBox.shrink();
    }
    return child;
  }
}

/// Shows [child] while an authenticated client refetches a token the
/// server rejected; routine token rotation doesn't count.
class AuthRefreshing extends HookWidget {
  /// Creates the gate.
  const AuthRefreshing({super.key, required this.child});

  /// Shown while refreshing.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConvexAuthState(:isAuthenticated, :isRefreshing) = useConvexAuth();
    if (!isAuthenticated || !isRefreshing) {
      return const SizedBox.shrink();
    }
    return child;
  }
}
