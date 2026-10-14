// Ported from convex/src/browser/sync/pagination.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/server/pagination.dart';
import 'package:re_convex/src/values/value.dart';

/// The loading state of a paginated query.
enum PaginationStatus {
  /// The first page is loading.
  loadingFirstPage('LoadingFirstPage'),

  /// More pages can be loaded.
  canLoadMore('CanLoadMore'),

  /// Another page is loading.
  loadingMore('LoadingMore'),

  /// Every page has loaded.
  exhausted('Exhausted');

  const PaginationStatus(this.value);

  /// The upstream name, like `CanLoadMore`.
  final String value;
}

/// Starts loading [numItems] more items; returns whether it did.
///
/// It does nothing while a page is loading or once every item has loaded.
typedef LoadMoreOfPaginatedQuery = bool Function(int numItems);

/// The loaded items of a paginated query, its status and how to load more.
final class PaginatedQueryResult<T> {
  /// Creates a result.
  const PaginatedQueryResult({
    required this.results,
    required this.status,
    required this.loadMore,
  });

  /// Every loaded item, across pages.
  final List<T> results;

  /// The loading state.
  final PaginationStatus status;

  /// Loads more items.
  final LoadMoreOfPaginatedQuery loadMore;
}

/// Checks that [value] holds the arguments of one page query.
Map<String, Value> asPaginationArgs(Value value) {
  final opts = value is Map<String, Object?> ? value['paginationOpts'] : null;
  if (opts is! Map<String, Object?> || opts['numItems'] is! num) {
    throw ArgumentError(
      'Not valid paginated query args: ${stringifyValueForError(value)}',
    );
  }
  return value! as Map<String, Value>;
}

/// Checks that [value] is a pagination result.
PaginationResult<Value> asPaginationResult(Value value) {
  if (value is! Map<String, Object?> ||
      value['page'] is! List<Object?> ||
      value['isDone'] is! bool ||
      value['continueCursor'] is! String) {
    throw ArgumentError(
      'Not a valid paginated query result: ${stringifyValueForError(value)}',
    );
  }
  return PaginationResult<Value>.fromValue(value);
}
