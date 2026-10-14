// Ported from convex/src/browser/sync/client.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/authentication_manager.dart';
import 'package:re_convex/src/browser/sync/dom_web_socket.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/local_state.dart';
import 'package:re_convex/src/browser/sync/metrics.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates_impl.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' hide Transition;
import 'package:re_convex/src/browser/sync/protocol.dart'
    as wire
    show Transition;
import 'package:re_convex/src/browser/sync/remote_query_set.dart';
import 'package:re_convex/src/browser/sync/request_manager.dart';
import 'package:re_convex/src/browser/sync/session.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/browser/sync/web_socket_manager.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/index.dart';
import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/jwt_decode/index.dart';
import 'package:web_socket/web_socket.dart';

export 'package:re_convex/src/browser/sync/authentication_manager.dart'
    show AuthTokenFetcher;

/// Options for [BaseConvexClient].
class BaseConvexClientOptions {
  /// Creates the options.
  const BaseConvexClientOptions({
    this.webSocketConstructor,
    this.verbose = false,
    this.logger,
    this.reportDebugInfoToConvex = false,
    this.onServerDisconnectError,
    this.skipConvexDeploymentUrlCheck = false,
    this.authRefreshTokenLeeway = const Duration(seconds: 10),
    this.expectAuth = false,
    this.initialAuthTokenReuse = false,
    this.subscribeToOnline,
  });

  /// Opens the WebSocket; defaults to package:web_socket's `WebSocket.connect`.
  final WebSocketConstructor? webSocketConstructor;

  /// Adds verbose logging for debugging.
  final bool verbose;

  /// Where logs go; `null` writes to package:logging's `Logger('re_convex')`
  /// and [instantiateNoopLogger] silences them.
  final ConvexLogger? logger;

  /// Sends additional metrics to Convex for debugging.
  final bool reportDebugInfoToConvex;

  /// Experimental: called with abnormal WebSocket close messages, whose
  /// content is not stable.
  final void Function(String message)? onServerDisconnectError;

  /// Skips checking that the URL looks like a Convex deployment, for
  /// self-hosted backends.
  final bool skipConvexDeploymentUrlCheck;

  /// How long before a token expires it is refetched.
  final Duration authRefreshTokenLeeway;

  /// Experimental: holds every request until the first auth token is sent.
  final bool expectAuth;

  /// Experimental: keeps the initial cached token instead of fetching a fresh
  /// one, which spares the server a second `Authenticate`.
  final bool initialAuthTokenReuse;

  /// Reconnects at once when the network comes back, like the browser's
  /// `online` event; see `subscribeToConnectivity` in the Flutter library.
  final SubscribeToOnline? subscribeToOnline;
}

/// State describing the client's connection with the Convex backend
/// (`ConnectionState` upstream).
final class ConvexConnectionState {
  /// Creates the state.
  const ConvexConnectionState({
    required this.hasInflightRequests,
    required this.isWebSocketConnected,
    required this.timeOfOldestInflightRequest,
    required this.hasEverConnected,
    required this.connectionCount,
    required this.connectionRetries,
    required this.inflightMutations,
    required this.inflightActions,
  });

  /// Whether any mutation or action is in flight.
  final bool hasInflightRequests;

  /// Whether the WebSocket is open.
  final bool isWebSocketConnected;

  /// When the oldest unanswered request was made.
  final DateTime? timeOfOldestInflightRequest;

  /// Whether the client ever opened a WebSocket to the "ready" state.
  final bool hasEverConnected;

  /// How many times this client connected; a high number means an unstable
  /// connection.
  final int connectionCount;

  /// How many times in a row the client failed to connect.
  final int connectionRetries;

  /// The number of mutations in flight.
  final int inflightMutations;

  /// The number of actions in flight.
  final int inflightActions;

  @override
  bool operator ==(Object other) =>
      other is ConvexConnectionState &&
      other.hasInflightRequests == hasInflightRequests &&
      other.isWebSocketConnected == isWebSocketConnected &&
      other.timeOfOldestInflightRequest == timeOfOldestInflightRequest &&
      other.hasEverConnected == hasEverConnected &&
      other.connectionCount == connectionCount &&
      other.connectionRetries == connectionRetries &&
      other.inflightMutations == inflightMutations &&
      other.inflightActions == inflightActions;

