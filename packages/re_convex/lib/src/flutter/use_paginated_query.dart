// Ported from convex/src/react/use_paginated_query.ts (Apache-2.0); modified for Dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/use_queries.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/pagination.dart';
import 'package:re_convex/src/values/compare.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

/// A query usable with `usePaginatedQuery`: it takes `paginationOpts` and
/// returns a [PaginationResult].
typedef PaginatedQueryReference<A, Item> =
    FunctionReference<QueryType, A, PaginationResult<Item>>;

// Incrementing integer for each page queried in the usePaginatedQuery hook.
typedef _QueryPageKey = int;

final class _UsePaginatedQueryState {
  const _UsePaginatedQueryState({
    required this.query,
    required this.args,
    required this.id,
    required this.nextPageKey,
    required this.pageKeys,
    required this.queries,
    required this.ongoingSplits,
    required this.skip,
  });

  final FunctionReference<QueryType, Object?, Object?> query;
  final Map<String, Value> args;
  final int id;
  final _QueryPageKey nextPageKey;
  final List<_QueryPageKey> pageKeys;
  // Keyed by page key.
  final Map<String, QueryRequest> queries;
  final Map<_QueryPageKey, (_QueryPageKey, _QueryPageKey)> ongoingSplits;
  final bool skip;

  _UsePaginatedQueryState copyWith({
    _QueryPageKey? nextPageKey,
    List<_QueryPageKey>? pageKeys,
    Map<String, QueryRequest>? queries,
    Map<_QueryPageKey, (_QueryPageKey, _QueryPageKey)>? ongoingSplits,
  }) => _UsePaginatedQueryState(
    query: query,
    args: args,
    id: id,
    nextPageKey: nextPageKey ?? this.nextPageKey,
    pageKeys: pageKeys ?? this.pageKeys,
    queries: queries ?? this.queries,
    ongoingSplits: ongoingSplits ?? this.ongoingSplits,
    skip: skip,
  );
}

QueryRequest _pageRequest(
  _UsePaginatedQueryState state,
  Map<String, Value> paginationOpts,
) => QueryRequest(
  query: state.query,
  args: {...state.args, 'paginationOpts': paginationOpts},
);

Map<String, Value> _pageOpts(
  _UsePaginatedQueryState state,
  _QueryPageKey key,
) => parseArgs(state.queries['$key']!.args['paginationOpts']);

_UsePaginatedQueryState Function(_UsePaginatedQueryState) _splitQuery(
  _QueryPageKey key,
  String splitCursor,
  String continueCursor,
) => (prevState) {
  final queries = {...prevState.queries};
  final splitKey1 = prevState.nextPageKey;
  final splitKey2 = prevState.nextPageKey + 1;
  final opts = _pageOpts(prevState, key);
  queries['$splitKey1'] = _pageRequest(prevState, {
    ...opts,
    'endCursor': splitCursor,
  });
  queries['$splitKey2'] = _pageRequest(prevState, {
    ...opts,
    'cursor': splitCursor,
    'endCursor': continueCursor,
  });
  return prevState.copyWith(
    nextPageKey: prevState.nextPageKey + 2,
    queries: queries,
    ongoingSplits: {...prevState.ongoingSplits, key: (splitKey1, splitKey2)},
  );
};

_UsePaginatedQueryState Function(_UsePaginatedQueryState) _completeSplitQuery(
  _QueryPageKey key,
) => (prevState) {
  final completedSplit = prevState.ongoingSplits[key];
  if (completedSplit == null) {
    return prevState;
  }
  final queries = {...prevState.queries}..remove('$key');
  final ongoingSplits = {...prevState.ongoingSplits}..remove(key);
  var pageKeys = [...prevState.pageKeys];
  final pageIndex = prevState.pageKeys.indexOf(key);
  if (pageIndex >= 0) {
    pageKeys = [
      ...prevState.pageKeys.sublist(0, pageIndex),
      completedSplit.$1,
      completedSplit.$2,
      ...prevState.pageKeys.sublist(pageIndex + 1),
    ];
  }
  return prevState.copyWith(
    queries: queries,
    pageKeys: pageKeys,
    ongoingSplits: ongoingSplits,
  );
};

