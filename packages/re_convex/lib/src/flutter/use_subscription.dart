// Ported from convex/src/react/use_subscription.ts (Apache-2.0); modified for Dart.
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:meta/meta.dart';

/// Subscribes while the widget is mounted and returns the current value,
/// rebuilding when [subscribe]'s callback reports a different one.
///
/// Memoize [getCurrentValue] and [subscribe]: new functions resubscribe.
@internal
T useSubscription<T>({
  required T Function() getCurrentValue,
  required void Function() Function(void Function() callback) subscribe,
}) => use(_SubscriptionHook<T>(getCurrentValue, subscribe));

class _SubscriptionHook<T> extends Hook<T> {
  const _SubscriptionHook(this.getCurrentValue, this.subscribe);

  final T Function() getCurrentValue;
  final void Function() Function(void Function() callback) subscribe;

  @override
  _SubscriptionHookState<T> createState() => _SubscriptionHookState<T>();
}

class _SubscriptionHookState<T> extends HookState<T, _SubscriptionHook<T>> {
  late T _value;
  void Function()? _unsubscribe;

  @override
  void initHook() {
    super.initHook();
    _subscribe();
  }

  @override
  void didUpdateHook(_SubscriptionHook<T> oldHook) {
    super.didUpdateHook(oldHook);
    if (!identical(oldHook.getCurrentValue, hook.getCurrentValue) ||
        !identical(oldHook.subscribe, hook.subscribe)) {
      _unsubscribe?.call();
      _subscribe();
    }
  }

  // Hooks run in build, so the value read after subscribing is current.
  void _subscribe() {
    final getCurrentValue = hook.getCurrentValue;
    var didUnsubscribe = false;
    final unsubscribe = hook.subscribe(() {
      // The callback can run after unsubscribing, during an update.
      if (didUnsubscribe || !identical(hook.getCurrentValue, getCurrentValue)) {
        return;
      }
      final value = getCurrentValue();
      if (identical(value, _value)) {
        return;
      }
      setState(() => _value = value);
    });
    _unsubscribe = () {
      didUnsubscribe = true;
      unsubscribe();
    };
    _value = getCurrentValue();
  }

  @override
  T build(BuildContext context) => _value;

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  String get debugLabel => 'useSubscription';
}
