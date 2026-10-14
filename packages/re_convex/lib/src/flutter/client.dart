// Ported from convex/src/react/client.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/query_options.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/paginated_query_client.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/flutter/convex_auth_state.dart';
import 'package:re_convex/src/flutter/use_queries.dart';
import 'package:re_convex/src/flutter/use_subscription.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/values/value.dart';

// How long `prewarmQuery` keeps a subscription by default.
const Duration _defaultExtendSubscriptionFor = Duration(milliseconds: 5000);

/// A mutation that can be called with its arguments; returned by
/// `useMutation`.
final class ReactMutation<A, R> {
  ReactMutation._(this._mutationReference, this._client, this._update);

  final FunctionReference<MutationType, A, R> _mutationReference;
  final ConvexReactClient _client;
  final OptimisticUpdate<A>? _update;

  /// Runs the mutation.
  Future<R> call(A args) =>
      _client.mutation(_mutationReference, args, optimisticUpdate: _update);

  /// A copy that applies [optimisticUpdate] while the mutation runs; it
  /// must be synchronous.
  ReactMutation<A, R> withOptimisticUpdate(
    OptimisticUpdate<A> optimisticUpdate,
  ) {
    if (_update != null) {
      throw StateError(
        'Already specified optimistic update for mutation '
        '${getFunctionName(_mutationReference)}',
      );
    }
    return createMutation(_mutationReference, _client, optimisticUpdate);
  }
}

/// Creates a [ReactMutation]; exported for tests.
@visibleForTesting
ReactMutation<A, R> createMutation<A, R>(
  FunctionReference<MutationType, A, R> mutationReference,
  ConvexReactClient client, [
  OptimisticUpdate<A>? update,
]) => ReactMutation._(mutationReference, client, update);

/// An action that can be called with its arguments; returned by
/// `useAction`.
final class ReactAction<A, R> {
  ReactAction._(this._actionReference, this._client);

  final FunctionReference<ActionType, A, R> _actionReference;
  final ConvexReactClient _client;

  /// Runs the action.
  Future<R> call(A args) => _client.action(_actionReference, args);
}

/// Creates a [ReactAction].
@internal
ReactAction<A, R> createAction<A, R>(
  FunctionReference<ActionType, A, R> actionReference,
  ConvexReactClient client,
) => ReactAction._(actionReference, client);

/// A watch on the result of a query; it subscribes only while [onUpdate]
/// callbacks are registered.
abstract interface class Watch<T> {
  /// Calls [callback] when the result changes; returns a function that
  /// unsubscribes.
  void Function() onUpdate(void Function() callback);

  /// The current result, or `null` while loading; throws the query's
  /// error.
  ({T value})? localQueryResult();

  /// The log lines of the current result.
  @internal
  List<String>? localQueryLogs();

  /// The current journal, or `null` before the first result.
  QueryJournal journal();
}

/// A watch on the results of a paginated query.
abstract interface class PaginatedWatch<T> {
  /// Calls [callback] when the results change; returns a function that
  /// unsubscribes.
  void Function() onUpdate(void Function() callback);

  /// The current results, or `null` when unknown.
  PaginatedQueryResult<T>? localQueryResult();
}

