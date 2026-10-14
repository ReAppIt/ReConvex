// Ported from convex/src/browser/http_client.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/index.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

/// The HTTP status of a successful request.
const int statusCodeOk = 200;

/// The HTTP status of a malformed request.
const int statusCodeBadRequest = 400;

/// Convex's status for "the function threw"; must match the backend.
const int statusCodeUdfFailed = 560;

final class _QueuedMutation {
  _QueuedMutation(this.name, this.args, this.completer);

  final String name;
  final Map<String, Value> args;
  final Completer<Value> completer;
}

/// Runs queries, mutations and actions over HTTP, without subscriptions.
///
/// Queued mutations run one at a time, in order.
class ConvexHttpClient {
  /// Creates a client for the deployment at [address].
  ///
  /// [dio] replaces upstream's `fetch` option; [auth] sets an initial JWT.
  ConvexHttpClient(
    String address, {
    bool skipConvexDeploymentUrlCheck = false,
    ConvexLogger? logger,
    String? auth,
    Dio? dio,
  }) : _address = address,
       _logger = logger ?? instantiateDefaultLogger(verbose: false),
       _dio = dio ?? Dio() {
    throwIfWeb();
    if (!skipConvexDeploymentUrlCheck) {
      validateDeploymentUrl(address);
    }
    if (auth != null && auth.isNotEmpty) {
      setAuth(auth);
    }
  }

  final String _address;
  final ConvexLogger _logger;
  final Dio _dio;
  String? _auth;
  String? _adminAuth;
  Future<String>? _encodedTsPromise;
  bool _debug = true;
  final List<_QueuedMutation> _mutationQueue = [];
  bool _isProcessingQueue = false;

  /// The URL of the deployment's HTTP API.
  String backendUrl() => '$_address/api';

  /// The address of the deployment.
  String get url => _address;

  /// Sets the JWT used for subsequent calls.
  void setAuth(String value) {
    clearAuth();
    _auth = value;
  }

  /// Authenticates with an admin key, optionally acting as a user.
  @internal
  void setAdminAuth(String token, [UserIdentityAttributes? actingAsIdentity]) {
    clearAuth();
    if (actingAsIdentity != null) {
      // Encode the identity to a base64 string
      final actingAsIdentityEncoded = base64.encode(
        utf8.encode(jsonEncode(actingAsIdentity)),
      );
      _adminAuth = '$token:$actingAsIdentityEncoded';
    } else {
      _adminAuth = token;
    }
  }

  /// Clears the auth token.
  void clearAuth() {
    _auth = null;
    _adminAuth = null;
  }

  /// Whether function log lines are written to the logger.
  @internal
  void setDebug(bool debug) {
    _debug = debug;
  }