  @override
  int get hashCode => Object.hash(
    hasInflightRequests,
    isWebSocketConnected,
    timeOfOldestInflightRequest,
    hasEverConnected,
    connectionCount,
    connectionRetries,
    inflightMutations,
    inflightActions,
  );

  @override
  String toString() =>
      'ConvexConnectionState(hasInflightRequests: $hasInflightRequests, '
      'isWebSocketConnected: $isWebSocketConnected, '
      'timeOfOldestInflightRequest: $timeOfOldestInflightRequest, '
      'hasEverConnected: $hasEverConnected, connectionCount: '
      '$connectionCount, connectionRetries: $connectionRetries, '
      'inflightMutations: $inflightMutations, inflightActions: '
      '$inflightActions)';
}

/// How a query changed within a [Transition].
sealed class QueryModification {
  const QueryModification();

  /// `Updated` or `Removed`.
  String get kind;
}

/// A query has a new result; `null` means an optimistic update set it
/// loading.
final class UpdatedQueryModification extends QueryModification {
  /// Creates the modification.
  const UpdatedQueryModification(this.result);

  @override
  String get kind => 'Updated';

  /// The new result.
  final FunctionResult? result;
}

/// A query was removed.
final class RemovedQueryModification extends QueryModification {
  /// Creates the modification.
  const RemovedQueryModification();

  @override
  String get kind => 'Removed';
}

/// The changes passed to `onTransition` handlers, from the server or from a
/// local optimistic update.
class Transition {
  /// Creates a transition.
  const Transition({
    required this.queries,
    required this.reflectedMutations,
    required this.timestamp,
  });

  /// The queries that changed.
  final List<({QueryToken token, QueryModification modification})> queries;

  /// The mutations whose effects this transition includes.
  final List<({RequestId requestId, FunctionResult result})> reflectedMutations;

  /// The server timestamp.
  final TS timestamp;
}

/// The public API of [BaseConvexClient].
@internal
abstract interface class BaseConvexClientInterface {
  /// See [BaseConvexClient.addOnTransitionHandler].
  void Function() addOnTransitionHandler(
    void Function(Transition transition) fn,
  );

  /// See [BaseConvexClient.setAuth].
  void setAuth(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]);

  /// See [BaseConvexClient.setAdminAuth].
  void setAdminAuth(String value, [UserIdentityAttributes? fakeUserIdentity]);

  /// See [BaseConvexClient.clearAuth].
  void clearAuth();

  /// See [BaseConvexClient.subscribe].
  ({QueryToken queryToken, void Function() unsubscribe}) subscribe(
    String name,
    Map<String, Value>? args, {
    QueryJournal journal,
    String? componentPath,
  });

  /// See [BaseConvexClient.localQueryResult].
  ({Value value})? localQueryResult(String udfPath, [Map<String, Value>? args]);

  /// See [BaseConvexClient.localQueryResultByToken].
  ({Value value})? localQueryResultByToken(QueryToken queryToken);

  /// See [BaseConvexClient.hasLocalQueryResultByToken].
  bool hasLocalQueryResultByToken(QueryToken queryToken);

  /// See [BaseConvexClient.localQueryLogs].
  List<String>? localQueryLogs(String udfPath, [Map<String, Value>? args]);

  /// See [BaseConvexClient.queryJournal].
  QueryJournal queryJournal(String name, [Map<String, Value>? args]);

  /// See [BaseConvexClient.connectionState].
  ConvexConnectionState connectionState();

  /// See [BaseConvexClient.subscribeToConnectionState].
  void Function() subscribeToConnectionState(
    void Function(ConvexConnectionState connectionState) cb,
  );

  /// See [BaseConvexClient.mutation].
  Future<Value> mutation(
    String name,
    Map<String, Value>? args, {
    OptimisticUpdate<Map<String, Value>>? optimisticUpdate,
  });

  /// See [BaseConvexClient.action].
  Future<Value> action(String name, [Map<String, Value>? args]);

  /// See [BaseConvexClient.close].
  Future<void> close();

  /// See [BaseConvexClient.url].
  String get url;
}

