// Ported from convex/src/react/queries_observer.ts (Apache-2.0); modified for Dart.
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/value.dart';

/// The pagination options of a paginated query request.
typedef SubscribeToPaginatedQueryOptions = ({int initialNumItems, int id});

/// One query of a `useQueries` request: [query] with [args].
final class QueryRequest {
  /// Creates the request.
  const QueryRequest({
    required this.query,
    required this.args,
    @internal this.paginationOptions,
  });

  /// The query to subscribe to.
  final FunctionReference<QueryType, Object?, Object?> query;

  /// Its arguments.
  final Map<String, Value> args;

  /// Subscribes through the paginated query client instead.
  @internal
  final SubscribeToPaginatedQueryOptions? paginationOptions;
}

/// Creates a [Watch] or, with pagination options, a [PaginatedWatch].
typedef CreateWatch =
    Object Function(
      FunctionReference<QueryType, Object?, Object?> query,
      Map<String, Value> args, {
      QueryJournal journal,
      SubscribeToPaginatedQueryOptions? paginationOptions,
    });

final class _QueryInfo {
  _QueryInfo({
    required this.query,
    required this.args,
    required this.watch,
    required this.unsubscribe,
    this.paginationOptions,
  });

  final FunctionReference<QueryType, Object?, Object?> query;
  final Map<String, Value> args;
  final Object watch;
  final void Function() unsubscribe;
  final SubscribeToPaginatedQueryOptions? paginationOptions;
}

void Function() _onUpdate(Object watch, void Function() callback) =>
    switch (watch) {
      Watch<Object?>() => watch.onUpdate(callback),
      PaginatedWatch<Object?>() => watch.onUpdate(callback),
      _ => throw ArgumentError.value(watch, 'watch', 'Not a watch'),
    };

Object? _localQueryResult(Object watch) => switch (watch) {
  Watch<Object?>() => watch.localQueryResult(),
  PaginatedWatch<Object?>() => switch (watch.localQueryResult()) {
    null => null,
    final result => (value: result),
  },
  _ => throw ArgumentError.value(watch, 'watch', 'Not a watch'),
};

/// Keeps a set of named query subscriptions in sync with a request, for
/// `useQueries`.
@internal
class QueriesObserver {
  /// Creates an observer that subscribes through [createWatch].
  QueriesObserver(this.createWatch);

  /// Creates the watches.
  CreateWatch createWatch;
  final Map<String, _QueryInfo> _queries = {};
  Set<void Function()> _listeners = {};

  /// Subscribes to [newQueries] and drops the queries no longer requested.
  void setQueries(Map<String, QueryRequest> newQueries) {
    // Add before removing, so the client can dedupe repeated queries.
    for (final MapEntry(key: identifier, value: request)
        in newQueries.entries) {
      final QueryRequest(:query, :args, :paginationOptions) = request;
      // Might throw
      getFunctionName(query);

      final existingInfo = _queries[identifier];
      if (existingInfo == null) {
        // No existing query => add it.
        _addQuery(
          identifier,
          query,
          args,
          paginationOptions: paginationOptions,
        );
      } else if (getFunctionName(query) !=
              getFunctionName(existingInfo.query) ||
          jsonEncode(convexToJson(args)) !=
              jsonEncode(convexToJson(existingInfo.args)) ||
          paginationOptions != existingInfo.paginationOptions) {
        // Existing query that doesn't match => remove the old and add the new.
        _removeQuery(identifier);
        _addQuery(
          identifier,
          query,
          args,
          paginationOptions: paginationOptions,
        );
      }
    }

    // Prune all the existing queries that we no longer need.
    for (final identifier in _queries.keys.toList()) {
      if (!newQueries.containsKey(identifier)) {
        _removeQuery(identifier);
      }
    }
  }

  /// Calls [listener] whenever a query result changes; returns a function
  /// that stops it.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  /// The local result of each query: a `({Value value})` record, `null`
  /// while loading, or the error the query threw.
  Map<String, Object?> getLocalResults(Map<String, QueryRequest> queries) {
    final result = <String, Object?>{};
    for (final MapEntry(key: identifier, value: request) in queries.entries) {
      final QueryRequest(:query, :args, :paginationOptions) = request;

      // Might throw
      getFunctionName(query);

      // Not watched; only reads the local result.
      final watch = createWatch(
        query,
        args,
        paginationOptions: paginationOptions,
      );

      Object? value;
      try {
        value = _localQueryResult(watch);
      } on Object catch (e) {
        value = e;
      }
      result[identifier] = value;
    }
    return result;
  }

  /// Switches to [createWatch], re-creating every watch and keeping its
  /// journal.
  void setCreateWatch(CreateWatch createWatch) {
    this.createWatch = createWatch;
    // If we have a new watch, we might be using a new Convex client.
    for (final identifier in _queries.keys.toList()) {
      final info = _queries[identifier]!;
      final watch = info.watch;
      final journal = watch is Watch<Object?> ? watch.journal() : null;
      _removeQuery(identifier);
      _addQuery(
        identifier,
        info.query,
        info.args,
        journal: journal,
        paginationOptions: info.paginationOptions,
      );
    }
  }

  /// Unsubscribes from every query and drops the listeners.
  void destroy() {
    for (final identifier in _queries.keys.toList()) {
      _removeQuery(identifier);
    }
    _listeners = {};
  }

  void _addQuery(
    String identifier,
    FunctionReference<QueryType, Object?, Object?> query,
    Map<String, Value> args, {
    SubscribeToPaginatedQueryOptions? paginationOptions,
    QueryJournal journal,
  }) {
    if (_queries.containsKey(identifier)) {
      throw StateError(
        'Tried to add a new query with identifier $identifier when it '
        'already exists.',
      );
    }
    final watch = createWatch(
      query,
      args,
      journal: journal,
      paginationOptions: paginationOptions,
    );
    final unsubscribe = _onUpdate(watch, _notifyListeners);
    _queries[identifier] = _QueryInfo(
      query: query,
      args: args,
      watch: watch,
      unsubscribe: unsubscribe,
      paginationOptions: paginationOptions,
    );
  }

  void _removeQuery(String identifier) {
    final info = _queries.remove(identifier);
    if (info == null) {
      throw StateError('No query found with identifier $identifier.');
    }
    info.unsubscribe();
  }

  void _notifyListeners() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}