/// The loaded items of a paginated query and how to load more, from
/// [usePaginatedQuery].
final class UsePaginatedQueryResult<Item> {
  /// Creates the result.
  const UsePaginatedQueryResult({
    required this.results,
    required this.status,
    required this.isLoading,
    required this.loadMore,
  });

  /// Every loaded item, across pages.
  final List<Item> results;

  /// The loading state.
  final PaginationStatus status;

  /// Whether a page is loading.
  final bool isLoading;

  /// Loads more items: `loadMore(numItems)`. Does nothing unless the
  /// status is [PaginationStatus.canLoadMore].
  final void Function(int numItems) loadMore;
}

/// Whether [error] means the page cursors no longer match the query.
@internal
bool isInvalidCursorError(Object error) {
  final message = error is ConvexError ? error.message : '$error';
  final data = error is ConvexError ? error.data : null;
  return message.contains('InvalidCursor') ||
      (data is Map<Object?, Object?> &&
          data['isConvexSystemError'] == true &&
          data['paginationError'] == 'InvalidCursor');
}

/// Loads [query] page by page: [initialNumItems] first, then what each
/// `loadMore` asks for. [args] exclude `paginationOpts`; an invalid cursor
/// restarts the pages.
UsePaginatedQueryResult<Item> usePaginatedQuery<A, Item>(
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
  final queryName = getFunctionName(query);
  final argsJson = jsonEncode(convexToJson(argsObject));
  final createInitialState = useMemoized(
    () => () {
      final id = nextPaginationId();
      final state = _UsePaginatedQueryState(
        query: query,
        args: argsObject,
        id: id,
        nextPageKey: 1,
        pageKeys: skip ? const [] : const [0],
        queries: const {},
        ongoingSplits: const {},
        skip: skip,
      );
      return skip
          ? state
          : state.copyWith(
              queries: {
                '0': _pageRequest(state, {
                  'numItems': initialNumItems.toDouble(),
                  'cursor': null,
                  'id': id.toDouble(),
                }),
              },
            );
    },
    [argsJson, queryName, initialNumItems, skip],
  );

  final context = useContext();
  final rebuild = useState(0);
  final stateRef = useRef<_UsePaginatedQueryState?>(null);
  // Applies now and rebuilds after this build, which can't rebuild itself.
  void setState(
    _UsePaginatedQueryState Function(_UsePaginatedQueryState) update,
  ) {
    stateRef.value = update(stateRef.value!);
    scheduleMicrotask(() {
      if (context.mounted) rebuild.value++;
    });
  }

  // `currState` is the state that we'll render based on.
  var currState = stateRef.value ??= createInitialState();
  if (getFunctionName(currState.query) != queryName ||
      jsonEncode(convexToJson(currState.args)) != argsJson ||
      currState.skip != skip) {
    currState = stateRef.value = createInitialState();
  }
  final logger = useConvex().logger;

  final resultsObject = useQueries(currState.queries);

  final allItems = <Object?>[];
  PaginationResult<Object?>? maybeLastResult;
  for (final pageKey in currState.pageKeys) {
    final currResult = resultsObject['$pageKey'];
    if (currResult == null) {
      maybeLastResult = null;
      break;
    }
    if (currResult is! ({Object? value})) {
      // The data changed under the cursors: restart pagination.
      if (isInvalidCursorError(currResult)) {
        logger.warn(
          'usePaginatedQuery hit error, resetting pagination state: '
          '${currResult is ConvexError ? currResult.message : currResult}',
        );
        setState((_) => createInitialState());
        allItems.clear();
        maybeLastResult = null;
        break;
      }
      // ignore: only_throw_errors, rethrows the page's own error.
      throw currResult;
    }
    final result = asPaginationResult(currResult.value);
    maybeLastResult = result;
    final ongoingSplit = currState.ongoingSplits[pageKey];
    final splitCursor = result.splitCursor;
    if (ongoingSplit != null) {
      if (resultsObject['${ongoingSplit.$1}'] != null &&
          resultsObject['${ongoingSplit.$2}'] != null) {
        // Both pages of the split have results now. Swap them in.
        setState(_completeSplitQuery(pageKey));
      }
    } else if (splitCursor != null &&
        splitCursor.isNotEmpty &&
        (result.pageStatus == PageStatus.splitRecommended ||
            result.pageStatus == PageStatus.splitRequired ||
            result.page.length > initialNumItems * 2)) {
      // Split on the server's advice or past double the expected items.
      setState(_splitQuery(pageKey, splitCursor, result.continueCursor));
    }
    if (result.pageStatus == PageStatus.splitRequired) {
      // The page is incomplete: show the pages before it while it splits.
      maybeLastResult = null;
      break;
    }
    allItems.addAll(result.page);
  }

  final results = allItems.cast<Item>();
  final lastResult = maybeLastResult;
  if (lastResult == null) {
    final firstPage = currState.nextPageKey == 1;
    return UsePaginatedQueryResult(
      results: results,
      status: firstPage
          ? PaginationStatus.loadingFirstPage
          : PaginationStatus.loadingMore,
      isLoading: true,
      loadMore: (_) {},
    );
  }
  if (lastResult.isDone) {
    return UsePaginatedQueryResult(
      results: results,
      status: PaginationStatus.exhausted,
      isLoading: false,
      loadMore: (_) {},
    );
  }
  final continueCursor = lastResult.continueCursor;
  var alreadyLoadingMore = false;
  return UsePaginatedQueryResult(
    results: results,
    status: PaginationStatus.canLoadMore,
    isLoading: false,
    loadMore: (numItems) {
      if (alreadyLoadingMore) return;
      alreadyLoadingMore = true;
      setState((prevState) {
        final queries = {...prevState.queries};
        queries['${prevState.nextPageKey}'] = _pageRequest(prevState, {
          'numItems': numItems.toDouble(),
          'cursor': continueCursor,
          'id': prevState.id.toDouble(),
        });
        return prevState.copyWith(
          nextPageKey: prevState.nextPageKey + 1,
          pageKeys: [...prevState.pageKeys, prevState.nextPageKey],
          queries: queries,
        );
      });
    },
  );
}

