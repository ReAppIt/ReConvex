// Ported from convex/src/browser/sync/client_node_test_helpers.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/paginated_query_client.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:web_socket/web_socket.dart';

/// The server side of one fake WebSocket connection.
class FakeServerSocket implements WebSocket {
  FakeServerSocket._(this._onClientText);

  final void Function(String text) _onClientText;
  final StreamController<WebSocketEvent> _events = StreamController();
  bool _closed = false;

  /// Whether the client closed this socket.
  bool closedByClient = false;

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => '';

  @override
  void sendText(String s) {
    if (_closed) throw WebSocketConnectionClosed();
    _onClientText(s);
  }

  @override
  void sendBytes(Uint8List b) {
    if (_closed) throw WebSocketConnectionClosed();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) throw WebSocketConnectionClosed();
    // Like IOWebSocket: a local close ends `events` without CloseReceived.
    _closed = true;
    closedByClient = true;
    unawaited(_events.close());
  }

  /// Sends [text] to the client.
  void serverSend(String text) {
    if (!_closed) _events.add(TextDataReceived(text));
  }

  /// Closes the connection from the server side.
  void serverClose([int? code = 1005, String reason = '']) {
    if (_closed) return;
    _closed = true;
    _events.add(CloseReceived(code, reason));
    unawaited(_events.close());
  }
}

/// A fake Convex deployment that accepts every WebSocket connection.
class InMemoryWebSocket {
  /// The deployment address to give the client.
  final String address = 'http://127.0.0.1:3210';

  /// Every URI the client connected to.
  final List<Uri> connectedUris = [];

  /// Fails the next connection attempt.
  bool failNextConnect = false;

  final List<String> _received = [];
  final List<Completer<String>> _waiters = [];
  FakeServerSocket? _socket;

  /// The current server socket.
  FakeServerSocket? socket() => _socket;

  /// Connects a client socket; pass as `webSocketConstructor`.
  Future<WebSocket> webSocketConstructor(Uri uri) async {
    connectedUris.add(uri);
    if (failNextConnect) {
      failNextConnect = false;
      throw WebSocketException('connection refused');
    }
    final socket = FakeServerSocket._(_onClientText);
    _socket = socket;
    return socket;
  }

  void _onClientText(String text) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(text);
    } else {
      _received.add(text);
    }
  }

  /// The next message the client sent, across sockets.
  Future<JsonMap> receive({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String text;
    if (_received.isNotEmpty) {
      text = _received.removeAt(0);
    } else {
      final completer = Completer<String>();
      _waiters.add(completer);
      text = await completer.future.timeout(timeout);
    }
    return jsonDecode(text) as JsonMap;
  }

  /// The next buffered client message, or `null`; for `fakeAsync` tests.
  JsonMap? tryReceive() =>
      _received.isEmpty ? null : jsonDecode(_received.removeAt(0)) as JsonMap;

  /// Sends [message] to the client on the current socket.
  void send(JsonMap message) => _socket!.serverSend(jsonEncode(message));

  /// Closes the current socket from the server side.
  void close([int? code = 1005, String reason = '']) =>
      _socket!.serverClose(code, reason);
}

/// Runs [cb] against a fresh [InMemoryWebSocket].
Future<void> withInMemoryWebSocket(
  Future<void> Function(InMemoryWebSocket ws) cb,
) async {
  final ws = InMemoryWebSocket();
  try {
    await cb(ws);
  } finally {
    final socket = ws.socket();
    if (socket != null && !socket._closed) {
      socket.serverClose(1000);
    }
  }
}

/// The client's local results, recorded for each transition.
///
/// Values are `({Object? value})?` records; `null` means loading.
class UpdateQueue {
  /// Creates a queue for [maxLength] updates.
  UpdateQueue([int maxLength = 10])
    : _completers = [
        for (var i = 0; i < maxLength; i++)
          Completer<Map<QueryToken, ({Object? value})?>>(),
      ];

  final List<Completer<Map<QueryToken, ({Object? value})?>>> _completers;

  /// Every update in order.
  final List<Map<QueryToken, ({Object? value})?>> updates = [];

  /// The latest value of every token.
  final Map<QueryToken, ({Object? value})?> allResults = {};

  /// The index of the next update.
  int nextIndex = 0;

  /// The update at [i], failing after a second instead of hanging.
  Future<Map<QueryToken, ({Object? value})?>> awaitPromiseAtIndexWithTimeout(
    int i,
  ) => _completers[i].future.timeout(
    const Duration(seconds: 1),
    onTimeout: () => throw TimeoutException('Awaiting promise in UpdateQueue'),
  );

  /// The update at [i].
  Future<Map<QueryToken, ({Object? value})?>> updatePromise(int i) =>
      _completers[i].future;

  /// An `onTransition` callback recording the results of [client].
  void Function(List<QueryToken> updatedQueryTokens) onTransition(
    BaseConvexClient client, [
    PaginatedQueryClient? paginatedClient,
  ]) => (updatedQueryTokens) {
    final update = <QueryToken, ({Object? value})?>{};
    for (final queryToken in updatedQueryTokens) {
      final ({Object? value})? value;
      if (serializedQueryTokenIsPaginated(queryToken)) {
        if (paginatedClient == null) {
          throw StateError(
            'No PaginatedQueryClient provided to look up value for token '
            '$queryToken',
          );
        }
        final result = paginatedClient.localQueryResultByToken(
          PaginatedQueryToken(queryToken),
        );
        value = result == null ? null : (value: result);
      } else {
        value = client.localQueryResultByToken(queryToken);
      }
      update[queryToken] = value;
      allResults[queryToken] = value;
    }
    _completers[nextIndex].complete(update);
    updates.add(update);
    nextIndex++;
  };
}

/// The query token of [udfPath] without arguments, as upstream spells it.
QueryToken token(String udfPath) =>
    QueryToken('{"udfPath":"$udfPath","args":{}}');

/// A `QueryUpdated` modification.
JsonMap queryUpdated(int queryId, Object? value) => {
  'type': 'QueryUpdated',
  'queryId': queryId,
  'value': value,
  'logLines': <String>[],
  'journal': null,
};

/// Polls [condition] every 50 ms, up to a second.
Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 20; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