/// Low-level client for integrating state management libraries with Convex.
///
/// Most apps use `ConvexReactClient`, `ConvexClient` or `ConvexHttpClient`
/// instead.
class BaseConvexClient implements BaseConvexClientInterface {
  /// Connects to the deployment at [address], like
  /// `https://small-mouse-123.convex.cloud`.
  ///
  /// [onTransition] receives the tokens of queries whose results changed.
  BaseConvexClient(
    String address,
    void Function(List<QueryToken> updatedQueries) onTransition, [
    BaseConvexClientOptions options = const BaseConvexClientOptions(),
  ]) : _address = address,
       _debug = options.reportDebugInfoToConvex,
       _logger =
           options.logger ??
           instantiateDefaultLogger(verbose: options.verbose) {
    throwIfWeb();
    if (!options.skipConvexDeploymentUrlCheck) {
      validateDeploymentUrl(address);
    }
    final webSocketConstructor =
        options.webSocketConstructor ?? WebSocket.connect;
    // Substitute http(s) with ws(s)
    final i = address.indexOf('://');
    if (i == -1) {
      throw ArgumentError('Provided address was not an absolute URL.');
    }
    final origin = address.substring(i + 3); // move past the double slash
    final protocol = address.substring(0, i);
    final String wsProtocol;
    if (protocol == 'http') {
      wsProtocol = 'ws';
    } else if (protocol == 'https') {
      wsProtocol = 'wss';
    } else {
      throw ArgumentError('Unknown parent protocol $protocol');
    }
    final wsUri = '$wsProtocol://$origin/api/$version/sync';

    _remoteQuerySet = RemoteQuerySet(_state.queryPath, _logger);
    _requestManager = RequestManager(_logger, _markConnectionStateDirty);

    // For AuthenticationManager; the expectAuth pause ends the constructor.
    void pauseSocket() {
      _webSocketManager.pause();
      _state.pause();
    }

    _authenticationManager = AuthenticationManager(
      _state,
      authenticate: (token) {
        final message = _state.setAuth(token);
        _webSocketManager.sendMessage(message);
        return message.baseVersion;
      },
      stopSocket: () => _webSocketManager.stop(),
      tryRestartSocket: () => _webSocketManager.tryRestart(),
      pauseSocket: pauseSocket,
      resumeSocket: () => _webSocketManager.resume(),
      clearAuth: clearAuth,
      logger: _logger,
      refreshTokenLeeway: options.authRefreshTokenLeeway,
      initialAuthTokenReuse: options.initialAuthTokenReuse,
    );
    addOnTransitionHandler((transition) {
      onTransition([for (final query in transition.queries) query.token]);
    });

    _webSocketManager = WebSocketManager(
      Uri.parse(wsUri),
      onOpen: (reconnectMetadata) {
        // We have a new WebSocket!
        _mark(MarkName.convexWebSocketOpen);
        _webSocketManager.sendMessage(
          Connect(
            connectionCount: reconnectMetadata.connectionCount,
            lastCloseReason: reconnectMetadata.lastCloseReason,
            clientTs: reconnectMetadata.clientTs,
            sessionId: _sessionId,
            maxObservedTimestamp: _maxObservedTimestamp,
          ),
        );

        // Reissue queries and mutations and reauthenticate from scratch.
        _remoteQuerySet = RemoteQuerySet(_state.queryPath, _logger);
        final (querySetModification, authModification) = _state.restart();
        if (authModification != null) {
          _webSocketManager.sendMessage(authModification);
        }
        _webSocketManager.sendMessage(querySetModification);
        for (final message in _requestManager.restart()) {
          _webSocketManager.sendMessage(message);
        }
      },
      onResume: () {
        final (querySetModification, authModification) = _state.resume();
        if (authModification != null) {
          _webSocketManager.sendMessage(authModification);
        }
        if (querySetModification != null) {
          _webSocketManager.sendMessage(querySetModification);
        }
        for (final message in _requestManager.resume()) {
          _webSocketManager.sendMessage(message);
        }
      },
      onMessage: (serverMessage) {
        // Report once, as reconnects would make metrics grow quadratically.
        if (!_firstMessageReceived) {
          _firstMessageReceived = true;
          _mark(MarkName.convexFirstMessageReceived);
          _reportMarks();
        }
        switch (serverMessage.type) {
          case 'Transition':
            final transition = wire.Transition(serverMessage.json);
            _observedTimestamp(transition.endVersion.ts);
            _authenticationManager.onTransition(transition);
            _remoteQuerySet.transition(transition);
            _state.transition(transition);
            final completedRequests = _requestManager.removeCompleted(
              _remoteQuerySet.timestamp(),
            );
            _notifyOnQueryResultChanges(completedRequests);
          case 'MutationResponse':
            final response = MutationResponse(serverMessage.json);
            if (response.success) {
              _observedTimestamp(response.ts);
            }
            final completedMutationInfo = _requestManager.onResponse(
              serverMessage,
            );
            if (completedMutationInfo != null) {
              _notifyOnQueryResultChanges({
                completedMutationInfo.requestId: completedMutationInfo.result,
              });
            }
          case 'ActionResponse':
            _requestManager.onResponse(serverMessage);
          case 'AuthError':
            _authenticationManager.onAuthError(AuthError(serverMessage.json));
          case 'FatalError':
            final error = logFatalError(
              _logger,
              FatalError(serverMessage.json).error,
            );
            unawaited(_webSocketManager.terminate());
            throw error;
        }

        return (hasSyncedPastLastReconnect: _hasSyncedPastLastReconnect());
      },
      onServerDisconnectError: options.onServerDisconnectError,
      webSocketConstructor: webSocketConstructor,
      logger: _logger,
      markConnectionStateDirty: _markConnectionStateDirty,
      debug: _debug,
      subscribeToOnline: options.subscribeToOnline,
    );
    _mark(MarkName.convexClientConstructed);

    // Begin client in a paused state waiting for an auth token.
    if (options.expectAuth) {
      pauseSocket();
    }
  }

