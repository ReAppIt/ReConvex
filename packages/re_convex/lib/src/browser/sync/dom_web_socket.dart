import 'dart:async';

import 'package:web_socket/web_socket.dart';

/// Opens a WebSocket to [uri] (`webSocketConstructor` upstream).
///
/// Defaults to dart:io's; `CupertinoWebSocket.connect` uses NSURLSession.
typedef WebSocketConstructor = Future<WebSocket> Function(Uri uri);

enum _ReadyState { connecting, open, closing, closed }

/// The browser `WebSocket` API over a package:web_socket connection, so the
/// WebSocket manager reads like upstream's.
///
/// [onclose] fires exactly once, also when connecting fails (code 1006).
class DomWebSocket {
  /// Starts connecting to [uri].
  DomWebSocket(Uri uri, WebSocketConstructor connect) {
    unawaited(_connect(uri, connect));
  }

  /// Called once the connection is open.
  void Function()? onopen;

  /// Called with each text message.
  void Function(String data)? onmessage;

  /// Called with transport errors; [onclose] follows.
  void Function(Object error)? onerror;

  /// Called once with the close code and reason.
  void Function(int code, String reason)? onclose;

  static const Duration _closeTimeout = Duration(seconds: 5);

  _ReadyState _readyState = _ReadyState.connecting;
  WebSocket? _ws;
  Timer? _closeTimer;

  Future<void> _connect(Uri uri, WebSocketConstructor connect) async {
    final WebSocket ws;
    try {
      ws = await connect(uri);
    } on Object catch (error) {
      if (_readyState == _ReadyState.closed) return;
      onerror?.call(error);
      _fireClose(1006, '');
      return;
    }
    _ws = ws;
    if (_readyState == _ReadyState.closing) {
      // close() was called while connecting.
      unawaited(_closeQuietly(ws));
      _fireClose(1006, '');
      return;
    }
    _readyState = _ReadyState.open;
    ws.events.listen(
      _onEvent,
      onError: (Object error) => onerror?.call(error),
      onDone: () =>
          _fireClose(_readyState == _ReadyState.closing ? 1005 : 1006, ''),
    );
    onopen?.call();
  }

  void _onEvent(WebSocketEvent event) {
    switch (event) {
      case TextDataReceived(:final text):
        if (_readyState != _ReadyState.closed) onmessage?.call(text);
      case BinaryDataReceived():
        // The sync protocol only sends text frames.
        break;
      case CloseReceived(:final code, :final reason):
        _fireClose(code ?? 1006, reason);
    }
  }

  /// Sends [data]; data sent while closing is dropped, as browsers do.
  void send(String data) {
    switch (_readyState) {
      case _ReadyState.connecting:
        throw StateError('WebSocket is not open yet');
      case _ReadyState.open:
        try {
          _ws!.sendText(data);
        } on WebSocketConnectionClosed {
          // The close event is on its way.
        }
      case _ReadyState.closing:
      case _ReadyState.closed:
        return;
    }
  }

  /// Starts closing; [onclose] fires once closed (code 1005).
  void close() {
    switch (_readyState) {
      case _ReadyState.connecting:
        _readyState = _ReadyState.closing;
      case _ReadyState.open:
        _readyState = _ReadyState.closing;
        final ws = _ws!;
        _closeTimer = Timer(_closeTimeout, () => _fireClose(1006, ''));
        unawaited(_closeQuietly(ws).then((_) => _fireClose(1005, '')));
      case _ReadyState.closing:
      case _ReadyState.closed:
        return;
    }
  }

  Future<void> _closeQuietly(WebSocket ws) async {
    try {
      await ws.close();
    } on WebSocketConnectionClosed {
      // Already closed.
    } on WebSocketException {
      // The connection is gone either way.
    }
  }

  void _fireClose(int code, String reason) {
    if (_readyState == _ReadyState.closed) return;
    _readyState = _ReadyState.closed;
    _closeTimer?.cancel();
    onclose?.call(code, reason);
  }
}
