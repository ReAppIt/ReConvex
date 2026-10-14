import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/dom_web_socket.dart';
import 'package:web_socket/web_socket.dart';

void main() {
  late io.HttpServer server;
  late List<io.WebSocket> serverSockets;
  late List<io.HttpHeaders> requestHeaders;
  late StreamController<io.WebSocket> connections;

  setUp(() async {
    serverSockets = [];
    requestHeaders = [];
    connections = StreamController.broadcast();
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestHeaders.add(request.headers);
      final socket = await io.WebSocketTransformer.upgrade(request);
      serverSockets.add(socket);
      connections.add(socket);
    });
  });

  tearDown(() async {
    for (final socket in serverSockets) {
      await socket.close();
    }
    await server.close(force: true);
    await connections.close();
  });

  Uri uri() => Uri.parse('ws://127.0.0.1:${server.port}/api/1.46.0/sync');

  ({DomWebSocket ws, List<String> events, Future<void> closed}) open() {
    final events = <String>[];
    final closed = Completer<void>();
    final ws = DomWebSocket(uri(), WebSocket.connect)
      ..onopen = () {
        events.add('open');
      }
      ..onmessage = (data) {
        events.add('message:$data');
      }
      ..onerror = (_) {
        events.add('error');
      }
      ..onclose = (code, reason) {
        events.add('close:$code:$reason');
        closed.complete();
      };
    return (ws: ws, events: events, closed: closed.future);
  }

  test('delivers messages, then the server close code and reason', () async {
    final (:ws, :events, :closed) = open();
    final serverSocket = await connections.stream.first;
    serverSocket.add('hello');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await serverSocket.close(1011, 'InternalServerError');
    await closed;
    expect(events, ['open', 'message:hello', 'close:1011:InternalServerError']);
    expect(ws, isNotNull);
  });

  test('a client close reports 1005 once', () async {
    final (:ws, :events, :closed) = open();
    await connections.stream.first;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    ws
      ..close()
      ..close();
    await closed;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, ['open', 'close:1005:']);
  });

  test('a failed connection reports an error, then 1006', () async {
    final port = server.port;
    await server.close(force: true);
    final events = <String>[];
    final closed = Completer<void>();
    DomWebSocket(Uri.parse('ws://127.0.0.1:$port/'), WebSocket.connect)
      ..onopen = () {
        events.add('open');
      }
      ..onerror = (_) {
        events.add('error');
      }
      ..onclose = (code, reason) {
        events.add('close:$code');
        closed.complete();
      };
    await closed.future;
    expect(events, ['error', 'close:1006']);
  });

  test('closing while connecting never opens', () async {
    final (:ws, :events, :closed) = open();
    ws.close();
    await closed;
    expect(events, ['close:1006:']);
  });

  test('sends no Convex-Client header', () async {
    final (:ws, events: _, :closed) = open();
    await connections.stream.first;
    expect(requestHeaders.single.value('convex-client'), isNull);
    ws.close();
    await closed;
  });
}