  final String _address;
  final LocalSyncState _state = LocalSyncState();
  late final RequestManager _requestManager;
  late final WebSocketManager _webSocketManager;
  late final AuthenticationManager _authenticationManager;
  late RemoteQuerySet _remoteQuerySet;
  final OptimisticQueryResults _optimisticQueryResults =
      OptimisticQueryResults();
  int _transitionHandlerCounter = 0;
  int _nextRequestId = 0;
  final Map<int, void Function(Transition transition)> _onTransitionFns = {};
  final String _sessionId = newSessionId();
  bool _firstMessageReceived = false;
  final bool _debug;
  final ConvexLogger _logger;
  TS? _maxObservedTimestamp;
  final Map<int, void Function(ConvexConnectionState connectionState)>
  _connectionStateSubscribers = {};
  int _nextConnectionStateSubscriberId = 0;
  ConvexConnectionState? _lastPublishedConnectionState;

  // Whether work from before the last restart finished, to reset backoff.
  bool _hasSyncedPastLastReconnect() =>
      _requestManager.hasSyncedPastLastReconnect() &&
      _state.hasSyncedPastLastReconnect();

  void _observedTimestamp(TS observedTs) {
    final current = _maxObservedTimestamp;
    if (current == null || current.lessThanOrEqual(observedTs)) {
      _maxObservedTimestamp = observedTs;
    }
  }

  /// The newest server timestamp the client has observed.
  TS? getMaxObservedTimestamp() => _maxObservedTimestamp;

  // Merges server results with optimistic updates; notifies changes.
  void _notifyOnQueryResultChanges(
    Map<RequestId, FunctionResult> completedRequests,
  ) {
    final remoteQueryResults = _remoteQuerySet.remoteQueryResults();
    final QueryResultsMap queryTokenToValue = {};
    for (final MapEntry(key: queryId, value: result)
        in remoteQueryResults.entries) {
      final queryToken = _state.queryToken(queryId);
      // We may have unsubscribed before the server learned it; ignore those.
      if (queryToken != null) {
        queryTokenToValue[queryToken] = Query(
          result: result,
          udfPath: _state.queryPath(queryId)!,
          args: _state.queryArgs(queryId)!,
        );
      }
    }

    // Queries changed by new server results or local optimistic updates.
    final changedQueryTokens = _optimisticQueryResults
        .ingestQueryResultsFromServer(
          queryTokenToValue,
          completedRequests.keys.toSet(),
        );

    _handleTransition(
      Transition(
        queries: [
          for (final token in changedQueryTokens)
            (
              token: token,
              modification: UpdatedQueryModification(
                _optimisticQueryResults.rawQueryResult(token),
              ),
            ),
        ],
        reflectedMutations: [
          for (final MapEntry(key: requestId, value: result)
              in completedRequests.entries)
            (requestId: requestId, result: result),
        ],
        timestamp: _remoteQuerySet.timestamp(),
      ),
    );
  }

