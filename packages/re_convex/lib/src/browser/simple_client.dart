// Ported from convex/src/browser/simple_client.ts (Apache-2.0); modified for Dart.
import 'dart:async';

import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/paginated_query_client.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/server/pagination.dart';
import 'package:re_convex/src/values/value.dart';

/// Options for [ConvexClient].
class ConvexClientOptions extends BaseConvexClientOptions {
  /// Creates the options.
  const ConvexClientOptions({
    this.disabled = false,
    super.webSocketConstructor,
    super.verbose,
    super.logger,
    super.reportDebugInfoToConvex,
    super.onServerDisconnectError,
    super.skipConvexDeploymentUrlCheck,
    super.authRefreshTokenLeeway,
    super.expectAuth,
    super.initialAuthTokenReuse,
    super.subscribeToOnline,
  });

  /// Creates a client that never connects, for code that runs without a
  /// backend.
  final bool disabled;
}

/// Stops a subscription; call it, or call [unsubscribe].
final class Unsubscribe<T> {
  Unsubscribe._(this._unsubscribe, this._getCurrentValue, this._getQueryLogs);

  final void Function() _unsubscribe;
  final ({T value})? Function() _getCurrentValue;
  final List<String>? Function() _getQueryLogs;

  /// Stops the subscription.
  void call() => _unsubscribe();

  /// Stops the subscription.
  void unsubscribe() => _unsubscribe();

  /// The current result, or `null` while it is loading.
  ({T value})? getCurrentValue() => _getCurrentValue();

  /// The log lines of the current result.
  @internal
  List<String>? getQueryLogs() => _getQueryLogs();
}

// The bookkeeping of one registered callback.
final class _QueryInfo {
  _QueryInfo({
    required this.queryToken,
    required this.decode,
    required this.callback,
    required this.onError,
    required this.unsubscribe,
  });

  final QueryToken queryToken;
  // Turns the raw local result into the callback's type.
  final Object? Function(Object? result) decode;
  final void Function(Object? result) callback;
  final void Function(Object error)? onError;
  final void Function() unsubscribe;
  bool hasEverRun = false;
}

/// Subscribes to Convex query functions and runs mutations and actions over
/// a WebSocket, without a UI framework.
///
/// Subscriptions with the same query and arguments share one server query.
class ConvexClient {
  /// Connects to the deployment at [address], like
  /// `https://small-mouse-123.convex.cloud`.
  ConvexClient(
    String address, [
    ConvexClientOptions options = const ConvexClientOptions(),
  ]) : _disabled = options.disabled {
    if (!options.skipConvexDeploymentUrlCheck) {
      validateDeploymentUrl(address);
    }
    if (!_disabled) {
      final client = BaseConvexClient(
        address,
        (_) {}, // NOP, let the paginated query client do it all
        options,
      );
      _client = client;
      _paginatedClient = PaginatedQueryClient(client, _transition);
    }
  }

  final List<_QueryInfo> _listeners = [];
  BaseConvexClient? _client;
  PaginatedQueryClient? _paginatedClient;
  // A synthetic server event to run callbacks the first time.
  Timer? _callNewListenersWithCurrentValuesTimer;
  bool _closed = false;
  final bool _disabled;

  /// Whether [close] was called.
  bool get closed => _closed;

  /// The underlying [BaseConvexClient]; throws when [disabled].
  BaseConvexClient get client {
    final client = _client;
    if (client != null) return client;
    throw StateError('ConvexClient is disabled');
  }

  /// The paginated query client; throws when [disabled].
  @internal
  PaginatedQueryClient get paginatedClient {
    final paginatedClient = _paginatedClient;
    if (paginatedClient != null) return paginatedClient;
    throw StateError('ConvexClient is disabled');
  }

  /// Whether this client never connects.
  bool get disabled => _disabled;