int _paginationId = 0;

/// Generates a new pagination id, so that separate uses of a paginated
/// query don't share pages.
@internal
int nextPaginationId() {
  _paginationId++;
  return _paginationId;
}

/// Resets the pagination id, for tests.
@visibleForTesting
void resetPaginationId() {
  _paginationId = 0;
}

/// The direction items of a paginated query are sorted in.
enum SortOrder {
  /// Ascending.
  asc,

  /// Descending.
  desc,
}

Map<String, Value> _withoutPaginationOpts(Object? args) =>
    Map.of(parseArgs(args))..remove('paginationOpts');

Object? _paginationOpt(Object? args, String key) =>
    (parseArgs(args)['paginationOpts'] as Map<Object?, Object?>?)?[key];

PaginationResult<Item> _withPage<Item>(
  PaginationResult<Item> value,
  List<Item> page,
) => PaginationResult<Item>.fromValue({...value.json, 'page': page});

bool _matches(Map<String, Value>? argsToMatch, Object? args) {
  if (argsToMatch == null) {
    return true;
  }
  final queryArgs = parseArgs(args);
  return argsToMatch.keys.every(
    (k) =>
        compareValues(
          argsToMatch[k],
          queryArgs.containsKey(k) ? queryArgs[k] : undefinedValue,
        ) ==
        0,
  );
}