  void _handleTransition(Transition transition) {
    for (final fn in _onTransitionFns.values.toList()) {
      fn(transition);
    }
  }

  /// Adds a handler called on every transition; returns a function that
  /// removes it.
  @override
  void Function() addOnTransitionHandler(
    void Function(Transition transition) fn,
  ) {
    final id = _transitionHandlerCounter++;
    _onTransitionFns[id] = fn;
    return () => _onTransitionFns.remove(id);
  }

  /// The current JWT auth token and its decoded claims, if a user token is
  /// set.
  ({String token, Map<String, Object?> decoded})? getCurrentAuthClaims() {
    final authToken = _state.getAuth();
    if (authToken == null || authToken.tokenType != 'User') {
      return null;
    }
    Map<String, Object?> decoded;
    try {
      decoded = jwtDecode(authToken.value);
    } on InvalidTokenError {
      decoded = {};
    }
    return (token: authToken.value, decoded: decoded);
  }

  /// Sets the source of auth tokens; [fetchToken] runs again whenever a
  /// token expires. [onChange] reports whether the server accepted a token,
  /// [onRefreshChange] whether a rejected one is being replaced.
  @override
  void setAuth(
    AuthTokenFetcher fetchToken,
    void Function(bool isAuthenticated) onChange, [
    void Function(bool isRefreshing)? onRefreshChange,
  ]) {
    unawaited(
      _authenticationManager.setConfig(fetchToken, onChange, onRefreshChange),
    );
  }

  /// Whether a token is set.
  bool hasAuth() => _state.hasAuth();

  /// Authenticates with an admin key, optionally acting as a user.
  @internal
  @override
  void setAdminAuth(String value, [UserIdentityAttributes? fakeUserIdentity]) {
    final message = _state.setAdminAuth(value, fakeUserIdentity);
    _webSocketManager.sendMessage(message);
  }

  /// Clears the auth token.
  @override
  void clearAuth() {
    final message = _state.clearAuth();
    _webSocketManager.sendMessage(message);
  }

  /// Subscribes to the query [name]; the `onTransition` callback learns
  /// when its result changes.
  ///
  /// [journal] from a previous run only applies to a new subscription.
  @override
  ({QueryToken queryToken, void Function() unsubscribe}) subscribe(
    String name,
    Map<String, Value>? args, {
    QueryJournal journal,
    String? componentPath,
  }) {
    final argsObject = parseArgs(args);

    final (:modification, :queryToken, :unsubscribe) = _state.subscribe(
      name,
      argsObject,
      journal: journal,
      componentPath: componentPath,
    );
    if (modification != null) {
      _webSocketManager.sendMessage(modification);
    }
    return (
      queryToken: queryToken,
      unsubscribe: () {
        final modification = unsubscribe();
        if (modification != null) {
          _webSocketManager.sendMessage(modification);
        }
      },
    );
  }

  /// The local result of a subscribed or optimistically set query, or
  /// `null` while it is loading; throws the query's error.
  @override
  ({Value value})? localQueryResult(
    String udfPath, [
    Map<String, Value>? args,
  ]) {
    final argsObject = parseArgs(args);
    final queryToken = serializePathAndArgs(udfPath, argsObject);
    return _optimisticQueryResults.queryResult(queryToken);
  }

  /// [localQueryResult] by query token.
  @internal
  @override
  ({Value value})? localQueryResultByToken(QueryToken queryToken) =>
      _optimisticQueryResults.queryResult(queryToken);

  /// Whether a local result exists for [queryToken], errors included.
  @internal
  @override
  bool hasLocalQueryResultByToken(QueryToken queryToken) =>
      _optimisticQueryResults.hasQueryResult(queryToken);

  /// The log lines of a local query result.
  @internal
  @override
  List<String>? localQueryLogs(String udfPath, [Map<String, Value>? args]) {
    final argsObject = parseArgs(args);
    final queryToken = serializePathAndArgs(udfPath, argsObject);
    return _optimisticQueryResults.queryLogs(queryToken);
  }

