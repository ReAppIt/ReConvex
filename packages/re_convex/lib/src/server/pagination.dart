// Ported from convex/src/server/pagination.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// An opaque identifier for the start or end of a page.
typedef Cursor = String;

/// Whether the server recommends or requires splitting a page.
extension type const PageStatus._(String value) implements String {
  /// The page is large enough that it should be split.
  static const splitRecommended = PageStatus._('SplitRecommended');

  /// The page must be split before it can grow.
  static const splitRequired = PageStatus._('SplitRequired');

  /// The known statuses.
  static const values = [splitRecommended, splitRequired];
}

/// The result of a paginated query: a page of [T]s and the cursors around it.
extension type PaginationResult<T>.fromValue(Map<String, Value> json) {
  /// Creates a result.
  PaginationResult({
    required List<T> page,
    required bool isDone,
    required Cursor continueCursor,
    Cursor? splitCursor,
    PageStatus? pageStatus,
  }) : json = {
         'continueCursor': continueCursor,
         'isDone': isDone,
         'page': page,
         'pageStatus': ?pageStatus,
         'splitCursor': ?splitCursor,
       };

  /// The page of results.
  List<T> get page => (json['page']! as List<Object?>).cast<T>();

  /// Whether this is the last page.
  bool get isDone => json['isDone']! as bool;

  /// The cursor that continues after this page.
  Cursor get continueCursor => json['continueCursor']! as String;

  /// Where the server would split this page, if it should be split.
  Cursor? get splitCursor => json['splitCursor'] as String?;

  /// Whether the server recommends or requires a split.
  PageStatus? get pageStatus => json['pageStatus'] as PageStatus?;

  /// Any field of the raw result.
  Value operator [](String key) => json[key];
}

/// The `paginationOpts` argument of a paginated query.
extension type PaginationOptions.fromValue(Map<String, Value> json) {
  /// Creates options for a page of [numItems] items starting at [cursor].
  PaginationOptions({
    required num numItems,
    required Cursor? cursor,
    Cursor? endCursor,
    num? id,
    num? maximumRowsRead,
    num? maximumBytesRead,
  }) : json = {
         'cursor': cursor,
         'endCursor': ?endCursor,
         if (id != null) 'id': id.toDouble(),
         if (maximumBytesRead != null)
           'maximumBytesRead': maximumBytesRead.toDouble(),
         if (maximumRowsRead != null)
           'maximumRowsRead': maximumRowsRead.toDouble(),
         'numItems': numItems.toDouble(),
       };

  /// The number of items to load in this page.
  double get numItems => json['numItems']! as double;

  /// Where the page starts, or `null` for the first page.
  Cursor? get cursor => json['cursor'] as String?;

  /// Where the page ends, if fixed.
  Cursor? get endCursor => json['endCursor'] as String?;

  /// A client-chosen id that keeps paginated queries apart.
  double? get id => json['id'] as double?;

  /// The most rows the query may read.
  double? get maximumRowsRead => json['maximumRowsRead'] as double?;

  /// The most bytes the query may read.
  double? get maximumBytesRead => json['maximumBytesRead'] as double?;
}