/// Optimistically updates every loaded item of [query] whose arguments
/// (without `paginationOpts`) equal [args].
void optimisticallyUpdateValueInPaginatedQuery<A, Item>(
  OptimisticLocalStore localStore,
  PaginatedQueryReference<A, Item> query,
  A args,
  Item Function(Item currentValue) updateValue,
) {
  final expectedArgs = jsonEncode(convexToJson(parseArgs(args)));

  for (final queryResult in localStore.getAllQueries(query)) {
    final value = queryResult.value;
    if (value != null) {
      final innerArgs = _withoutPaginationOpts(queryResult.args);
      if (jsonEncode(convexToJson(innerArgs)) == expectedArgs) {
        final result = value.value;
        localStore.setQuery(query, queryResult.args, (
          value: _withPage(result, result.page.map(updateValue).toList()),
        ));
      }
    }
  }
}

/// Optimistically adds [item] to the top of the first page of
/// [paginatedQuery], once that page has loaded.
///
/// [argsToMatch] limits the update to queries with those arguments.
void insertAtTop<A, Item>({
  required PaginatedQueryReference<A, Item> paginatedQuery,
  required OptimisticLocalStore localQueryStore,
  required Item item,
  Map<String, Value>? argsToMatch,
}) {
  final queries = localQueryStore.getAllQueries(paginatedQuery);
  final queriesThatMatch = queries.where((q) => _matches(argsToMatch, q.args));
  final firstPage = queriesThatMatch
      .where((q) => _paginationOpt(q.args, 'cursor') == null)
      .firstOrNull;
  final firstPageValue = firstPage?.value;
  if (firstPage == null || firstPageValue == null) {
    // first page is not loaded, so don't update it until it loads
    return;
  }
  localQueryStore.setQuery(paginatedQuery, firstPage.args, (
    value: _withPage(firstPageValue.value, [
      item,
      ...firstPageValue.value.page,
    ]),
  ));
}

/// Optimistically adds [item] to the bottom of the last page of
/// [paginatedQuery], only once every page has loaded.
void insertAtBottomIfLoaded<A, Item>({
  required PaginatedQueryReference<A, Item> paginatedQuery,
  required OptimisticLocalStore localQueryStore,
  required Item item,
  Map<String, Value>? argsToMatch,
}) {
  final queries = localQueryStore.getAllQueries(paginatedQuery);
  final queriesThatMatch = queries.where((q) => _matches(argsToMatch, q.args));
  final lastPage = queriesThatMatch
      .where((q) => q.value != null && q.value!.value.isDone)
      .firstOrNull;
  if (lastPage == null) {
    // Last page not loaded: the item would pop out on the next update.
    return;
  }
  final value = lastPage.value!.value;
  localQueryStore.setQuery(paginatedQuery, lastPage.args, (
    value: _withPage(value, [...value.page, item]),
  ));
}

typedef _LoadedResult<A, Item> = ({A args, PaginationResult<Item> value});

/// Optimistically inserts [item] where [sortKeyFromItem] places it among
/// the loaded pages of [paginatedQuery], sorted by [sortOrder].
///
/// Items past the last loaded page are only added once it is the last.
void insertAtPosition<A, Item>({
  required PaginatedQueryReference<A, Item> paginatedQuery,
  required SortOrder sortOrder,
  required Value Function(Item element) sortKeyFromItem,
  required OptimisticLocalStore localQueryStore,
  required Item item,
  Map<String, Value>? argsToMatch,
}) {
  final queries = localQueryStore.getAllQueries(paginatedQuery);
  // One group per usePaginatedQuery: args, with only paginationOpts.id.
  final queryGroups =
      <String, List<({A args, ({PaginationResult<Item> value})? value})>>{};
  for (final query in queries) {
    final queryArgs = parseArgs(query.args);
    if (argsToMatch != null &&
        !argsToMatch.keys.every((k) => argsToMatch[k] == queryArgs[k])) {
      continue;
    }
    final key = jsonEncode(
      convexToJson({
        for (final MapEntry(key: k, value: v) in queryArgs.entries)
          k: k == 'paginationOpts' ? _paginationOpt(query.args, 'id') : v,
      }),
    );
    (queryGroups[key] ??= []).add(query);
  }
  for (final pageQueries in queryGroups.values) {
    _insertAtPositionInPages(
      pageQueries: pageQueries,
      paginatedQuery: paginatedQuery,
      sortOrder: sortOrder,
      sortKeyFromItem: sortKeyFromItem,
      localQueryStore: localQueryStore,
      item: item,
    );
  }
}

