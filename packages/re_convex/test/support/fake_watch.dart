// Ported from convex/src/test/fake_watch.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/flutter/client.dart';

/// A [Watch] whose value tests set by hand.
class FakeWatch<T> implements Watch<T> {
  /// The registered callbacks.
  final Set<void Function()> callbacks = {};

  /// The current value; `null` while loading.
  ({T value})? value;

  /// The current journal.
  QueryJournal journalValue;

  /// Sets the value and notifies the callbacks.
  void setValue(({T value})? newValue) {
    value = newValue;
    for (final callback in callbacks.toList()) {
      callback();
    }
  }

  /// Sets the journal.
  void setJournal(QueryJournal journal) {
    journalValue = journal;
  }

  /// The number of registered callbacks.
  int numCallbacks() => callbacks.length;

  @override
  void Function() onUpdate(void Function() callback) {
    callbacks.add(callback);
    return () {
      callbacks.remove(callback);

      // Without subscribers, drop the journal like the real client.
      if (numCallbacks() == 0) {
        journalValue = null;
      }
    };
  }

  @override
  ({T value})? localQueryResult() => value;

  @override
  List<String>? localQueryLogs() => null;

  @override
  QueryJournal journal() => journalValue;
}
