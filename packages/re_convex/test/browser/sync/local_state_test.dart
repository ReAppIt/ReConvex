import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/local_state.dart';

import '../../support/fakes.dart';

void main() {
  test('can create a local state', () {
    LocalSyncState();
  });

  test('has outstanding state older than restart', () {
    final state = LocalSyncState();
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Restarting w/o outstanding queries
    state.restart();
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Do two subscriptions.
    state
      ..subscribe('hello:world1', {})
      ..subscribe('hello:world2', {});
    final queryId1 = state.queryId('hello:world1', {})!;
    final queryId2 = state.queryId('hello:world2', {})!;
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Restart before we get results. This should flip synced to false.
    state.restart();
    expect(state.hasSyncedPastLastReconnect(), isFalse);

    // If we provide partial results, then synced should remain false
    state.transition(
      transition(
        startVersion: stateVersion(ts: 500),
        endVersion: stateVersion(ts: 1000),
        modifications: [
          {
            'type': 'QueryUpdated',
            'queryId': queryId1,
            'value': 'hi',
            'logLines': <String>[],
            'journal': null,
          },
        ],
      ),
    );
    expect(state.hasSyncedPastLastReconnect(), isFalse);

    // If we provide full results, then synced should go true
    state.transition(
      transition(
        startVersion: stateVersion(ts: 1000),
        endVersion: stateVersion(ts: 1500),
        modifications: [
          {
            'type': 'QueryUpdated',
            'queryId': queryId2,
            'value': 'hi',
            'logLines': <String>[],
            'journal': null,
          },
        ],
      ),
    );
    expect(state.hasSyncedPastLastReconnect(), isTrue);
  });

  test('unsubscribe resets outstanding state older than restart', () {
    final state = LocalSyncState();
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Do one subscription.
    final sub1 = state.subscribe('hello:world', {});

    // Restart before we get results. This should flip synced to false.
    state.restart();
    expect(state.hasSyncedPastLastReconnect(), isFalse);

    // Unsubscribe. This should flip synced back to true, even before getting result.
    sub1.unsubscribe();
    expect(state.hasSyncedPastLastReconnect(), isTrue);
  });

  test('complete auth resets outstanding state older than restart', () {
    final state = LocalSyncState();
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Set auth
    state.setAuth('auth123');
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Restart before we get results. This should flip synced to false.
    state.restart();
    expect(state.hasSyncedPastLastReconnect(), isFalse);

    // Mark auth completion
    state.markAuthCompletion();
    expect(state.hasSyncedPastLastReconnect(), isTrue);
  });

  test('cleared auth resets outstanding state older than restart', () {
    final state = LocalSyncState();
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Set auth
    state.setAuth('auth123');
    expect(state.hasSyncedPastLastReconnect(), isTrue);

    // Restart before we get results. This should flip synced to false.
    state.restart();
    expect(state.hasSyncedPastLastReconnect(), isFalse);

    // Mark auth cleared
    state.clearAuth();
    expect(state.hasSyncedPastLastReconnect(), isTrue);
  });

  test('a journal from the server is re-sent on restart', () {
    final state = LocalSyncState();
    final queryId = state.subscribe('hello:world', {}).modification!;
    final id = queryId.modifications.single.json['queryId']! as int;
    expect(queryId.modifications.single.json.containsKey('journal'), isFalse);

    state.transition(
      transition(
        startVersion: stateVersion(ts: 0),
        endVersion: stateVersion(ts: 1),
        modifications: [
          {
            'type': 'QueryUpdated',
            'queryId': id,
            'value': 1,
            'logLines': <String>[],
            'journal': 'cursor',
          },
        ],
      ),
    );
    final (querySet, authenticate) = state.restart();
    expect(querySet.modifications.single.json['journal'], 'cursor');
    expect(authenticate, isNull);
  });
}
