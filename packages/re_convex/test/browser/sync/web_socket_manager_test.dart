import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/browser/sync/web_socket_manager.dart';

import '../../support/client_node_test_helpers.dart';
import '../../support/fakes.dart';

// nextDouble() == 0.5 makes the jitter zero.
class _FixedRandom implements Random {
  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

typedef _Started = ({WebSocketManager manager, List<String> events});

_Started _start(
  InMemoryWebSocket ws, {
  bool synced = true,
  SubscribeToOnline? subscribeToOnline,
}) {
  final events = <String>[];
  final manager = WebSocketManager(
    Uri.parse('ws://127.0.0.1:3210/api/1.46.0/sync'),
    onOpen: (meta) =>
        events.add('open:${meta.connectionCount}:${meta.lastCloseReason}'),
    onResume: () => events.add('resume'),
    onMessage: (message) {
      events.add('message:${message.type}');
      return (hasSyncedPastLastReconnect: synced);
    },
    webSocketConstructor: ws.webSocketConstructor,
    logger: instantiateNoopLogger(),
    markConnectionStateDirty: () {},
    debug: false,
    subscribeToOnline: subscribeToOnline,
    random: _FixedRandom(),
  );
  return (manager: manager, events: events);
}

void _elapse(FakeAsync async, int milliseconds) {
  async
    ..elapse(Duration(milliseconds: milliseconds))
    ..flushMicrotasks();
}

void main() {
  test('backs off by the close reason, doubling each retry', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, :events) = _start(ws, synced: false);
      async.flushMicrotasks();
      expect(events, ['open:0:InitialConnect']);

      ws.close(1011, 'InternalServerError');
      async.flushMicrotasks();
      expect(manager.socketState(), 'disconnected');
      _elapse(async, 999);
      expect(ws.connectedUris, hasLength(1));
      _elapse(async, 1);
      expect(ws.connectedUris, hasLength(2));
      expect(events.last, 'open:1:InternalServerError');

      // The next failure doubles the backoff.
      ws.close(1011, 'InternalServerError');
      async.flushMicrotasks();
      _elapse(async, 1999);
      expect(ws.connectedUris, hasLength(2));
      _elapse(async, 1);
      expect(ws.connectedUris, hasLength(3));

      // Overload errors start at 3 seconds.
      ws.close(1011, 'SubscriptionsWorkerFullError: busy');
      async.flushMicrotasks();
      _elapse(async, 3 * 4 * 1000 - 1);
      expect(ws.connectedUris, hasLength(3));
      _elapse(async, 1);
      expect(ws.connectedUris, hasLength(4));
      expect(manager.connectionState().connectionRetries, 3);

      // Unknown reasons start at 1 second; the backoff is capped at 16 seconds.
      for (final (index, backoff) in [8000, 16000, 16000].indexed) {
        ws.close();
        async.flushMicrotasks();
        _elapse(async, backoff - 1);
        expect(ws.connectedUris, hasLength(4 + index));
        _elapse(async, 1);
        expect(ws.connectedUris, hasLength(5 + index));
      }

      unawaited(manager.terminate());
      async.flushMicrotasks();
    });
  });

  test('resets the retries once a message shows the client re-synced', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, events: _) = _start(ws);
      async.flushMicrotasks();
      ws.close();
      async.flushMicrotasks();
      _elapse(async, 1000);
      expect(manager.connectionState().connectionRetries, 1);

      ws.send({'type': 'Ping'});
      async.flushMicrotasks();
      expect(manager.connectionState().connectionRetries, 1);

      ws.send(transitionJson());
      async.flushMicrotasks();
      expect(manager.connectionState().connectionRetries, 0);

      unawaited(manager.terminate());
      async.flushMicrotasks();
    });
  });

  test('reconnects after 60s without server messages', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, :events) = _start(ws);
      async.flushMicrotasks();

      // A ping resets the inactivity timer.
      _elapse(async, 59999);
      ws.send({'type': 'Ping'});
      async.flushMicrotasks();
      _elapse(async, 59999);
      expect(ws.connectedUris, hasLength(1));

      _elapse(async, 1);
      expect(ws.socket()!.closedByClient, isTrue);
      // Client-side reasons retry after 100 ms.
      _elapse(async, 100);
      expect(ws.connectedUris, hasLength(2));
      expect(events.last, 'open:1:InactiveServer');

      unawaited(manager.terminate());
      async.flushMicrotasks();
    });
  });

  test('reconnects at once when the network comes back', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      void Function()? onOnline;
      var unsubscribed = false;
      final (:manager, events: _) = _start(
        ws,
        subscribeToOnline: (callback) {
          onOnline = callback;
          return () => unsubscribed = true;
        },
      );
      async.flushMicrotasks();

      ws.close();
      async.flushMicrotasks();
      _elapse(async, 200);
      expect(ws.connectedUris, hasLength(1));

      onOnline!();
      async.flushMicrotasks();
      expect(ws.connectedUris, hasLength(2));

      JsonMap? event;
      unawaited(ws.receive().then((message) => event = message));
      async.flushMicrotasks();
      expect(event?['type'], 'Event');
      expect(event?['eventType'], 'NetworkRecoveryReconnect');
      expect((event?['event']! as Map)['timeSavedMs'], 800);

      unawaited(manager.terminate());
      async.flushMicrotasks();
      expect(unsubscribed, isTrue);
    });
  });

  test('holds onOpen while paused, then resumes', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, :events) = _start(ws);
      manager.pause();
      async.flushMicrotasks();
      expect(manager.socketState(), 'ready');
      expect(events, isEmpty);

      // Like upstream, the paused open already counted the connection.
      manager.resume();
      expect(events, ['open:1:null']);

      manager.pause();
      expect(manager.sendMessage(Event(eventType: 'x', event: null)), isFalse);
      manager.resume();
      expect(events.last, 'resume');

      unawaited(manager.terminate());
      async.flushMicrotasks();
    });
  });

  test('stop closes the socket until tryRestart', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, events: _) = _start(ws);
      async.flushMicrotasks();

      var stopped = false;
      unawaited(manager.stop().then((_) => stopped = true));
      async.flushMicrotasks();
      expect(stopped, isTrue);
      expect(manager.socketState(), 'stopped');
      _elapse(async, 20000);
      expect(ws.connectedUris, hasLength(1));

      manager.tryRestart();
      async.flushMicrotasks();
      expect(manager.socketState(), 'ready');
      expect(ws.connectedUris, hasLength(2));

      unawaited(manager.terminate());
      async.flushMicrotasks();
    });
  });

  test('terminate never reconnects and leaves no timers', () {
    fakeAsync((async) {
      final ws = InMemoryWebSocket();
      final (:manager, events: _) = _start(ws);
      async.flushMicrotasks();
      ws.close();
      async.flushMicrotasks();

      unawaited(manager.terminate());
      async.flushMicrotasks();
      _elapse(async, 60000);
      expect(ws.connectedUris, hasLength(1));
      expect(manager.socketState(), 'terminated');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('rejects out-of-order TransitionChunks and clears the buffer', () {
    fakeAsync((async) {
      final errors = <Object>[];
      late _Started started;
      final ws = InMemoryWebSocket();
      runZonedGuarded(() => started = _start(ws), (e, _) => errors.add(e));
      async.flushMicrotasks();

      final json = jsonEncode(transitionJson());
      ws.send({
        'type': 'TransitionChunk',
        'chunk': json.substring(json.length ~/ 2),
        'partNumber': 1,
        'totalParts': 2,
        'transitionId': 'a',
      });
      async.flushMicrotasks();
      expect(errors.single, isFormatException);

      // A fresh, complete transition still goes through.
      ws
        ..send({
          'type': 'TransitionChunk',
          'chunk': json.substring(0, json.length ~/ 2),
          'partNumber': 0,
          'totalParts': 2,
          'transitionId': 'b',
        })
        ..send({
          'type': 'TransitionChunk',
          'chunk': json.substring(json.length ~/ 2),
          'partNumber': 1,
          'totalParts': 2,
          'transitionId': 'b',
        });
      async.flushMicrotasks();
      expect(started.events.last, 'message:Transition');

      unawaited(started.manager.terminate());
      async.flushMicrotasks();
    });
  });
}
