import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A Dio adapter that records requests and answers them with [handler].
class FakeHttpAdapter implements HttpClientAdapter {
  /// Creates the adapter.
  FakeHttpAdapter(this.handler);

  /// Answers a request given its options and decoded body.
  Future<ResponseBody> Function(RequestOptions options, String body) handler;

  /// Every request, in order.
  final List<({RequestOptions options, String body})> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await requestStream.forEach(bytes.addAll);
    }
    final body = utf8.decode(bytes);
    requests.add((options: options, body: body));
    return handler(options, body);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON response.
ResponseBody jsonResponse(Object json, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(json),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

/// A Dio that uses [adapter].
Dio fakeDio(FakeHttpAdapter adapter) => Dio()..httpClientAdapter = adapter;
