import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/flutter/connectivity.dart';

void main() {
  group('subscribeToConnectivity', () {
    test('fires only when the network comes back', () async {
      final changes = StreamController<List<ConnectivityResult>>();
      var online = 0;
      final unsubscribe = subscribeToConnectivity(
        connectivityChanges: () => changes.stream,
      )(() => online++);

      changes
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.mobile])
        ..add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(online, 1);

      unsubscribe();
      expect(changes.hasListener, isFalse);
      await changes.close();
    });

    test('treats errors as online', () async {
      final changes = StreamController<List<ConnectivityResult>>();
      var online = 0;
      final unsubscribe = subscribeToConnectivity(
        connectivityChanges: () => changes.stream,
      )(() => online++);

      changes
        ..add([ConnectivityResult.none])
        ..addError(Exception('no plugin'))
        ..add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(online, 0);

      unsubscribe();
      await changes.close();
    });
  });
}