void _insertAtPositionInPages<A, Item>({
  required List<({A args, ({PaginationResult<Item> value})? value})>
  pageQueries,
  required PaginatedQueryReference<A, Item> paginatedQuery,
  required SortOrder sortOrder,
  required Value Function(Item element) sortKeyFromItem,
  required OptimisticLocalStore localQueryStore,
  required Item item,
}) {
  final asc = sortOrder == SortOrder.asc;
  final insertedKey = sortKeyFromItem(item);
  final sortedPages = <_LoadedResult<A, Item>>[
    for (final q in pageQueries)
      if (q.value != null && q.value!.value.page.isNotEmpty)
        (args: q.args, value: q.value!.value),
  ];
  sortedPages.sort((a, b) {
    final aKey = sortKeyFromItem(a.value.page[0]);
    final bKey = sortKeyFromItem(b.value.page[0]);
    return asc ? compareValues(aKey, bKey) : compareValues(bKey, aKey);
  });

  // check if the inserted element is before the first page
  if (sortedPages.isEmpty) {
    // no pages, so don't update until they load
    return;
  }
  final firstLoadedPage = sortedPages.first;
  final firstPageKey = sortKeyFromItem(firstLoadedPage.value.page[0]);
  final isBeforeFirstPage = asc
      ? compareValues(insertedKey, firstPageKey) <= 0
      : compareValues(insertedKey, firstPageKey) >= 0;
  if (isBeforeFirstPage) {
    if (_paginationOpt(firstLoadedPage.args, 'cursor') == null) {
      localQueryStore.setQuery(paginatedQuery, firstLoadedPage.args, (
        value: _withPage(firstLoadedPage.value, [
          item,
          ...firstLoadedPage.value.page,
        ]),
      ));
    }
    // Otherwise the very first page is not loaded.
    return;
  }

  final lastLoadedPage = sortedPages.last;
  final lastPageKey = sortKeyFromItem(lastLoadedPage.value.page.last);
  final isAfterLastPage = asc
      ? compareValues(insertedKey, lastPageKey) >= 0
      : compareValues(insertedKey, lastPageKey) <= 0;
  if (isAfterLastPage) {
    // Only once the last page is done, or the item pops out on update.
    if (lastLoadedPage.value.isDone) {
      localQueryStore.setQuery(paginatedQuery, lastLoadedPage.args, (
        value: _withPage(lastLoadedPage.value, [
          ...lastLoadedPage.value.page,
          item,
        ]),
      ));
    }
    return;
  }

  // Insert into the page before the first one starting after the item.
  final successorPageIndex = sortedPages.indexWhere(
    (p) => asc
        ? compareValues(sortKeyFromItem(p.value.page[0]), insertedKey) > 0
        : compareValues(sortKeyFromItem(p.value.page[0]), insertedKey) < 0,
  );
  final pageToUpdate = successorPageIndex == -1
      ? sortedPages.last
      : (successorPageIndex == 0 ? null : sortedPages[successorPageIndex - 1]);
  if (pageToUpdate == null) {
    // no pages, so don't update until they load
    return;
  }
  // Find the first element at or after the inserted element, in sort order.
  final page = pageToUpdate.value.page;
  final indexWithinPage = page.indexWhere(
    (e) => asc
        ? compareValues(sortKeyFromItem(e), insertedKey) >= 0
        : compareValues(sortKeyFromItem(e), insertedKey) <= 0,
  );
  final newPage = indexWithinPage == -1
      ? [...page, item]
      : [
          ...page.sublist(0, indexWithinPage),
          item,
          ...page.sublist(indexWithinPage),
        ];
  localQueryStore.setQuery(paginatedQuery, pageToUpdate.args, (
    value: _withPage(pageToUpdate.value, newPage),
  ));
}
