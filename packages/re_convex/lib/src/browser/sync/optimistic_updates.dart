// Ported from convex/src/browser/sync/optimistic_updates.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/server/api.dart';

/// The client's current query results, for use within optimistic updates.
///
/// `null` means loading (or failed); a record holds the value, maybe `null`.
abstract interface class OptimisticLocalStore {
  /// The result of [query] with [args], or `null` while it is loading.
  ///
  /// Don't mutate the returned value: copy it, then [setQuery].
  ({R value})? getQuery<A, R>(FunctionReference<QueryType, A, R> query, A args);

  /// Every loaded instance of [query], with its arguments.
  List<({A args, ({R value})? value})> getAllQueries<A, R>(
    FunctionReference<QueryType, A, R> query,
  );

  /// Optimistically sets the result of [query] with [args]; `null` marks it
  /// as loading.
  void setQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
    ({R value})? value,
  );
}

/// Updates query results locally while a mutation runs, given the
/// mutation's [Args]. It must be synchronous.
typedef OptimisticUpdate<Args> =
    void Function(OptimisticLocalStore localQueryStore, Args args);
