// Ported from convex/src/browser/sync/paginated_query_client.ts (Apache-2.0); modified for Dart.
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/client.dart';
import 'package:re_convex/src/browser/sync/pagination.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' hide Transition;
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/long.dart';

typedef _QueryPageKey = int;

typedef _PageQuery = ({
  QueryToken queryToken,
  void Function() unsubscribe,
  String? cursor,
});

// `pageKeys` lists active pages in order; split halves wait outside it.
final class _LocalPaginatedQuery {
  _LocalPaginatedQuery({
    required this.token,
    required this.canonicalizedUdfPath,
    required this.args,
    required this.initialNumItems,
    required this.id,
  });

  final PaginatedQueryToken token;
  final String canonicalizedUdfPath;
  // Without paginationOpts.
  final Map<String, Value> args;
  int numSubscribers = 1;
  final int initialNumItems;
  _QueryPageKey nextPageKey = 0;
  final List<_QueryPageKey> pageKeys = [];
  final Map<_QueryPageKey, _PageQuery> pageKeyToQuery = {};
  final Map<_QueryPageKey, (_QueryPageKey, _QueryPageKey)> ongoingSplits = {};
  bool skip = false;
  // Gives separate uses of the query separate identities.
  final int id;
}

/// How a paginated query changed within an [ExtendedTransition].
sealed class PaginatedQueryModification {
  const PaginatedQueryModification();
}

/// A paginated query has new results.
final class UpdatedPaginatedQueryModification
    extends PaginatedQueryModification {
  /// Creates the modification.
  const UpdatedPaginatedQueryModification(this.result);

  /// The new results, or `null` when the query is unknown.
  final PaginatedQueryResult<Value>? result;
}

/// A paginated query was removed.
final class RemovedPaginatedQueryModification
    extends PaginatedQueryModification {
  /// Creates the modification.
  const RemovedPaginatedQueryModification();
}

/// A [Transition] that also lists the paginated queries that changed.
class ExtendedTransition extends Transition {
  /// Creates a transition.
  const ExtendedTransition({
    required super.queries,
    required super.reflectedMutations,
    required super.timestamp,
    required this.paginatedQueries,
  });

  /// The paginated queries that changed.
  final List<
    ({PaginatedQueryToken token, PaginatedQueryModification modification})
  >
  paginatedQueries;
}

/// Maps paginated queries to their page queries and splits pages that grow
/// too large; use its `onTransition` exclusively.
@internal
class PaginatedQueryClient {
  /// Creates the client over `client`; `onTransition` receives every
  /// transition.
  PaginatedQueryClient(this._client, this._onTransition) {
    _client.addOnTransitionHandler(_onBaseTransition);
  }

  final BaseConvexClientInterface _client;
  final void Function(ExtendedTransition transition) _onTransition;
  final Map<PaginatedQueryToken, _LocalPaginatedQuery> _paginatedQuerySet = {};
  // A real transition timestamp, for synthetic transitions.
  final TS _lastTransitionTs = Long.fromNumber(0);

  /// Subscribes to the paginated query [name] with [args] (without
  /// `paginationOpts`).
  ({PaginatedQueryToken paginatedQueryToken, void Function() unsubscribe})
  subscribe(
    String name,
    Map<String, Value> args, {
    required int initialNumItems,
    required int id,
  }) {
    final canonicalizedUdfPath = canonicalizeUdfPath(name);
    // Note that only the expected options are included in the serialization.
    final token = serializePaginatedPathAndArgs(
      canonicalizedUdfPath,
      args,
      initialNumItems: initialNumItems,
      id: id,
    );

    void unsubscribe() => _removePaginatedQuerySubscriber(token);

    final existingEntry = _paginatedQuerySet[token];
    if (existingEntry != null) {
      existingEntry.numSubscribers += 1;
      return (paginatedQueryToken: token, unsubscribe: unsubscribe);
    }

    _paginatedQuerySet[token] = _LocalPaginatedQuery(
      token: token,
      canonicalizedUdfPath: canonicalizedUdfPath,
      args: args,
      initialNumItems: initialNumItems,
      id: id,
    );

    _addPageToPaginatedQuery(token, null, initialNumItems);

    return (paginatedQueryToken: token, unsubscribe: unsubscribe);
  }