  /// Calls [callback] with each new result of [query]; it also runs soon
  /// after registering when a result is already in memory.
  ///
  /// Query errors go to [onError], or to the zone when it is null.
  Unsubscribe<R> onUpdate<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
    void Function(R result) callback, [
    void Function(Object error)? onError,
  ]) {
    if (disabled) {
      return _createDisabledUnsubscribe<R>();
    }

    // BaseConvexClient takes care of deduplicating queries subscriptions...
    final (:queryToken, :unsubscribe) = client.subscribe(
      getFunctionName(query),
      parseArgs(args),
    );

    // ...but we still need to bookkeep callbacks to actually call them.
    final queryInfo = _QueryInfo(
      queryToken: queryToken,
      decode: query.decodeResult,
      callback: (result) => callback(result as R),
      onError: onError,
      unsubscribe: unsubscribe,
    );
    _listeners.add(queryInfo);

    // A result in memory runs the callback soon, not on a server update.
    if (_queryResultReady(queryToken) &&
        _callNewListenersWithCurrentValuesTimer == null) {
      _callNewListenersWithCurrentValuesTimer = Timer(
        Duration.zero,
        _callNewListenersWithCurrentValues,
      );
    }

    return Unsubscribe<R>._(
      () {
        if (closed) {
          // all unsubscribes already ran
          return;
        }
        _listeners.remove(queryInfo);
        unsubscribe();
      },
      () => switch (client.localQueryResultByToken(queryToken)) {
        null => null,
        (:final value) => (value: query.decodeResult(value)),
      },
      () => client.localQueryLogs(queryToken),
    );
  }

  /// Calls [callback] with each new result of the paginated [query].
  ///
  /// An experimental preview: caching, page splitting and the options may
  /// change. [args] exclude `paginationOpts`.
  Unsubscribe<PaginatedQueryResult<Item>>
  // ignore: non_constant_identifier_names, upstream name.
  onPaginatedUpdate_experimental<A, Item>(
    FunctionReference<QueryType, A, PaginationResult<Item>> query,
    A args, {
    required int initialNumItems,
    required void Function(PaginatedQueryResult<Item> result) callback,
    void Function(Object error)? onError,
  }) {
    if (disabled) {
      return _createDisabledUnsubscribe<PaginatedQueryResult<Item>>();
    }

    // Simple client doesn't use IDs; these queries needn't stay separate.
    const id = -1;
    final (:paginatedQueryToken, :unsubscribe) = paginatedClient.subscribe(
      getFunctionName(query),
      parseArgs(args),
      initialNumItems: initialNumItems,
      id: id,
    );

    final queryInfo = _QueryInfo(
      queryToken: paginatedQueryToken,
      decode: (result) => _typed<Item>(result! as PaginatedQueryResult<Value>),
      callback: (result) => callback(result! as PaginatedQueryResult<Item>),
      onError: onError,
      unsubscribe: unsubscribe,
    );
    _listeners.add(queryInfo);

    // A result already in memory runs the callback soon.
    if (paginatedClient.localQueryResultByToken(paginatedQueryToken) != null &&
        _callNewListenersWithCurrentValuesTimer == null) {
      _callNewListenersWithCurrentValuesTimer = Timer(
        Duration.zero,
        _callNewListenersWithCurrentValues,
      );
    }

    return Unsubscribe<PaginatedQueryResult<Item>>._(
      () {
        if (closed) {
          // all unsubscribes already ran
          return;
        }
        _listeners.remove(queryInfo);
        unsubscribe();
      },
      () {
        final result = paginatedClient.localQueryResult(
          getFunctionName(query),
          parseArgs(args),
          initialNumItems: initialNumItems,
          id: id,
        );
        return result == null ? null : (value: _typed<Item>(result));
      },
      // Paginated queries don't aggregate their logs
      () => const [],
    );
  }

  static PaginatedQueryResult<Item> _typed<Item>(
    PaginatedQueryResult<Value> result,
  ) => PaginatedQueryResult<Item>(
    results: result.results.cast<Item>(),
    status: result.status,
    loadMore: result.loadMore,
  );

  // Run callbacks that never ran, if their query has a result now.
  void _callNewListenersWithCurrentValues() {
    _callNewListenersWithCurrentValuesTimer = null;
    _transitionImpl(const [], callNewListeners: true);
  }

  bool _queryResultReady(QueryToken queryToken) =>
      client.hasLocalQueryResultByToken(queryToken);

  Unsubscribe<T> _createDisabledUnsubscribe<T>() =>
      Unsubscribe<T>._(() {}, () => null, () => null);

  /// Closes the connection and drops every callback.
  Future<void> close() async {
    if (disabled) return;
    // prevent pending updates
    _listeners.clear();
    _closed = true;
    _paginatedClient = null;
    return client.close();
  }

  /// The current JWT auth token and decoded claims.
  ({String token, Map<String, Object?> decoded})? getAuth() {
    if (disabled) return null;
    return client.getCurrentAuthClaims();
  }

  /// Sets the source of auth tokens; [fetchToken] runs again whenever a
  /// token expires, and returns `null` when no token can be had.
  void setAuth(
    AuthTokenFetcher fetchToken, [
    void Function(bool isAuthenticated)? onChange,
  ]) {
    if (disabled) return;
    client.setAuth(fetchToken, onChange ?? (_) {});
  }

  /// Authenticates with an admin key, optionally acting as [identity].
  @internal
  void setAdminAuth(String token, [UserIdentityAttributes? identity]) {
    if (closed) {
      throw StateError('ConvexClient has already been closed.');
    }
    if (disabled) return;
    client.setAdminAuth(token, identity);
  }

  void _transition(ExtendedTransition transition) => _transitionImpl([
    for (final query in transition.queries) query.token,
    for (final query in transition.paginatedQueries) query.token,
  ]);

  void _transitionImpl(
    List<QueryToken> updatedQueries, {
    bool callNewListeners = false,
  }) {
    // Deduping subscriptions happens in the BaseConvexClient, so not much to do here.

    // Call all callbacks in the order they were registered
    for (final queryInfo in _listeners.toList()) {
      final queryToken = queryInfo.queryToken;
      final isPaginatedQuery = serializedQueryTokenIsPaginated(queryToken);

      final hasResultReady = isPaginatedQuery
          ? _paginatedClient?.localQueryResultByToken(
                  PaginatedQueryToken(queryToken),
                ) !=
                null
          : client.hasLocalQueryResultByToken(queryToken);

      if (updatedQueries.contains(queryToken) ||
          (callNewListeners && !queryInfo.hasEverRun && hasResultReady)) {
        queryInfo.hasEverRun = true;
        Object? newValue;
        try {
          final Object? result;
          if (isPaginatedQuery) {
            final paginated = _paginatedClient?.localQueryResultByToken(
              PaginatedQueryToken(queryToken),
            );
            if (paginated == null) continue;
            result = paginated;
          } else {
            final local = client.localQueryResultByToken(queryToken);
            // A typed callback can't receive "loading".
            if (local == null) continue;
            result = local.value;
          }
          newValue = queryInfo.decode(result);
        } on Object catch (error, stackTrace) {
          final onError = queryInfo.onError;
          if (onError != null) {
            onError(error);
          } else {
            // Make some noise without unsubscribing or failing to call other callbacks.
            Zone.current.handleUncaughtError(error, stackTrace);
          }
          continue;
        }
        queryInfo.callback(newValue);
      }
    }
  }

  /// Runs [mutation]; [optimisticUpdate] updates local query results until
  /// it completes.
  Future<R> mutation<A, R>(
    FunctionReference<MutationType, A, R> mutation,
    A args, {
    OptimisticUpdate<A>? optimisticUpdate,
  }) async {
    if (disabled) throw StateError('ConvexClient is disabled');
    final result = await client.mutation(
      getFunctionName(mutation),
      parseArgs(args),
      optimisticUpdate: optimisticUpdate == null
          ? null
          : (store, rawArgs) => optimisticUpdate(store, rawArgs as A),
    );
    return mutation.decodeResult(result);
  }

  /// Runs [action].
  Future<R> action<A, R>(
    FunctionReference<ActionType, A, R> action,
    A args,
  ) async {
    if (disabled) throw StateError('ConvexClient is disabled');
    final result = await client.action(
      getFunctionName(action),
      parseArgs(args),
    );
    return action.decodeResult(result);
  }

  /// Fetches a query result once.
  Future<R> query<A, R>(FunctionReference<QueryType, A, R> query, A args) {
    if (disabled) throw StateError('ConvexClient is disabled');
    final value = client.localQueryResult(
      getFunctionName(query),
      parseArgs(args),
    );
    if (value != null) return Future.value(query.decodeResult(value.value));

    final completer = Completer<R>();
    late final Unsubscribe<R> unsubscribe;
    unsubscribe = onUpdate(
      query,
      args,
      (value) {
        unsubscribe();
        completer.complete(value);
      },
      (error) {
        unsubscribe();
        completer.completeError(error);
      },
    );
    return completer.future;
  }

  /// The current [ConvexConnectionState] with the Convex backend.
  ConvexConnectionState connectionState() {
    if (disabled) throw StateError('ConvexClient is disabled');
    return client.connectionState();
  }

  /// Calls [cb] each time the [ConvexConnectionState] changes; returns a
  /// function that stops it.
  void Function() subscribeToConnectionState(
    void Function(ConvexConnectionState connectionState) cb,
  ) {
    if (disabled) return () {};
    return client.subscribeToConnectionState(cb);
  }
}