/// Options for [ConvexReactClient].
class ConvexReactClientOptions extends BaseConvexClientOptions {
  /// Creates the options.
  const ConvexReactClientOptions({
    this.baseClient,
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

  /// A client to use instead of creating one; the other options then have
  /// no effect.
  @internal
  final BaseConvexClientInterface? baseClient;
}

/// A Convex client for Flutter: queries, mutations and actions, with
/// subscriptions shared by every watch on the same query.
///
/// The WebSocket opens on first use.
class ConvexReactClient implements IConvexReactClient {
  /// Creates a client for the deployment at [address], like
  /// `https://happy-otter-123.convex.cloud`.
  ConvexReactClient(
    String address, [
    ConvexReactClientOptions options = const ConvexReactClientOptions(),
  ]) : _address = address,
       _options = options,
       _logger =
           options.logger ??
           instantiateDefaultLogger(verbose: options.verbose) {
    // Validate now; the lazily created internal client validates later.
    if (!address.contains('://')) {
      throw ArgumentError('Provided address was not an absolute URL.');
    }
  }

  final String _address;
  final ConvexReactClientOptions _options;
  final ConvexLogger _logger;
  BaseConvexClientInterface? _cachedSync;
  PaginatedQueryClient? _cachedPaginatedQueryClient;
  Map<QueryToken, Set<void Function()>> _listeners = {};
  // "closed" means this client is done, not just that the underlying WS connection is closed.
  bool _closed = false;
  String? _adminAuth;
  UserIdentityAttributes? _fakeUserIdentity;

  /// The address of the deployment.
  String get url => _address;

  /// The underlying client, created on first access.
  @internal
  BaseConvexClientInterface get sync {
    if (_closed) {
      throw StateError('ConvexReactClient has already been closed.');
    }
    final cached = _cachedSync;
    if (cached != null) {
      return cached;
    }
    // BaseConvexClient and paginated query client are always created together.
    final sync =
        _options.baseClient ??
        BaseConvexClient(
          _address,
          (_) {}, // Use the PaginatedQueryClient's transition instead.
          _baseOptions(),
        );
    _cachedSync = sync;
    final adminAuth = _adminAuth;
    if (adminAuth != null) {
      sync.setAdminAuth(adminAuth, _fakeUserIdentity);
    }
    _cachedPaginatedQueryClient = PaginatedQueryClient(sync, _handleTransition);
    return sync;
  }

  // The options with the resolved logger, shared with the base client.
  BaseConvexClientOptions _baseOptions() => BaseConvexClientOptions(
    webSocketConstructor: _options.webSocketConstructor,
    verbose: _options.verbose,
    logger: _logger,
    reportDebugInfoToConvex: _options.reportDebugInfoToConvex,
    onServerDisconnectError: _options.onServerDisconnectError,
    skipConvexDeploymentUrlCheck: _options.skipConvexDeploymentUrlCheck,
    authRefreshTokenLeeway: _options.authRefreshTokenLeeway,
    expectAuth: _options.expectAuth,
    initialAuthTokenReuse: _options.initialAuthTokenReuse,
    subscribeToOnline: _options.subscribeToOnline,
  );

  /// The paginated query client, created with [sync].
  @internal
  PaginatedQueryClient get paginatedQueryClient {
    // access sync to instantiate the clients
    sync;
    final cached = _cachedPaginatedQueryClient;
    if (cached != null) {
      return cached;
    }
    throw StateError('Should already be instantiated');
  }

  /// Sets the source of auth tokens; [fetchToken] runs again whenever a
  /// token expires. [onChange] reports whether the server accepted a token,
  /// [onRefreshChange] whether a rejected one is being replaced.
  @override
  void setAuth(
    AuthTokenFetcher fetchToken, [
    void Function(bool isAuthenticated)? onChange,
    void Function(bool isRefreshing)? onRefreshChange,
  ]) {
    sync.setAuth(fetchToken, onChange ?? (_) {}, onRefreshChange);
  }

  /// Clears the auth token.
  @override
  void clearAuth() {
    sync.clearAuth();
  }

  /// Authenticates with an admin key, optionally acting as [identity].
  @internal
  void setAdminAuth(String token, [UserIdentityAttributes? identity]) {
    _adminAuth = token;
    _fakeUserIdentity = identity;
    if (_closed) {
      throw StateError('ConvexReactClient has already been closed.');
    }
    if (_cachedSync != null) {
      sync.setAdminAuth(token, identity);
    }
  }

  /// A [Watch] on [query] with [args].
  ///
  /// [journal] from a previous run only applies to a new subscription.
  Watch<R> watchQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args, {
    QueryJournal journal,
    @internal String? componentPath,
  }) => _Watch(
    this,
    query,
    parseArgs(args),
    journal: journal,
    componentPath: componentPath,
  );

  /// Subscribes to a query for [extendSubscriptionFor], so a later
  /// `useQuery` or [query] finds its result already loaded.
  void prewarmQuery<A, R>(
    QueryOptions<A, R> queryOptions, {
    Duration extendSubscriptionFor = _defaultExtendSubscriptionFor,
  }) {
    final watch = watchQuery(queryOptions.query, queryOptions.args);
    final unsubscribe = watch.onUpdate(() {});
    Timer(extendSubscriptionFor, unsubscribe);
  }

  /// A [PaginatedWatch] on [query] with [args] (without `paginationOpts`).
  @internal
  PaginatedWatch<Item> watchPaginatedQuery<A, Item>(
    FunctionReference<QueryType, A, Object?> query,
    A args, {
    required int initialNumItems,
    required int id,
    String? componentPath,
  }) => _PaginatedWatch(
    this,
    getFunctionName(query),
    parseArgs(args),
    initialNumItems: initialNumItems,
    id: id,
  );

  /// Runs [mutation]; [optimisticUpdate] updates local query results until
  /// it completes.
  Future<R> mutation<A, R>(
    FunctionReference<MutationType, A, R> mutation,
    A args, {
    OptimisticUpdate<A>? optimisticUpdate,
  }) async {
    final name = getFunctionName(mutation);
    final result = await sync.mutation(
      name,
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
    final name = getFunctionName(action);
    return action.decodeResult(await sync.action(name, parseArgs(args)));
  }

  /// Fetches a query result once, from memory when it is already loaded.
  ///
  /// Most code should subscribe instead, with [watchQuery] or `useQuery`.
  Future<R> query<A, R>(FunctionReference<QueryType, A, R> query, A args) {
    final watch = watchQuery(query, args);
    final existingResult = watch.localQueryResult();
    if (existingResult != null) {
      return Future.value(existingResult.value);
    }
    final completer = Completer<R>();
    late final void Function() unsubscribe;
    unsubscribe = watch.onUpdate(() {
      final ({R value})? result;
      try {
        result = watch.localQueryResult();
      } on Object catch (error, stackTrace) {
        unsubscribe();
        completer.completeError(error, stackTrace);
        return;
      }
      // An optimistic update can set the query loading; keep waiting.
      if (result == null) return;
      unsubscribe();
      completer.complete(result.value);
    });
    return completer.future;
  }

  /// The current [ConvexConnectionState] with the Convex backend.
  ConvexConnectionState connectionState() => sync.connectionState();

  /// Calls [cb] each time the [ConvexConnectionState] changes; returns a
  /// function that stops it.
  void Function() subscribeToConnectionState(
    void Function(ConvexConnectionState connectionState) cb,
  ) => sync.subscribeToConnectionState(cb);

  /// The logger this client writes to.
  ConvexLogger get logger => _logger;

  /// Closes the connection; the client can't be used afterwards.
  Future<void> close() async {
    _closed = true;
    // Prevent outstanding batched updates from invoking listeners.
    _listeners = {};
    _cachedPaginatedQueryClient = null;
    final sync = _cachedSync;
    if (sync != null) {
      _cachedSync = null;
      await sync.close();
    }
  }

  void _handleTransition(ExtendedTransition transition) {
    _transition([
      for (final query in transition.queries) query.token,
      for (final query in transition.paginatedQueries) query.token,
    ]);
  }

  void _transition(List<QueryToken> updatedQueries) {
    for (final queryToken in updatedQueries) {
      final callbacks = _listeners[queryToken];
      if (callbacks != null) {
        for (final callback in callbacks.toList()) {
          callback();
        }
      }
    }
  }

  void Function() _addListener(
    QueryToken queryToken,
    void Function() callback,
    void Function() unsubscribe,
  ) {
    (_listeners[queryToken] ??= {}).add(callback);
    return () {
      if (_closed) {
        return;
      }
      final currentListeners = _listeners[queryToken]!;
      currentListeners.remove(callback);
      if (currentListeners.isEmpty) {
        _listeners.remove(queryToken);
      }
      unsubscribe();
    };
  }
}

final class _Watch<A, R> implements Watch<R> {
  _Watch(
    this._client,
    this._query,
    this._args, {
    required QueryJournal journal,
    required String? componentPath,
  }) : _journal = journal,
       _componentPath = componentPath;

  final ConvexReactClient _client;
  final FunctionReference<QueryType, A, R> _query;
  final Map<String, Value> _args;
  final QueryJournal _journal;
  final String? _componentPath;

  String get _name => getFunctionName(_query);

  @override
  void Function() onUpdate(void Function() callback) {
    final (:queryToken, :unsubscribe) = _client.sync.subscribe(
      _name,
      _args,
      journal: _journal,
      componentPath: _componentPath,
    );
    return _client._addListener(queryToken, callback, unsubscribe);
  }

  @override
  ({R value})? localQueryResult() {
    // Without a client yet there can't be a result.
    final cached = _client._cachedSync;
    if (cached == null) {
      return null;
    }
    final result = cached.localQueryResult(_name, _args);
    return result == null ? null : (value: _query.decodeResult(result.value));
  }

  @override
  List<String>? localQueryLogs() =>
      _client._cachedSync?.localQueryLogs(_name, _args);

  @override
  QueryJournal journal() => _client._cachedSync?.queryJournal(_name, _args);
}

final class _PaginatedWatch<Item> implements PaginatedWatch<Item> {
  _PaginatedWatch(
    this._client,
    this._name,
    this._args, {
    required int initialNumItems,
    required int id,
  }) : _initialNumItems = initialNumItems,
       _id = id;

  final ConvexReactClient _client;
  final String _name;
  final Map<String, Value> _args;
  final int _initialNumItems;
  final int _id;

  @override
  void Function() onUpdate(void Function() callback) {
    final (:paginatedQueryToken, :unsubscribe) = _client.paginatedQueryClient
        .subscribe(_name, _args, initialNumItems: _initialNumItems, id: _id);
    return _client._addListener(paginatedQueryToken, callback, unsubscribe);
  }

  @override
  PaginatedQueryResult<Item>? localQueryResult() {
    final result = _client.paginatedQueryClient.localQueryResult(
      _name,
      _args,
      initialNumItems: _initialNumItems,
      id: _id,
    );
    if (result == null) {
      return null;
    }
    return PaginatedQueryResult<Item>(
      results: result.results.cast<Item>(),
      status: result.status,
      loadMore: result.loadMore,
    );
  }
}

/// Makes [client] available to the hooks below it.
class ConvexProvider extends InheritedWidget {
  /// Creates the provider.
  const ConvexProvider({super.key, required this.client, required super.child});

  /// The client the hooks use.
  final ConvexReactClient client;

  /// The client of the nearest [ConvexProvider], if any.
  static ConvexReactClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConvexProvider>()?.client;

  @override
  bool updateShouldNotify(ConvexProvider oldWidget) =>
      !identical(client, oldWidget.client);
}

/// The client of the nearest [ConvexProvider], or `null`.
@internal
ConvexReactClient? useConvexOrNull() => ConvexProvider.maybeOf(useContext());

/// The [ConvexReactClient] of the nearest [ConvexProvider].
ConvexReactClient useConvex() {
  final convex = useConvexOrNull();
  if (convex == null) {
    throw StateError(
      'Could not find Convex client! `useConvex` must be used in the widget '
      'tree under `ConvexProvider`. Did you forget it?',
    );
  }
  return convex;
}

// Memoizes the request so equal arguments don't resubscribe.
Map<String, QueryRequest> _useQueryRequest<A, R>(
  FunctionReference<QueryType, A, R> query,
  A? args, {
  required bool skip,
}) {
  final argsObject = skip ? const <String, Value>{} : parseArgs(args);
  final queryName = getFunctionName(query);
  return useMemoized(
    () => skip
        ? const <String, QueryRequest>{}
        : {'query': QueryRequest(query: query, args: argsObject)},
    [jsonEncode(convexToJson(argsObject)), queryName, skip],
  );
}

/// Subscribes to [query] and returns its result in a record (`null` can be a
/// result), or `null` while loading or with [skip]; throws the query's error.
({R value})? useQuery<A, R>(
  FunctionReference<QueryType, A, R> query,
  A? args, {
  bool skip = false,
}) {
  final results = useQueries(_useQueryRequest(query, args, skip: skip));
  final result = results['query'];
  if (result is ({Object? value})) {
    return (value: result.value as R);
  }
  if (result == null) {
    return null;
  }
  // ignore: only_throw_errors, rethrows the query's own error.
  throw result;
}

/// The state of a query, as [useQuery_experimental] returns it.
sealed class UseQueryResult<T> {
  const UseQueryResult();

  /// `pending`, `success` or `error`.
  String get status;
}

/// The query is loading or skipped.
final class UseQueryPending<T> extends UseQueryResult<T> {
  /// Creates the result.
  const UseQueryPending();

  @override
  String get status => 'pending';
}

/// The query returned [data].
final class UseQuerySuccess<T> extends UseQueryResult<T> {
  /// Creates the result.
  const UseQuerySuccess(this.data);

  /// The result.
  final T data;

  @override
  String get status => 'success';
}

/// The query threw [error].
final class UseQueryError<T> extends UseQueryResult<T> {
  /// Creates the result.
  const UseQueryError(this.error);

  /// The error.
  final Object error;

  @override
  String get status => 'error';
}

/// [useQuery] returning a [UseQueryResult] instead of throwing, unless
/// [throwOnError].
// ignore: non_constant_identifier_names, upstream name.
UseQueryResult<R> useQuery_experimental<A, R>({
  required FunctionReference<QueryType, A, R> query,
  required A? args,
  bool skip = false,
  bool throwOnError = false,
}) {
  final results = useQueries(_useQueryRequest(query, args, skip: skip));
  final result = results['query'];
  if (result is ({Object? value})) {
    return UseQuerySuccess(result.value as R);
  }
  if (result == null) {
    return UseQueryPending<R>();
  }
  if (throwOnError) {
    // ignore: only_throw_errors, rethrows the query's own error.
    throw result;
  }
  return UseQueryError<R>(result);
}

/// A [ReactMutation] for [mutation] on the nearest [ConvexProvider]'s
/// client.
ReactMutation<A, R> useMutation<A, R>(
  FunctionReference<MutationType, A, R> mutation,
) {
  final convex = useConvexOrNull();
  if (convex == null) {
    throw StateError(
      'Could not find Convex client! `useMutation` must be used in the '
      'widget tree under `ConvexProvider`. Did you forget it?',
    );
  }
  return useMemoized(() => createMutation(mutation, convex), [
    convex,
    getFunctionName(mutation),
  ]);
}

/// A [ReactAction] for [action] on the nearest [ConvexProvider]'s client.
ReactAction<A, R> useAction<A, R>(FunctionReference<ActionType, A, R> action) {
  final convex = useConvexOrNull();
  if (convex == null) {
    throw StateError(
      'Could not find Convex client! `useAction` must be used in the widget '
      'tree under `ConvexProvider`. Did you forget it?',
    );
  }
  return useMemoized(() => createAction(action, convex), [
    convex,
    getFunctionName(action),
  ]);
}

/// The [ConvexConnectionState] of the nearest [ConvexProvider]'s client,
/// rebuilding when it changes.
ConvexConnectionState useConvexConnectionState() {
  final convex = useConvexOrNull();
  if (convex == null) {
    throw StateError(
      'Could not find Convex client! `useConvexConnectionState` must be used '
      'in the widget tree under `ConvexProvider`. Did you forget it?',
    );
  }
  final getCurrentValue = useCallback(convex.connectionState, [convex]);
  final subscribe = useCallback(
    (void Function() callback) =>
        convex.subscribeToConnectionState((_) => callback()),
    [convex],
  );
  return useSubscription(
    getCurrentValue: getCurrentValue,
    subscribe: subscribe,
  );
}