  /// The current results of a paginated query; throws when a page failed.
  PaginatedQueryResult<Value>? localQueryResult(
    String name,
    Map<String, Value> args, {
    required int initialNumItems,
    required int id,
  }) {
    final canonicalizedUdfPath = canonicalizeUdfPath(name);
    final token = serializePaginatedPathAndArgs(
      canonicalizedUdfPath,
      args,
      initialNumItems: initialNumItems,
      id: id,
    );
    return localQueryResultByToken(token);
  }

  /// [localQueryResult] by token.
  PaginatedQueryResult<Value>? localQueryResultByToken(
    PaginatedQueryToken token,
  ) {
    final paginatedQuery = _paginatedQuerySet[token];
    if (paginatedQuery == null) {
      return null;
    }

    final activePages = _activePageQueryTokens(paginatedQuery);
    if (activePages.isEmpty) {
      return PaginatedQueryResult(
        results: const [],
        status: PaginationStatus.loadingFirstPage,
        loadMore: (numItems) => _loadMoreOfPaginatedQuery(token, numItems),
      );
    }

    final allResults = <Value>[];

    // Some page is loading (this isn't supposed to happen to any page but the last)
    var hasUndefined = false;
    var isDone = false;

    for (final pageToken in activePages) {
      // Throws, e.g. InvalidCursor, which resets the query with a new id.
      final result = _client.localQueryResultByToken(pageToken);

      if (result == null) {
        hasUndefined = true;
        isDone = false;
        continue;
      }

      final paginationResult = asPaginationResult(result.value);
      allResults.addAll(paginationResult.page);
      // logic only relevant to the last page, we just happen to run it each time
      isDone = paginationResult.isDone;
    }

    final PaginationStatus status;
    if (hasUndefined) {
      status = allResults.isEmpty
          ? PaginationStatus.loadingFirstPage
          : PaginationStatus.loadingMore;
    } else if (isDone) {
      status = PaginationStatus.exhausted;
    } else {
      status = PaginationStatus.canLoadMore;
    }

    return PaginatedQueryResult(
      results: allResults,
      status: status,
      loadMore: (numItems) => _loadMoreOfPaginatedQuery(token, numItems),
    );
  }

  void _onBaseTransition(Transition transition) {
    final changedBaseTokens = [
      for (final query in transition.queries) query.token,
    ];
    final changed = _queriesContainingTokens(changedBaseTokens);

    var paginatedQueries =
        <
          ({PaginatedQueryToken token, PaginatedQueryModification modification})
        >[];

    if (changed.isNotEmpty) {
      _processPaginatedQuerySplits(changed, _client.localQueryResultByToken);

      paginatedQueries = [
        for (final token in changed)
          (
            token: token,
            modification: UpdatedPaginatedQueryModification(
              localQueryResultByToken(token),
            ),
          ),
      ];
    }

    _onTransition(
      ExtendedTransition(
        queries: transition.queries,
        reflectedMutations: transition.reflectedMutations,
        timestamp: transition.timestamp,
        paginatedQueries: paginatedQueries,
      ),
    );
  }

  // Always transitions: the status likely went CanLoadMore to LoadingMore.
  bool _loadMoreOfPaginatedQuery(PaginatedQueryToken token, int numItems) {
    _mustGetPaginatedQuery(token);

    final lastPageToken = _queryTokenForLastPageOfPaginatedQuery(token);
    final lastPageResult = _client.localQueryResultByToken(lastPageToken);

    if (lastPageResult == null) {
      // Still loading a page and concurrent loads are not allowed
      return false;
    }

    final paginationResult = asPaginationResult(lastPageResult.value);
    if (paginationResult.isDone) {
      // No more pages available
      return false;
    }

    _addPageToPaginatedQuery(token, paginationResult.continueCursor, numItems);

    _onTransition(
      ExtendedTransition(
        timestamp: _lastTransitionTs,
        reflectedMutations: const [],
        queries: const [],
        paginatedQueries: [
          (
            token: token,
            modification: UpdatedPaginatedQueryModification(
              localQueryResultByToken(token),
            ),
          ),
        ],
      ),
    );

    return true;
  }

