// Ported from convex/src/browser/sync/web_socket_manager.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/dom_web_socket.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';

const int _closeNormal = 1000;
const int _closeGoingAway = 1001;
const int _closeNoStatus = 1005;

/// Convex's "404 Not Found": the edge accepts the upgrade before it knows the
/// destination exists.
const int _closeNotFound = 4040;

/// Subscribes to "the network came back" events, returning an unsubscribe
/// function; it stands in for the browser's `online` event.
typedef SubscribeToOnline = void Function() Function(void Function() onOnline);

enum _Paused { yes, no, uninitialized }

// Disconnected, connecting, ready, stopped or terminated; some can pause.
sealed class _Socket {
  const _Socket();

  String get state;
}

final class _Disconnected extends _Socket {
  const _Disconnected();

  @override
  String get state => 'disconnected';
}

final class _Connecting extends _Socket {
  const _Connecting(this.ws, this.paused);

  final DomWebSocket ws;
  final _Paused paused;

  @override
  String get state => 'connecting';
}

final class _Ready extends _Socket {
  const _Ready(this.ws, this.paused);

  final DomWebSocket ws;
  final _Paused paused;

  @override
  String get state => 'ready';
}

final class _Stopped extends _Socket {
  const _Stopped();

  @override
  String get state => 'stopped';
}

final class _Terminated extends _Socket {
  const _Terminated();

  @override
  String get state => 'terminated';
}

/// What `onOpen` learns about the new connection.
typedef ReconnectMetadata = ({
  int connectionCount,
  String? lastCloseReason,
  int clientTs,
});

/// What `onMessage` reports back.
typedef OnMessageResponse = ({bool hasSyncedPastLastReconnect});

const Map<String, Duration> _serverDisconnectErrors = {
  // A known error, e.g. during a restart or push
  'InternalServerError': Duration(milliseconds: 1000),
  // ErrorMetadata::overloaded() messages that we really should back off
  'SubscriptionsWorkerFullError': Duration(milliseconds: 3000),
  'TooManyConcurrentRequests': Duration(milliseconds: 3000),
  'CommitterFullError': Duration(milliseconds: 3000),
  'AwsTooManyRequestsException': Duration(milliseconds: 3000),
  'ExecuteFullError': Duration(milliseconds: 3000),
  'SystemTimeoutError': Duration(milliseconds: 3000),
  'ExpiredInQueue': Duration(milliseconds: 3000),
  // ErrorMetadata::feature_temporarily_unavailable() that typically indicate a deploy just happened
  'VectorIndexesUnavailable': Duration(milliseconds: 1000),
  'SearchIndexesUnavailable': Duration(milliseconds: 1000),
  'TableSummariesUnavailable': Duration(milliseconds: 1000),
  // More ErrorMetadata::overloaded()
  'VectorIndexTooLarge': Duration(milliseconds: 3000),
  'SearchIndexTooLarge': Duration(milliseconds: 3000),
  'TooManyWritesInTimePeriod': Duration(milliseconds: 3000),
};

String _classifyDisconnectError(String? s) {
  if (s == null) return 'Unknown';
  // startsWith so more info could be at the end (although currently there isn't)
  for (final prefix in _serverDisconnectErrors.keys) {
    if (s.startsWith(prefix)) {
      return prefix;
    }
  }
  return 'Unknown';
}

/// A wrapper around a WebSocket that handles errors, reconnection, and
/// message parsing.
class WebSocketManager {
  /// Starts connecting right away.
  WebSocketManager(
    this._uri, {
    required void Function(ReconnectMetadata reconnectMetadata) onOpen,
    required void Function() onResume,
    required OnMessageResponse Function(ServerMessage message) onMessage,
    required WebSocketConstructor webSocketConstructor,
    required ConvexLogger logger,
    required void Function() markConnectionStateDirty,
    required bool debug,
    void Function(String message)? onServerDisconnectError,
    SubscribeToOnline? subscribeToOnline,
    Random? random,
  }) : _onOpen = onOpen,
       _onResume = onResume,
       _onMessage = onMessage,
       _webSocketConstructor = webSocketConstructor,
       _logger = logger,
       _markConnectionStateDirty = markConnectionStateDirty,
       _debug = debug,
       _onServerDisconnectError = onServerDisconnectError,
       _subscribeToOnline = subscribeToOnline,
       _random = random ?? Random() {
    // Set up network online event listener
    _setupNetworkListener();
    _connect();
  }