  /// The current journal of the query [name], or `null` before its first
  /// result.
  @override
  QueryJournal queryJournal(String name, [Map<String, Value>? args]) {
    final argsObject = parseArgs(args);
    final queryToken = serializePathAndArgs(name, argsObject);
    return _state.queryJournal(queryToken);
  }

  /// The current [ConvexConnectionState] with the Convex backend.
  @override
  ConvexConnectionState connectionState() {
    final wsConnectionState = _webSocketManager.connectionState();
    return ConvexConnectionState(
      hasInflightRequests: _requestManager.hasInflightRequests(),
      isWebSocketConnected: wsConnectionState.isConnected,
      hasEverConnected: wsConnectionState.hasEverConnected,
      connectionCount: wsConnectionState.connectionCount,
      connectionRetries: wsConnectionState.connectionRetries,
      timeOfOldestInflightRequest: _requestManager
          .timeOfOldestInflightRequest(),
      inflightMutations: _requestManager.inflightMutations(),
      inflightActions: _requestManager.inflightActions(),
    );
  }

  // Publishes the connection state in a microtask if it changed.
  void _markConnectionStateDirty() {
    scheduleMicrotask(() {
      final curConnectionState = connectionState();
      if (curConnectionState != _lastPublishedConnectionState) {
        _lastPublishedConnectionState = curConnectionState;
        for (final cb in _connectionStateSubscribers.values.toList()) {
          // A throwing callback stops the rest; the client stays consistent.
          cb(curConnectionState);
        }
      }
    });
  }

  /// Calls [cb] each time the [ConvexConnectionState] changes; returns a
  /// function that stops it.
  @override
  void Function() subscribeToConnectionState(
    void Function(ConvexConnectionState connectionState) cb,
  ) {
    final id = _nextConnectionStateSubscriberId++;
    _connectionStateSubscribers[id] = cb;
    return () {
      _connectionStateSubscribers.remove(id);
    };
  }

  /// Runs the mutation [name], applying [optimisticUpdate] until it
  /// completes; throws a `ConvexError` or an [Exception] when it fails.
  @override
  Future<Value> mutation(
    String name,
    Map<String, Value>? args, {
    OptimisticUpdate<Map<String, Value>>? optimisticUpdate,
  }) async {
    final result = await mutationInternal(
      name,
      args,
      optimisticUpdate: optimisticUpdate,
    );
    return _valueOrThrow(UdfType.mutation, name, result);
  }

  static Value _valueOrThrow(
    UdfType source,
    String name,
    FunctionResult result,
  ) {
    switch (result) {
      case FunctionSuccess(:final value):
        return value;
      case FunctionFailure(:final errorData):
        final message = createHybridErrorStacktrace(source, name, result);
        if (errorData != null) {
          throw forwardData(result, ConvexError<Value>(message));
        }
        throw Exception(message);
    }
  }

  /// [mutation] returning the raw [FunctionResult].
  @internal
  Future<FunctionResult> mutationInternal(
    String udfPath,
    Map<String, Value>? args, {
    OptimisticUpdate<Map<String, Value>>? optimisticUpdate,
    String? componentPath,
  }) => enqueueMutation(
    udfPath,
    args,
    optimisticUpdate: optimisticUpdate,
    componentPath: componentPath,
  ).mutationPromise;