  List<PaginatedQueryToken> _queriesContainingTokens(
    List<QueryToken> queryTokens,
  ) {
    if (queryTokens.isEmpty) {
      return [];
    }

    final changed = <PaginatedQueryToken>[];
    final queryTokenSet = queryTokens.toSet();

    for (final MapEntry(key: paginatedToken, value: paginatedQuery)
        in _paginatedQuerySet.entries) {
      for (final pageToken in _allQueryTokens(paginatedQuery)) {
        if (queryTokenSet.contains(pageToken)) {
          changed.add(paginatedToken);
          break;
        }
      }
    }

    return changed;
  }

  void _processPaginatedQuerySplits(
    List<PaginatedQueryToken> changed,
    ({Value value})? Function(QueryToken token) getResult,
  ) {
    for (final paginatedQueryToken in changed) {
      final paginatedQuery = _mustGetPaginatedQuery(paginatedQueryToken);
      final ongoingSplits = paginatedQuery.ongoingSplits;
      final pageKeyToQuery = paginatedQuery.pageKeyToQuery;

      // Check for any completed splits
      for (final MapEntry(key: pageKey, value: (splitKey1, splitKey2))
          in ongoingSplits.entries.toList()) {
        final bothNewPagesLoaded =
            getResult(pageKeyToQuery[splitKey1]!.queryToken) != null &&
            getResult(pageKeyToQuery[splitKey2]!.queryToken) != null;

        if (bothNewPagesLoaded) {
          _completePaginatedQuerySplit(
            paginatedQuery,
            pageKey,
            splitKey1,
            splitKey2,
          );
        }
      }

      // Check each active page for splits needed
      for (final pageKey in paginatedQuery.pageKeys.toList()) {
        if (ongoingSplits.containsKey(pageKey)) {
          continue; // Already splitting
        }

        final pageEntry = pageKeyToQuery[pageKey];
        if (pageEntry == null) {
          throw StateError('No page query for active pageKey $pageKey');
        }
        final pageResult = getResult(pageEntry.queryToken);
        if (pageResult == null) {
          continue;
        }
        final result = asPaginationResult(pageResult.value);

        // Check if this page needs splitting
        final splitCursor = result.splitCursor;
        final shouldSplit =
            splitCursor != null &&
            splitCursor.isNotEmpty &&
            (result.pageStatus == 'SplitRecommended' ||
                result.pageStatus == 'SplitRequired' ||
                // This client-driven page splitting condition will change in the future.
                result.page.length > paginatedQuery.initialNumItems * 2);

        if (shouldSplit) {
          _splitPaginatedQueryPage(
            paginatedQuery,
            pageKey,
            pageEntry.cursor,
            splitCursor,
            result.continueCursor,
          );
        }
      }
    }
  }

  void _splitPaginatedQueryPage(
    _LocalPaginatedQuery paginatedQuery,
    _QueryPageKey pageKey,
    // Where the page being split started.
    String? startCursor,
    // The end of the first split page and the start of the second.
    String splitCursor,
    // Where the page being split ended.
    String? continueCursor,
  ) {
    final splitKey1 = paginatedQuery.nextPageKey++;
    final splitKey2 = paginatedQuery.nextPageKey++;

    final paginationOpts = <String, Value>{
      'numItems': paginatedQuery.initialNumItems.toDouble(),
      'id': paginatedQuery.id.toDouble(),
    };

    // First split page: same cursor as the original page, ending at splitCursor
    final firstSubscription = _client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      {
        ...paginatedQuery.args,
        'paginationOpts': {
          ...paginationOpts,
          'cursor': startCursor,
          'endCursor': splitCursor,
        },
      },
    );
    paginatedQuery.pageKeyToQuery[splitKey1] = (
      queryToken: firstSubscription.queryToken,
      unsubscribe: firstSubscription.unsubscribe,
      cursor: startCursor,
    );

