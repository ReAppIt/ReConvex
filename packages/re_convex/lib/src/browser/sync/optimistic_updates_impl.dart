// Ported from convex/src/browser/sync/optimistic_updates_impl.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

/// An optimistic update function that has been curried over its arguments.
typedef WrappedOptimisticUpdate =
    void Function(OptimisticLocalStore localQueryStore);

class _OptimisticLocalStoreImpl implements OptimisticLocalStore {
  _OptimisticLocalStoreImpl(this._queryResults);

  // A reference to the query results in OptimisticQueryResults
  final QueryResultsMap _queryResults;

  // All of the queries modified by this class
  final List<QueryToken> modifiedQueries = [];

  @override
  ({R value})? getQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
  ) {
    final queryArgs = parseArgs(args);
    final name = getFunctionName(query);
    final queryResult = _queryResults[serializePathAndArgs(name, queryArgs)];
    if (queryResult == null) {
      return null;
    }
    return _decode(query, _queryValue(queryResult.result));
  }

  @override
  List<({A args, ({R value})? value})> getAllQueries<A, R>(
    FunctionReference<QueryType, A, R> query,
  ) {
    final queriesWithName = <({A args, ({R value})? value})>[];
    final name = canonicalizeUdfPath(getFunctionName(query));
    for (final queryResult in _queryResults.values) {
      if (queryResult.udfPath == name) {
        queriesWithName.add((
          args: queryResult.args as A,
          value: _decode(query, _queryValue(queryResult.result)),
        ));
      }
    }
    return queriesWithName;
  }

  @override
  void setQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
    ({R value})? value,
  ) {
    final queryArgs = parseArgs(args);
    final name = getFunctionName(query);
    final queryToken = serializePathAndArgs(name, queryArgs);

    final result = value == null
        ? null
        // It's an optimistic update, so there are no function logs to show.
        : FunctionSuccess(value: value.value, logLines: const []);
    _queryResults[queryToken] = Query(
      udfPath: name,
      args: queryArgs,
      result: result,
    );
    modifiedQueries.add(queryToken);
  }

  static ({R value})? _decode<A, R>(
    FunctionReference<QueryType, A, R> query,
    ({Value value})? raw,
  ) => raw == null ? null : (value: query.decodeResult(raw.value));

  static ({Value value})? _queryValue(FunctionResult? result) =>
      switch (result) {
        null => null,
        FunctionSuccess(:final value) => (value: value),
        // An errored query reads as loading instead of breaking the update.
        FunctionFailure() => null,
      };
}

final class _OptimisticUpdateAndId {
  _OptimisticUpdateAndId(this.update, this.mutationId);

  final WrappedOptimisticUpdate update;
  final RequestId mutationId;
}

/// A query result with optimistic updates applied.
final class Query {
  /// Creates the entry.
  Query({required this.result, required this.udfPath, required this.args});

  /// The result; `null` means an optimistic update set the query loading.
  final FunctionResult? result;

  /// The function path.
  final String udfPath;

  /// The arguments.
  final Map<String, Value> args;
}

/// Query results by token.
typedef QueryResultsMap = Map<QueryToken, Query>;

/// A view of all of our query results with optimistic updates applied on
/// top.
class OptimisticQueryResults {
  QueryResultsMap _queryResults = {};
  List<_OptimisticUpdateAndId> _optimisticUpdates = [];

  /// Applies every optimistic update on top of [serverQueryResults], first
  /// dropping those of [optimisticUpdatesToDrop]; returns the changed
  /// queries.
  List<QueryToken> ingestQueryResultsFromServer(
    QueryResultsMap serverQueryResults,
    Set<RequestId> optimisticUpdatesToDrop,
  ) {
    _optimisticUpdates = _optimisticUpdates
        .where(
          (updateAndId) =>
              !optimisticUpdatesToDrop.contains(updateAndId.mutationId),
        )
        .toList();

    final oldQueryResults = _queryResults;
    _queryResults = Map.of(serverQueryResults);
    final localStore = _OptimisticLocalStoreImpl(_queryResults);
    for (final updateAndId in _optimisticUpdates) {
      updateAndId.update(localStore);
    }

    // To find the changed queries, just do a shallow comparison
    final changedQueries = <QueryToken>[];
    for (final MapEntry(key: queryToken, value: query)
        in _queryResults.entries) {
      final oldQuery = oldQueryResults[queryToken];
      if (oldQuery == null || !identical(oldQuery.result, query.result)) {
        changedQueries.add(queryToken);
      }
    }

    return changedQueries;
  }

  /// Applies [update] for the mutation [mutationId]; returns the queries it
  /// changed.
  List<QueryToken> applyOptimisticUpdate(
    WrappedOptimisticUpdate update,
    RequestId mutationId,
  ) {
    // Apply the update to our store
    _optimisticUpdates.add(_OptimisticUpdateAndId(update, mutationId));
    final localStore = _OptimisticLocalStoreImpl(_queryResults);
    update(localStore);

    // Notify about any query results that changed
    return localStore.modifiedQueries;
  }

  /// The result of [queryToken] with optimistic updates applied, errors
  /// included.
  FunctionResult? rawQueryResult(QueryToken queryToken) =>
      _queryResults[queryToken]?.result;

  /// The value of [queryToken], or `null` while it is loading; throws the
  /// query's error.
  ({Value value})? queryResult(QueryToken queryToken) {
    final query = _queryResults[queryToken];
    if (query == null) {
      return null;
    }
    final result = query.result;
    switch (result) {
      case null:
        return null;
      case FunctionSuccess(:final value):
        return (value: value);
      case FunctionFailure(:final errorData):
        final message = createHybridErrorStacktrace(
          UdfType.query,
          query.udfPath,
          result,
        );
        if (errorData != null) {
          throw forwardData(result, ConvexError<Value>(message));
        }
        throw Exception(message);
    }
  }

  /// Whether [queryToken] has a result or was set loading by an update.
  bool hasQueryResult(QueryToken queryToken) =>
      _queryResults.containsKey(queryToken);

  /// The log lines of [queryToken]'s result.
  List<String>? queryLogs(QueryToken queryToken) =>
      _queryResults[queryToken]?.result?.logLines;
}