  final Uri _uri;
  final void Function(ReconnectMetadata reconnectMetadata) _onOpen;
  final void Function() _onResume;
  final OnMessageResponse Function(ServerMessage message) _onMessage;
  final WebSocketConstructor _webSocketConstructor;
  final ConvexLogger _logger;
  final void Function() _markConnectionStateDirty;
  final bool _debug;
  final void Function(String message)? _onServerDisconnectError;
  final SubscribeToOnline? _subscribeToOnline;
  final Random _random;

  _Socket _socket = const _Disconnected();

  int _connectionCount = 0;
  bool _hasEverConnected = false;
  // "InitialConnect", a client-side reason, a server close reason, or null.
  String? _lastCloseReason = 'InitialConnect';

  // The split-up Transition currently being received.
  ({List<String> chunks, int totalParts, String transitionId})?
  _transitionChunkBuffer;

  /// Upon HTTPS/WSS failure, the first jittered backoff duration.
  static const Duration _defaultInitialBackoff = Duration(milliseconds: 1000);

  /// We back off exponentially, but cap it: this is the jittered max.
  static const Duration _maxBackoff = Duration(milliseconds: 16000);

  /// How many times have we failed consecutively?
  int _retries = 0;

  /// Sync protocol Pings arrive every 15s without other messages, but one
  /// large Transition can hog the line, so this threshold is higher.
  static const Duration _serverInactivityThreshold = Duration(
    milliseconds: 60000,
  );

  Timer? _reconnectDueToServerInactivityTimeout;

  ({Timer timer, int scheduledAt, double backoffMs})? _scheduledReconnect;

  void Function()? _networkOnlineUnsubscribe;

  /// Pending event to send after reconnecting due to network recovery.
  ({double timeSavedMs})? _pendingNetworkRecoveryInfo;

  final int _firstTime = clock.now().millisecondsSinceEpoch;
  final Stopwatch _monotonic = clock.stopwatch()..start();

  int _monotonicMillis() => _firstTime + _monotonic.elapsedMilliseconds;

  String _prettyNow() =>
      't=${((_monotonicMillis() - _firstTime) / 100).round() / 10}s';

  void _setSocketState(_Socket state) {
    _socket = state;
    _logVerbose(
      'socket state changed: ${_socket.state}, paused: ${_pausedOf(_socket)}',
    );
    _markConnectionStateDirty();
  }

  static String? _pausedOf(_Socket socket) => switch (socket) {
    _Connecting(:final paused) || _Ready(:final paused) => paused.name,
    _ => null,
  };

  void _setupNetworkListener() {
    final subscribeToOnline = _subscribeToOnline;
    if (subscribeToOnline == null) {
      return;
    }
    // Avoid registering duplicate listeners
    if (_networkOnlineUnsubscribe != null) {
      return;
    }
    _networkOnlineUnsubscribe = subscribeToOnline(() {
      _logVerbose('network online event detected');
      tryReconnectImmediately();
    });
    _logVerbose('network online event listener registered');
  }

  void _cleanupNetworkListener() {
    final unsubscribe = _networkOnlineUnsubscribe;
    if (unsubscribe != null) {
      unsubscribe();
      _networkOnlineUnsubscribe = null;
      _logVerbose('network online event listener removed');
    }
  }

