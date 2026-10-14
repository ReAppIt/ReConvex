// Ported from convex/src/react/use_queries.ts (Apache-2.0); modified for Dart.
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:meta/meta.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/flutter/client.dart';
import 'package:re_convex/src/flutter/queries_observer.dart';
import 'package:re_convex/src/flutter/use_subscription.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/value.dart';

export 'package:re_convex/src/flutter/queries_observer.dart'
    show QueryRequest, SubscribeToPaginatedQueryOptions;

/// The queries of a [useQueries] request, by identifier.
typedef RequestForQueries = Map<String, QueryRequest>;

/// Subscribes to several queries at once, by identifier.
///
/// Each result is a `({Value value})` record, `null` while loading, or the
/// error the query threw. Memoize [queries]: a new map resubscribes.
Map<String, Object?> useQueries(RequestForQueries queries) {
  final convex = useConvexOrNull();
  if (convex == null) {
    // Includes `useQuery`, which calls this hook more often than apps do.
    throw StateError(
      'Could not find Convex client! `useQuery` must be used in the widget '
      'tree under `ConvexProvider`. Did you forget it?',
    );
  }
  final CreateWatch createWatch = useMemoized(
    () =>
        (
          FunctionReference<QueryType, Object?, Object?> query,
          Map<String, Value> args, {
          QueryJournal journal,
          SubscribeToPaginatedQueryOptions? paginationOptions,
        }) => paginationOptions != null
        ? convex.watchPaginatedQuery<Object?, Object?>(
            query,
            args,
            initialNumItems: paginationOptions.initialNumItems,
            id: paginationOptions.id,
          )
        : convex.watchQuery(query, args, journal: journal),
    [convex],
  );
  return useQueriesHelper(queries, createWatch);
}

/// [useQueries] with an injected [createWatch], for tests.
@internal
Map<String, Object?> useQueriesHelper(
  RequestForQueries queries,
  CreateWatch createWatch,
) {
  final observer = useMemoized(() => QueriesObserver(createWatch));

  if (!identical(observer.createWatch, createWatch)) {
    observer.setCreateWatch(createWatch);
  }

  // Unsubscribe from all queries on unmount.
  useEffect(() => observer.destroy, [observer]);

  final subscription = useMemoized(
    () => (
      getCurrentValue: () => observer.getLocalResults(queries),
      subscribe: (void Function() callback) {
        observer.setQueries(queries);
        return observer.subscribe(callback);
      },
    ),
    [observer, queries],
  );

  return useSubscription(
    getCurrentValue: subscription.getCurrentValue,
    subscribe: subscription.subscribe,
  );
}
