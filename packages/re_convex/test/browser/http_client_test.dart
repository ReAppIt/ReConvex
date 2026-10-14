import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/browser.dart';
import 'package:re_convex/server.dart';
import 'package:re_convex/values.dart';

import '../support/fake_http.dart';
import '../support/fakes.dart';

final apiMutationFunc =
    makeFunctionReference<MutationType, Map<String, Object?>, String>(
      'test:mutation',
    );

Map<String, Object?> _body(String body) =>
    jsonDecode(body) as Map<String, Object?>;

String _argValue(String body) =>
    ((_body(body)['args']! as List<Object?>).first! as Map)['value']! as String;

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('mutation queue processes mutations sequentially', () async {
    final resolveFirst = Completer<ResponseBody>();
    final resolveSecond = Completer<ResponseBody>();
    final adapter = FakeHttpAdapter((options, body) {
      final value = _argValue(body);
      if (_body(body)['path'] == 'test:mutation' && value == 'first') {
        return resolveFirst.future;
      }
      if (_body(body)['path'] == 'test:mutation' && value == 'second') {
        return resolveSecond.future;
      }
      return Future.error(Exception('Unexpected mutation'));
    });
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));

    // Start two queued mutations
    final firstPromise = client.mutation(apiMutationFunc, {'value': 'first'});
    final secondPromise = client.mutation(apiMutationFunc, {'value': 'second'});
    await _settle();

    // Verify first mutation started but second hasn't
    expect(adapter.requests, hasLength(1));
    expect(_argValue(adapter.requests[0].body), 'first');

    // Resolve first mutation
    resolveFirst.complete(
      jsonResponse({'status': 'success', 'value': 'first result'}),
    );
    await _settle();

    // Verify second mutation started
    expect(adapter.requests, hasLength(2));
    expect(_argValue(adapter.requests[1].body), 'second');

    // Resolve second mutation
    resolveSecond.complete(
      jsonResponse({'status': 'success', 'value': 'second result'}),
    );

    // Verify both promises resolve
    expect(await firstPromise, 'first result');
    expect(await secondPromise, 'second result');
  });

  test('unqueued mutations skip the queue', () async {
    final resolveQueued = Completer<ResponseBody>();
    final adapter = FakeHttpAdapter((options, body) {
      final value = _argValue(body);
      if (value == 'queued') {
        return resolveQueued.future;
      }
      if (value == 'unqueued') {
        return Future.value(
          jsonResponse({'status': 'success', 'value': 'unqueued result'}),
        );
      }
      return Future.error(Exception('Unexpected mutation'));
    });
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));

    // Start a queued mutation
    final queuedPromise = client.mutation(apiMutationFunc, {'value': 'queued'});
    await _settle();
    expect(adapter.requests, hasLength(1));

    // Start an unqueued mutation while first is still running
    final unqueuedPromise = client.mutation(apiMutationFunc, {
      'value': 'unqueued',
    }, skipQueue: true);
    await _settle();

    // Verify both mutations started immediately
    expect(adapter.requests, hasLength(2));

    // Resolve the queued mutation
    resolveQueued.complete(
      jsonResponse({'status': 'success', 'value': 'queued result'}),
    );

    // Verify both promises resolve
    expect(await queuedPromise, 'queued result');
    expect(await unqueuedPromise, 'unqueued result');
  });

  test("failed mutations don't block the queue", () async {
    final resolveSecond = Completer<ResponseBody>();
    final adapter = FakeHttpAdapter((options, body) {
      final value = _argValue(body);
      if (value == 'first') {
        return Future.value(
          jsonResponse({
            'status': 'error',
            'errorMessage': 'First mutation failed',
          }),
        );
      }
      if (value == 'second') {
        return resolveSecond.future;
      }
      return Future.error(Exception('Unexpected mutation'));
    });
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));

    // Start two queued mutations
    final firstPromise = client.mutation(apiMutationFunc, {'value': 'first'});
    final secondPromise = client.mutation(apiMutationFunc, {'value': 'second'});

    await expectLater(
      firstPromise,
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('First mutation failed'),
        ),
      ),
    );
    await _settle();

    // First mutation failed, second should start
    expect(adapter.requests, hasLength(2));
    expect(_argValue(adapter.requests[1].body), 'second');

    // Resolve second mutation
    resolveSecond.complete(
      jsonResponse({'status': 'success', 'value': 'second result'}),
    );
    expect(await secondPromise, 'second result');
  });

  // Upstream checks that an instance-level fetch wins over `setFetch`.
  test('the dio passed to the constructor is used', () async {
    final adapter = FakeHttpAdapter(
      (options, body) async =>
          jsonResponse({'status': 'success', 'value': 'instance fetch result'}),
    );
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));
    final result = await client.mutation(apiMutationFunc, {'value': 'test'});

    expect(adapter.requests, hasLength(1));
    expect(result, 'instance fetch result');
  });

  test('sends the npm client version and auth headers', () async {
    final adapter = FakeHttpAdapter(
      (options, body) async => jsonResponse({'status': 'success', 'value': 1}),
    );
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter))
      ..setAuth('jwt');
    expect(
      await client.query(
        makeFunctionReference<QueryType, Map<String, Object?>, Object?>(
          'messages:list',
        ),
        {'n': 2.0},
      ),
      1.0,
    );
    final request = adapter.requests.single;
    expect(request.options.uri.toString(), 'http://test/api/query');
    expect(request.options.headers['Convex-Client'], 'npm-1.46.0');
    expect(request.options.headers['Authorization'], 'Bearer jwt');
    expect(_body(request.body), {
      'path': 'messages:list',
      'format': 'convex_encoded_json',
      'args': [
        {'n': 2.0},
      ],
    });
  });

  test('a function error with data throws a ConvexError', () async {
    final adapter = FakeHttpAdapter(
      (options, body) async => jsonResponse({
        'status': 'error',
        'errorMessage': 'Not allowed',
        'errorData': {'code': 403},
      }, status: 560),
    );
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));
    await expectLater(
      client.action(
        makeFunctionReference<ActionType, Map<String, Object?>, Object?>('a:b'),
        noArgs,
      ),
      throwsA(
        isA<ConvexError<Value>>()
            .having((e) => e.message, 'message', 'Not allowed')
            .having((e) => e.data, 'data', {'code': 403.0}),
      ),
    );
  });

  test('consistentQuery reuses one timestamp', () async {
    final adapter = FakeHttpAdapter((options, body) async {
      if (options.uri.path == '/api/query_ts') {
        return jsonResponse({'ts': 'AAAAAAAAAAA='});
      }
      return jsonResponse({'status': 'success', 'value': 'v'});
    });
    final client = ConvexHttpClient('http://test', dio: fakeDio(adapter));
    final query =
        makeFunctionReference<QueryType, Map<String, Object?>, String>('a:b');
    await client.consistentQuery(query, noArgs);
    await client.consistentQuery(query, noArgs);
    expect(
      [for (final r in adapter.requests) r.options.uri.path],
      ['/api/query_ts', '/api/query_at_ts', '/api/query_at_ts'],
    );
    expect(_body(adapter.requests[1].body)['ts'], 'AAAAAAAAAAA=');
  });
}