    // Second split page: cursor starts at splitCursor, endCursor is the original continueCursor
    final secondSubscription = _client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      {
        ...paginatedQuery.args,
        'paginationOpts': {
          ...paginationOpts,
          'cursor': splitCursor,
          'endCursor': continueCursor,
        },
      },
    );
    paginatedQuery.pageKeyToQuery[splitKey2] = (
      queryToken: secondSubscription.queryToken,
      unsubscribe: secondSubscription.unsubscribe,
      cursor: splitCursor,
    );

    paginatedQuery.ongoingSplits[pageKey] = (splitKey1, splitKey2);
  }

  ({QueryToken queryToken, void Function() unsubscribe})
  _addPageToPaginatedQuery(
    PaginatedQueryToken token,
    String? continueCursor,
    int numItems,
  ) {
    final paginatedQuery = _mustGetPaginatedQuery(token);
    final pageKey = paginatedQuery.nextPageKey++;

    final paginationOpts = <String, Value>{
      'cursor': continueCursor,
      'numItems': numItems.toDouble(),
      'id': paginatedQuery.id.toDouble(),
    };

    final pageArgs = {...paginatedQuery.args, 'paginationOpts': paginationOpts};

    final subscription = _client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      pageArgs,
    );

    paginatedQuery.pageKeys.add(pageKey);
    paginatedQuery.pageKeyToQuery[pageKey] = (
      queryToken: subscription.queryToken,
      unsubscribe: subscription.unsubscribe,
      cursor: continueCursor,
    );
    return subscription;
  }

  void _removePaginatedQuerySubscriber(PaginatedQueryToken token) {
    final paginatedQuery = _paginatedQuerySet[token];
    if (paginatedQuery == null) {
      return;
    }

    paginatedQuery.numSubscribers -= 1;
    if (paginatedQuery.numSubscribers > 0) {
      return;
    }

    // Remove all page subscriptions by calling their unsubscribe callbacks
    for (final subscription in paginatedQuery.pageKeyToQuery.values.toList()) {
      subscription.unsubscribe();
    }

    _paginatedQuerySet.remove(token);
  }

  void _completePaginatedQuerySplit(
    _LocalPaginatedQuery paginatedQuery,
    _QueryPageKey pageKey,
    _QueryPageKey splitKey1,
    _QueryPageKey splitKey2,
  ) {
    final originalQuery = paginatedQuery.pageKeyToQuery.remove(pageKey)!;
    final pageIndex = paginatedQuery.pageKeys.indexOf(pageKey);
    paginatedQuery.pageKeys.replaceRange(pageIndex, pageIndex + 1, [
      splitKey1,
      splitKey2,
    ]);
    paginatedQuery.ongoingSplits.remove(pageKey);
    originalQuery.unsubscribe();
  }

  // The query tokens for all active pages, in result order.
  List<QueryToken> _activePageQueryTokens(
    _LocalPaginatedQuery paginatedQuery,
  ) => [
    for (final pageKey in paginatedQuery.pageKeys)
      paginatedQuery.pageKeyToQuery[pageKey]!.queryToken,
  ];

  List<QueryToken> _allQueryTokens(_LocalPaginatedQuery paginatedQuery) => [
    for (final sub in paginatedQuery.pageKeyToQuery.values) sub.queryToken,
  ];

  QueryToken _queryTokenForLastPageOfPaginatedQuery(PaginatedQueryToken token) {
    final paginatedQuery = _mustGetPaginatedQuery(token);
    if (paginatedQuery.pageKeys.isEmpty) {
      throw StateError('No pages for paginated query $token');
    }
    final lastPageKey = paginatedQuery.pageKeys.last;
    return paginatedQuery.pageKeyToQuery[lastPageKey]!.queryToken;
  }

  _LocalPaginatedQuery _mustGetPaginatedQuery(PaginatedQueryToken token) {
    final paginatedQuery = _paginatedQuerySet[token];
    if (paginatedQuery == null) {
      throw StateError('paginated query no longer exists for token $token');
    }
    return paginatedQuery;
  }
}