  Transition? _assembleTransition(TransitionChunk chunk) {
    final buffer = _transitionChunkBuffer;
    if (chunk.partNumber < 0 ||
        chunk.partNumber >= chunk.totalParts ||
        chunk.totalParts == 0 ||
        (buffer != null &&
            (buffer.totalParts != chunk.totalParts ||
                buffer.transitionId != chunk.transitionId))) {
      // Throwing an error doesn't crash the client, so clear the buffer.
      _transitionChunkBuffer = null;
      throw const FormatException('Invalid TransitionChunk');
    }

    final current = _transitionChunkBuffer ??= (
      chunks: <String>[],
      totalParts: chunk.totalParts,
      transitionId: chunk.transitionId,
    );

    if (chunk.partNumber != current.chunks.length) {
      // Throwing an error doesn't crash the client, so clear the buffer.
      final expectedLength = current.chunks.length;
      _transitionChunkBuffer = null;
      throw FormatException(
        'TransitionChunk received out of order: expected part '
        '$expectedLength, got ${chunk.partNumber}',
      );
    }

    current.chunks.add(chunk.chunk);

    if (current.chunks.length == chunk.totalParts) {
      final fullJson = current.chunks.join();
      _transitionChunkBuffer = null;

      final transition = parseServerMessage(jsonDecode(fullJson) as JsonMap);
      if (transition.type != 'Transition') {
        throw FormatException(
          'Expected Transition, got ${transition.type} after assembling chunks',
        );
      }
      return Transition(transition.json);
    }

    return null;
  }

  void _connect() {
    if (_socket is _Terminated) {
      return;
    }
    if (_socket is! _Disconnected && _socket is! _Stopped) {
      throw StateError(
        "Didn't start connection from disconnected state: ${_socket.state}",
      );
    }

    final ws = DomWebSocket(_uri, _webSocketConstructor);
    _logVerbose('constructed WebSocket');
    _setSocketState(_Connecting(ws, _Paused.no));

    // Start the inactivity timer before connecting, to catch bad handshakes.
    _resetServerInactivityTimeout();

    ws
      ..onopen = () {
        _logger.logVerbose('begin ws.onopen');
        final socket = _socket;
        if (socket is! _Connecting) {
          throw StateError('onopen called with socket not in connecting state');
        }
        _setSocketState(
          _Ready(
            ws,
            socket.paused == _Paused.yes ? _Paused.uninitialized : _Paused.no,
          ),
        );
        _resetServerInactivityTimeout();
        if (socket.paused == _Paused.no) {
          _hasEverConnected = true;
          _onOpen((
            connectionCount: _connectionCount,
            lastCloseReason: _lastCloseReason,
            clientTs: _monotonicMillis(),
          ));
        }

        if (_lastCloseReason != 'InitialConnect') {
          if (_lastCloseReason != null) {
            _logger.log(
              'WebSocket reconnected at ${_prettyNow()} after disconnect '
              'due to $_lastCloseReason',
            );
          } else {
            _logger.log('WebSocket reconnected at ${_prettyNow()}');
          }
        }

        _connectionCount += 1;
        _lastCloseReason = null;

        // Send event for network recovery reconnect if applicable
        final recovery = _pendingNetworkRecoveryInfo;
        if (recovery != null) {
          _pendingNetworkRecoveryInfo = null;
          sendMessage(
            Event(
              eventType: 'NetworkRecoveryReconnect',
              event: {'timeSavedMs': recovery.timeSavedMs},
            ),
          );
          _logger.log(
            'Network recovery reconnect saved '
            '~${(recovery.timeSavedMs / 1000).round()}s of waiting',
          );
        }
      }
      // onclose fires even when connecting fails, so errors all go through it.
      ..onerror = (error) {
        _transitionChunkBuffer = null;
        _logger.log('WebSocket error message: $error');
      }
      ..onmessage = (data) {
        _resetServerInactivityTimeout();
        final messageLength = data.length;
        var serverMessage = parseServerMessage(jsonDecode(data) as JsonMap);
        _logVerbose('received ws message with type ${serverMessage.type}');

        // Ping's only purpose is to reset the server inactivity timer.
        if (serverMessage.type == 'Ping') {
          return;
        }

        // TransitionChunks never reach the main client logic.
        if (serverMessage.type == 'TransitionChunk') {
          final transition = _assembleTransition(
            TransitionChunk(serverMessage.json),
          );
          if (transition == null) {
            return;
          }
          serverMessage = transition;
          _logVerbose(
            'assembled full ws message of type ${serverMessage.type}',
          );
        }

        if (_transitionChunkBuffer != null) {
          _transitionChunkBuffer = null;
          _logger.log(
            'Received unexpected ${serverMessage.type} while buffering '
            'TransitionChunks',
          );
        }

        if (serverMessage.type == 'Transition') {
          _reportLargeTransition(
            messageLength: messageLength,
            transition: Transition(serverMessage.json),
          );
        }
        final response = _onMessage(ServerMessage(serverMessage.json));
        if (response.hasSyncedPastLastReconnect) {
          // Reset backoff to 0 once all outstanding requests are complete.
          _retries = 0;
          _markConnectionStateDirty();
        }
      }
      ..onclose = (code, reason) {
        _logVerbose('begin ws.onclose');
        _transitionChunkBuffer = null;
        // reason is often an empty string
        _lastCloseReason ??= reason.isNotEmpty
            ? reason
            : 'closed with code $code';
        if (code != _closeNormal &&
            // This commonly gets fired on mobile apps when the app is backgrounded
            code != _closeGoingAway &&
            code != _closeNoStatus &&
            // We want to retry on a 404, as it can be transient during a push.
            code != _closeNotFound) {
          var msg = 'WebSocket closed with code $code';
          if (reason.isNotEmpty) {
            msg += ': $reason';
          }
          _logger.log(msg);
          final onServerDisconnectError = _onServerDisconnectError;
          if (onServerDisconnectError != null && reason.isNotEmpty) {
            // Unstable API; InternalServerErrors may be dropped.
            onServerDisconnectError(msg);
          }
        }
        _scheduleReconnect(_classifyDisconnectError(reason));
      };
  }