  /// Sends a mutation and applies its optimistic update right away.
  @internal
  ({RequestId requestId, Future<FunctionResult> mutationPromise})
  enqueueMutation(
    String udfPath,
    Map<String, Value>? args, {
    OptimisticUpdate<Map<String, Value>>? optimisticUpdate,
    String? componentPath,
  }) {
    final mutationArgs = parseArgs(args);
    _tryReportLongDisconnect();
    final requestId = nextRequestId;
    _nextRequestId++;

    if (optimisticUpdate != null) {
      void wrappedUpdate(OptimisticLocalStore localQueryStore) {
        // A void callback can still return the Future of an async closure.
        final update =
            optimisticUpdate
                as Object? Function(OptimisticLocalStore, Map<String, Value>);
        final result = update(localQueryStore, mutationArgs);
        if (result is Future<Object?>) {
          _logger.warn(
            'Optimistic update handler returned a Promise. Optimistic '
            'updates should be synchronous.',
          );
        }
      }

      final changedQueryTokens = _optimisticQueryResults.applyOptimisticUpdate(
        wrappedUpdate,
        requestId,
      );

      _handleTransition(
        Transition(
          queries: [
            for (final token in changedQueryTokens)
              (
                token: token,
                modification: UpdatedQueryModification(
                  switch (localQueryResultByToken(token)) {
                    null => null,
                    (:final value) => FunctionSuccess(
                      value: value,
                      logLines: const [],
                    ),
                  },
                ),
              ),
          ],
          reflectedMutations: const [],
          timestamp: _remoteQuerySet.timestamp(),
        ),
      );
    }

    final message = MutationRequest(
      requestId: requestId,
      udfPath: udfPath,
      componentPath: componentPath,
      args: [convexToJson(mutationArgs)],
    );
    final mightBeSent = _webSocketManager.sendMessage(message);
    final mutationPromise = _requestManager.request(message, sent: mightBeSent);
    return (requestId: requestId, mutationPromise: mutationPromise);
  }

  /// Runs the action [name]; throws a `ConvexError` or an [Exception] when
  /// it fails.
  @override
  Future<Value> action(String name, [Map<String, Value>? args]) async {
    final result = await actionInternal(name, args);
    return _valueOrThrow(UdfType.action, name, result);
  }

  /// [action] returning the raw [FunctionResult].
  @internal
  Future<FunctionResult> actionInternal(
    String udfPath,
    Map<String, Value>? args, {
    String? componentPath,
  }) {
    final actionArgs = parseArgs(args);
    final requestId = nextRequestId;
    _nextRequestId++;
    _tryReportLongDisconnect();

    final message = ActionRequest(
      requestId: requestId,
      udfPath: udfPath,
      componentPath: componentPath,
      args: [convexToJson(actionArgs)],
    );

    final mightBeSent = _webSocketManager.sendMessage(message);
    return _requestManager.request(message, sent: mightBeSent);
  }

  /// Closes the connection and stops every subscription; completes once
  /// the WebSocket closed.
  @override
  Future<void> close() {
    _authenticationManager.stop();
    return _webSocketManager.terminate();
  }

  /// The address of the deployment; it may be canonicalized.
  @override
  String get url => _address;

  /// The id of the next mutation or action.
  @internal
  int get nextRequestId => _nextRequestId;

  /// The id of this client's session.
  @internal
  String get sessionId => _sessionId;

  void _mark(MarkName name) {
    if (_debug) {
      mark(name, sessionId);
    }
  }

  // Reports performance marks to the server; only with a working WebSocket.
  void _reportMarks() {
    if (_debug) {
      final report = getMarksReport(sessionId);
      _webSocketManager.sendMessage(
        Event(eventType: 'ClientConnect', event: report),
      );
    }
  }

  void _tryReportLongDisconnect() {
    if (!_debug) {
      return;
    }
    final timeOfOldestRequest = connectionState().timeOfOldestInflightRequest;
    if (timeOfOldestRequest == null ||
        clock.now().difference(timeOfOldestRequest) <=
            const Duration(minutes: 1)) {
      return;
    }
    final endpoint = '$_address/api/debug_event';
    unawaited(
      Dio()
          .post<Object?>(
            endpoint,
            data: jsonEncode({'event': 'LongWebsocketDisconnect'}),
            options: Options(
              headers: {
                'Content-Type': 'application/json',
                'Convex-Client': 'npm-$version',
              },
              validateStatus: (_) => true,
            ),
          )
          .then<void>(
            (response) {
              final status = response.statusCode ?? 0;
              if (status < 200 || status >= 300) {
                _logger.warn(
                  'Analytics request failed with response: ${response.data}',
                );
              }
            },
            onError: (Object error) {
              _logger.warn('Analytics response failed with error: $error');
            },
          ),
    );
  }
}

/// Throws on the web, where Dart's 53-bit `int` can't tell int64 from
/// float64.
@internal
void throwIfWeb() {
  if (identical(0, 0.0)) {
    throw UnsupportedError(
      're_convex runs on iOS and Android: on the web a Dart int cannot be '
      'told apart from a double, which Convex values need.',
    );
  }
}
