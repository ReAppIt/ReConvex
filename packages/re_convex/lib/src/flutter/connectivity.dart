import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:re_convex/src/browser/sync/web_socket_manager.dart';

/// A [SubscribeToOnline] over connectivity_plus, firing when the device goes
/// from no network to any; pass it as `subscribeToOnline` to skip the
/// backoff. Errors and a missing plugin count as online.
SubscribeToOnline subscribeToConnectivity({
  Stream<List<ConnectivityResult>> Function()? connectivityChanges,
}) => (onOnline) {
  var offline = false;
  final changes =
      connectivityChanges ?? () => Connectivity().onConnectivityChanged;
  final subscription = changes().listen(
    (results) {
      final isOffline = !results.any((r) => r != ConnectivityResult.none);
      if (offline && !isOffline) {
        onOnline();
      }
      offline = isOffline;
    },
    onError: (Object _) {
      offline = false;
    },
  );
  return () {
    unawaited(subscription.cancel());
  };
};
