// Ported from convex/src/browser/query_options.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/server/api.dart';

/// A Convex query and its arguments.
final class QueryOptions<A, R> {
  /// Creates the options.
  const QueryOptions({required this.query, required this.args});

  /// The query function to run.
  final FunctionReference<QueryType, A, R> query;

  /// The arguments to the query function.
  final A args;
}

/// Creates [QueryOptions] for [query] and [args], inferring their types.
QueryOptions<A, R> convexQueryOptions<A, R>({
  required FunctionReference<QueryType, A, R> query,
  required A args,
}) => QueryOptions(query: query, args: args);