  /// The state of the socket: `disconnected`, `connecting`, `ready`,
  /// `stopped` or `terminated`.
  String socketState() => _socket.state;

  /// Sends [message]; returns whether it might have been sent.
  bool sendMessage(ClientMessage message) {
    final messageForLog = <String, Object?>{
      'type': message.type,
      if (message.type == 'Authenticate' && message.json['tokenType'] == 'User')
        'value': '...${_last7(message.json['value']! as String)}',
    };
    final socket = _socket;
    if (socket is _Ready && socket.paused == _Paused.no) {
      final encodedMessage = encodeClientMessage(message);
      final request = jsonEncode(encodedMessage);
      var sent = false;
      try {
        socket.ws.send(request);
        sent = true;
      } on Object catch (error) {
        _logger.log(
          'Failed to send message on WebSocket, reconnecting: $error',
        );
        _closeAndReconnect('FailedToSendMessage');
      }
      _logVerbose(
        '${sent ? 'sent' : 'failed to send'} message with type '
        '${message.type}: ${jsonEncode(messageForLog)}',
      );
      return true;
    }
    _logVerbose(
      'message not sent (socket state: ${_socket.state}, paused: '
      '${_pausedOf(_socket)}): ${jsonEncode(messageForLog)}',
    );
    return false;
  }

  static String _last7(String value) =>
      value.length <= 7 ? value : value.substring(value.length - 7);

  void _resetServerInactivityTimeout() {
    if (_socket is _Terminated) {
      // Don't reset any timers if we were trying to terminate.
      return;
    }
    _reconnectDueToServerInactivityTimeout?.cancel();
    _reconnectDueToServerInactivityTimeout = Timer(
      _serverInactivityThreshold,
      () => _closeAndReconnect('InactiveServer'),
    );
  }

  void _scheduleReconnect(String reason) {
    // Cancel any existing scheduled reconnect to avoid multiple reconnects
    _scheduledReconnect?.timer.cancel();
    _scheduledReconnect = null;

    _socket = const _Disconnected();
    final backoff = _nextBackoff(reason);
    _markConnectionStateDirty();
    _logger.log('Attempting reconnect in ${backoff.round()}ms');

    final scheduledAt = _monotonicMillis();
    late final Timer timer;
    timer = Timer(Duration(microseconds: (backoff * 1000).round()), () {
      // Only proceed if this timer hasn't been replaced
      if (identical(_scheduledReconnect?.timer, timer)) {
        _scheduledReconnect = null;
        _connect();
      }
    });

    _scheduledReconnect = (
      timer: timer,
      scheduledAt: scheduledAt,
      backoffMs: backoff,
    );
  }