  /// Runs [query] at a timestamp shared by every `consistentQuery` of this
  /// client, so their results are consistent with each other.
  ///
  /// Long-lived clients can fail with an expired timestamp.
  Future<R> consistentQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
  ) async {
    final queryArgs = parseArgs(args);
    final timestampPromise = _getTimestamp();
    return query.decodeResult(
      await _queryInner(
        getFunctionName(query),
        queryArgs,
        timestampPromise: timestampPromise,
      ),
    );
  }

  Future<String> _getTimestamp() => _encodedTsPromise ??= _getTimestampInner();

  Future<String> _getTimestampInner() async {
    final response = await _post('$_address/api/query_ts', null);
    if (!_isOk(response.status)) {
      throw Exception(response.text);
    }
    final json = jsonDecode(response.text) as Map<String, Object?>;
    return json['ts']! as String;
  }

  /// Runs [query] once.
  Future<R> query<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
  ) async {
    final queryArgs = parseArgs(args);
    return query.decodeResult(
      await _queryInner(getFunctionName(query), queryArgs),
    );
  }

  Future<Value> _queryInner(
    String name,
    Map<String, Value> queryArgs, {
    Future<String>? timestampPromise,
  }) async {
    final args = [convexToJson(queryArgs)];
    final timestamp = timestampPromise == null ? null : await timestampPromise;

    final body = jsonEncode({
      'path': name,
      'format': 'convex_encoded_json',
      'args': args,
      'ts': ?timestamp,
    });
    final endpoint = timestamp != null
        ? '$_address/api/query_at_ts'
        : '$_address/api/query';

    final response = await _post(endpoint, body);
    return _handleResponse(response, UdfType.query, name);
  }

  Future<Value> _mutationInner(
    String name,
    Map<String, Value> mutationArgs,
  ) async {
    final body = jsonEncode({
      'path': name,
      'format': 'convex_encoded_json',
      'args': [convexToJson(mutationArgs)],
    });
    final response = await _post('$_address/api/mutation', body);
    return _handleResponse(response, UdfType.mutation, name);
  }

  Future<void> _processMutationQueue() async {
    if (_isProcessingQueue) {
      return;
    }

    _isProcessingQueue = true;
    while (_mutationQueue.isNotEmpty) {
      final queued = _mutationQueue.removeAt(0);
      try {
        final result = await _mutationInner(queued.name, queued.args);
        queued.completer.complete(result);
      } on Object catch (error, stackTrace) {
        queued.completer.completeError(error, stackTrace);
      }
    }
    _isProcessingQueue = false;
  }

  Future<Value> _enqueueMutation(String name, Map<String, Value> args) {
    final completer = Completer<Value>();
    _mutationQueue.add(_QueuedMutation(name, args, completer));
    unawaited(_processMutationQueue());
    return completer.future;
  }

  /// Runs [mutation]; it waits for earlier queued mutations unless
  /// [skipQueue].
  Future<R> mutation<A, R>(
    FunctionReference<MutationType, A, R> mutation,
    A args, {
    bool skipQueue = false,
  }) async {
    final mutationArgs = parseArgs(args);
    final name = getFunctionName(mutation);
    final result = skipQueue
        ? await _mutationInner(name, mutationArgs)
        : await _enqueueMutation(name, mutationArgs);
    return mutation.decodeResult(result);
  }

  /// Runs [action].
  Future<R> action<A, R>(
    FunctionReference<ActionType, A, R> action,
    A args,
  ) async {
    final actionArgs = parseArgs(args);
    final name = getFunctionName(action);
    final body = jsonEncode({
      'path': name,
      'format': 'convex_encoded_json',
      'args': [convexToJson(actionArgs)],
    });
    final response = await _post('$_address/api/action', body);
    return action.decodeResult(_handleResponse(response, UdfType.action, name));
  }

  /// Runs any function by reference or name, optionally in a component.
  @internal
  Future<Value> function(
    Object anyFunction, [
    String? componentPath,
    Map<String, Value>? args,
  ]) async {
    final functionArgs = parseArgs(args);
    final name = anyFunction is String
        ? anyFunction
        : getFunctionName(anyFunction as AnyFunctionReference);
    final body = jsonEncode({
      'componentPath': componentPath,
      'path': name,
      'format': 'convex_encoded_json',
      'args': convexToJson(functionArgs),
    });
    final response = await _post('$_address/api/function', body);
    return _handleResponse(response, UdfType.any, name);
  }

  static bool _isOk(int status) => status >= 200 && status < 300;

  Future<({int status, String text})> _post(String url, String? body) async {
    final headers = <String, Object>{
      'Content-Type': 'application/json',
      'Convex-Client': 'npm-$version',
    };
    final adminAuth = _adminAuth;
    final auth = _auth;
    if (adminAuth != null) {
      headers['Authorization'] = 'Convex $adminAuth';
    } else if (auth != null) {
      headers['Authorization'] = 'Bearer $auth';
    }
    final response = await _dio.post<List<int>>(
      url,
      data: body,
      options: Options(
        headers: headers,
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    return (
      status: response.statusCode ?? 0,
      text: utf8.decode(response.data ?? const []),
    );
  }

  Value _handleResponse(
    ({int status, String text}) response,
    UdfType udfType,
    String name,
  ) {
    if (!_isOk(response.status) && response.status != statusCodeUdfFailed) {
      throw Exception(response.text);
    }
    final respJSON = jsonDecode(response.text) as Map<String, Object?>;
    if (_debug) {
      for (final line
          in (respJSON['logLines'] as List<Object?>? ?? const [])
              .cast<String>()) {
        logForFunction(_logger, LogLevel.info, udfType, name, line);
      }
    }
    switch (respJSON['status']) {
      case 'success':
        return jsonToConvex(respJSON['value']);
      case 'error':
        final errorMessage = respJSON['errorMessage']! as String;
        if (respJSON.containsKey('errorData')) {
          throw _forwardErrorData(
            respJSON['errorData'],
            ConvexError<Value>(errorMessage),
          );
        }
        throw Exception(errorMessage);
      default:
        throw Exception('Invalid response: ${jsonEncode(respJSON)}');
    }
  }
}

ConvexError<Value> _forwardErrorData(
  JSONValue errorData,
  ConvexError<Value> error,
) {
  error.data = jsonToConvex(errorData);
  return error;
}
