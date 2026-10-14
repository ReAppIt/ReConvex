// Ported from convex/src/react/use_paginated_query2.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/use_paginated_query.dart';
import 'package:re_convex/src/flutter/use_queries.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

final class _UsePaginatedQueryState {
  const _UsePaginatedQueryState({
    required this.query,
    required this.args,
    required this.id,
    required this.queries,
    required this.skip,
  });

  final FunctionReference<QueryType, Object?, Object?> query;
  final Map<String, Value> args;
  final int id;
  // Zero or one queries, under `paginatedQuery`.
  final Map<String, QueryRequest> queries;
  final bool skip;
}

/// [usePaginatedQuery] on the client's own pagination logic, which will
/// replace it.
// ignore: non_constant_identifier_names, upstream name.
UsePaginatedQueryResult<Item> usePaginatedQuery_experimental<A, Item>(
  PaginatedQueryReference<A, Item> query,
  A? args, {
  required int initialNumItems,
  bool skip = false,
}) {
  if (initialNumItems < 0) {
    throw ArgumentError(
      '`options.initialNumItems` must be a positive number. Received '
      '`$initialNumItems`.',
    );
  }
  final argsObject = skip ? const <String, Value>{} : parseArgs(args);

  final convexClient = useConvex();
  final logger = convexClient.logger;

  _UsePaginatedQueryState createInitialState() {
    final id = _nextPaginationId();
    return _UsePaginatedQueryState(
      query: query,
      args: argsObject,
      id: id,
      queries: skip
          ? const {}
          : {
              'paginatedQuery': QueryRequest(
                query: query,
                args: {...argsObject},
                paginationOptions: (initialNumItems: initialNumItems, id: id),
              ),
            },
      skip: skip,
    );
  }

  final context = useContext();
  final rebuild = useState(0);
  final stateRef = useRef<_UsePaginatedQueryState?>(null);
  void setState(_UsePaginatedQueryState state) {
    stateRef.value = state;
    scheduleMicrotask(() {
      if (context.mounted) rebuild.value++;
    });
  }

  // `currState` is the state that we'll render based on.
  var currState = stateRef.value ??= createInitialState();
  // New function, args, or skip? New paginated query!
  if (getFunctionName(query) != getFunctionName(currState.query) ||
      jsonEncode(convexToJson(argsObject)) !=
          jsonEncode(convexToJson(currState.args)) ||
      skip != currState.skip) {
    currState = stateRef.value = createInitialState();
  }
  final resultsObject = useQueries(currState.queries);

  if (!resultsObject.containsKey('paginatedQuery')) {
    if (!skip) {
      throw StateError('Why is it missing?');
    }
    return UsePaginatedQueryResult(
      results: const [],
      status: PaginationStatus.loadingFirstPage,
      isLoading: true,
      loadMore: (_) {},
    );
  }
  final result = resultsObject['paginatedQuery'];

  if (result == null) {
    return UsePaginatedQueryResult(
      results: const [],
      status: PaginationStatus.loadingFirstPage,
      isLoading: true,
      loadMore: (_) {},
    );
  }

  if (result is! ({Object? value})) {
    if (isInvalidCursorError(result)) {
      // The cursors no longer match the query: restart pagination.
      logger.warn(
        'usePaginatedQuery hit error, resetting pagination state: '
        '${result is ConvexError ? result.message : result}',
      );
      setState(createInitialState());
      return UsePaginatedQueryResult(
        results: const [],
        status: PaginationStatus.loadingFirstPage,
        isLoading: true,
        loadMore: (_) {},
      );
    }
    // ignore: only_throw_errors, rethrows the query's own error.
    throw result;
  }

  final paginated = result.value! as PaginatedQueryResult<Object?>;
  return UsePaginatedQueryResult(
    results: paginated.results.cast<Item>(),
    status: paginated.status,
    isLoading:
        paginated.status == PaginationStatus.loadingFirstPage ||
        paginated.status == PaginationStatus.loadingMore,
    loadMore: paginated.loadMore,
  );
}

int _paginationId = 0;

int _nextPaginationId() {
  _paginationId++;
  return _paginationId;
}

/// Resets the pagination id of [usePaginatedQuery_experimental], for tests.
@visibleForTesting
void resetPaginationId2() {
  _paginationId = 0;
}