  /// Closes the WebSocket and schedules a reconnect, after an error.
  void _closeAndReconnect(String closeReason) {
    _logVerbose('begin closeAndReconnect with reason $closeReason');
    switch (_socket) {
      case _Disconnected():
      case _Terminated():
      case _Stopped():
        // Nothing to do if we don't have a WebSocket.
        return;
      case _Connecting():
      case _Ready():
        _lastCloseReason = closeReason;
        // Close the old socket asynchronously, we'll open a new socket in reconnect.
        unawaited(_close());
        _scheduleReconnect('client');
        return;
    }
  }

  /// Closes the WebSocket without its `onclose` reconnecting.
  ///
  /// Callers update the state afterwards so the closed socket isn't used.
  Future<void> _close() {
    _transitionChunkBuffer = null;
    switch (_socket) {
      case _Disconnected():
      case _Terminated():
      case _Stopped():
        // Nothing to do if we don't have a WebSocket.
        return Future.value();
      case _Connecting(:final ws):
        final completer = Completer<void>();
        // Messages can still be received after close but we're not interested.
        ws
          ..onmessage = (_) {
            _logVerbose('Ignoring message received after close');
          }
          ..onclose = (_, _) {
            _logVerbose('Closed after connecting');
            completer.complete();
          }
          ..onopen = () {
            _logVerbose('Opened after connecting');
            ws.close();
          };
        return completer.future;
      case _Ready(:final ws):
        _logVerbose('ws.close called');
        final completer = Completer<void>();
        // Messages can still be received after close but we're not interested.
        ws
          ..onmessage = (_) {
            _logVerbose('Ignoring message received after close');
          }
          ..onclose = (_, _) {
            completer.complete();
          }
          ..close();
        return completer.future;
    }
  }

  /// Closes the WebSocket and never reconnects; completes once it closed.
  Future<void> terminate() {
    _reconnectDueToServerInactivityTimeout?.cancel();
    _scheduledReconnect?.timer.cancel();
    _scheduledReconnect = null;
    _cleanupNetworkListener();
    final result = _close();
    _setSocketState(const _Terminated());
    return result;
  }

  /// Closes the WebSocket until [tryRestart].
  Future<void> stop() {
    switch (_socket) {
      case _Terminated():
        // If we're terminating we ignore stop
        return Future.value();
      case _Connecting():
      case _Stopped():
      case _Disconnected():
      case _Ready():
        _cleanupNetworkListener();
        final result = _close();
        _socket = const _Stopped();
        return result;
    }
  }

  /// Creates a new WebSocket after a previous [stop], unless [terminate] was
  /// called before.
  void tryRestart() {
    switch (_socket) {
      case _Stopped():
        break;
      case _Terminated():
      case _Connecting():
      case _Ready():
      case _Disconnected():
        _logger.logVerbose('Restart called without stopping first');
        return;
    }
    _setupNetworkListener();
    _connect();
  }

  /// Holds outgoing messages until [resume].
  void pause() {
    switch (_socket) {
      case _Disconnected():
      case _Stopped():
      case _Terminated():
        // If already stopped or stopping ignore.
        return;
      case _Connecting(:final ws):
        _socket = _Connecting(ws, _Paused.yes);
      case _Ready(:final ws):
        _socket = _Ready(ws, _Paused.yes);
    }
  }

  /// Reconnects right away, cancelling a scheduled reconnect, when waiting
  /// to reconnect; used when the network comes back.
  void tryReconnectImmediately() {
    _logVerbose('tryReconnectImmediately called');

    // Only reconnect if we're in disconnected state (waiting to reconnect)
    if (_socket is! _Disconnected) {
      _logVerbose(
        'tryReconnectImmediately called but socket state is ${_socket.state}, '
        'no action taken',
      );
      return;
    }

    // Track how much time we saved by reconnecting immediately
    double? timeSavedMs;
    final scheduled = _scheduledReconnect;
    if (scheduled != null) {
      final elapsed = _monotonicMillis() - scheduled.scheduledAt;
      timeSavedMs = max(0, scheduled.backoffMs - elapsed);
      _logVerbose(
        'would have waited ${timeSavedMs.round()}ms more (backoff was '
        '${scheduled.backoffMs.round()}ms, elapsed ${elapsed}ms)',
      );
      // Cancel the scheduled reconnect
      scheduled.timer.cancel();
      _scheduledReconnect = null;
      _logVerbose('canceled scheduled reconnect');
    }

    _logger.log('Network recovery detected, reconnecting immediately');
    // Store the time saved to send as an event after we connect
    _pendingNetworkRecoveryInfo = timeSavedMs != null
        ? (timeSavedMs: timeSavedMs)
        : null;
    _connect();
  }

  /// Resumes after [pause].
  void resume() {
    final socket = _socket;
    switch (socket) {
      case _Connecting(:final ws):
        _socket = _Connecting(ws, _Paused.no);
        return;
      case _Ready(:final ws, :final paused):
        if (paused == _Paused.uninitialized) {
          _socket = _Ready(ws, _Paused.no);
          _hasEverConnected = true;
          _onOpen((
            connectionCount: _connectionCount,
            lastCloseReason: _lastCloseReason,
            clientTs: _monotonicMillis(),
          ));
        } else if (paused == _Paused.yes) {
          _socket = _Ready(ws, _Paused.no);
          _onResume();
        }
        return;
      case _Terminated():
      case _Stopped():
      case _Disconnected():
        // Ignore resume if not paused, perhaps we already resumed.
        return;
    }
  }

  /// Whether the socket is ready, and its connection counts.
  ({
    bool isConnected,
    bool hasEverConnected,
    int connectionCount,
    int connectionRetries,
  })
  connectionState() => (
    isConnected: _socket is _Ready,
    hasEverConnected: _hasEverConnected,
    connectionCount: _connectionCount,
    connectionRetries: _retries,
  );

  void _logVerbose(String message) {
    _logger.logVerbose(message);
  }

  double _nextBackoff(String reason) {
    final initialBackoff = reason == 'client'
        // There's no evidence of a server problem, retry quickly
        ? const Duration(milliseconds: 100)
        : reason == 'Unknown'
        ? _defaultInitialBackoff
        : _serverDisconnectErrors[reason]!;

    final baseBackoff = initialBackoff.inMilliseconds * pow(2, _retries);
    _retries += 1;
    final actualBackoff = min(
      baseBackoff.toDouble(),
      _maxBackoff.inMilliseconds.toDouble(),
    );
    final jitter = actualBackoff * (_random.nextDouble() - 0.5);
    return actualBackoff + jitter;
  }

  void _reportLargeTransition({
    required Transition transition,
    required int messageLength,
  }) {
    final clientClockSkew = transition.clientClockSkew;
    final serverTs = transition.serverTs;
    if (clientClockSkew == null || serverTs == null) {
      return;
    }

    final transitionTransitTime =
        _monotonicMillis() - // client time now
        // How far behind the client clock is, inflated by Connect's latency.
        clientClockSkew -
        serverTs / 1000000; // server time when transition was sent
    final prettyTransitionTime = '${transitionTransitTime.round()}ms';
    final prettyMessageMB = '${(messageLength / 10000).round() / 100}MB';
    final bytesPerSecond = messageLength / (transitionTransitTime / 1000);
    final prettyBytesPerSecond =
        '${(bytesPerSecond / 10000).round() / 100}MB per second';
    _logVerbose(
      'received $prettyMessageMB transition in $prettyTransitionTime at '
      '$prettyBytesPerSecond',
    );

    // Warnings that will show up for *all users*, so don't be too aggressive.
    if (messageLength > 20000000) {
      // Big enough that the developer should be made aware of this.
      _logger.log(
        'received query results totaling more that 20MB ($prettyMessageMB) '
        'which will take a long time to download on slower connections',
      );
    } else if (transitionTransitTime > 20000) {
      // Weak connections, sleeping or backgrounded apps can cause this too.
      _logger.log(
        'received query results totaling $prettyMessageMB which took more '
        'than 20s to arrive ($prettyTransitionTime)',
      );
    }

    if (_debug) {
      // debug means "reportDebugInfoToConvex" is set so this can be aggressive.
      sendMessage(
        Event(
          eventType: 'ClientReceivedTransition',
          event: {
            'transitionTransitTime': transitionTransitTime.toDouble(),
            'messageLength': messageLength.toDouble(),
          },
        ),
      );
    }
  }
}
