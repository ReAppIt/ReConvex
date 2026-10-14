// Ported from convex/src/browser/sync/udf_path_utils.ts (Apache-2.0); modified for Dart.
import 'dart:convert';

import 'package:re_convex/src/values/value.dart';

/// Adds `:default` to a bare module path and strips a `.js` extension.
String canonicalizeUdfPath(String udfPath) {
  final pieces = udfPath.split(':');
  String moduleName;
  String functionName;
  if (pieces.length == 1) {
    moduleName = pieces[0];
    functionName = 'default';
  } else {
    moduleName = pieces.sublist(0, pieces.length - 1).join(':');
    functionName = pieces[pieces.length - 1];
  }
  if (moduleName.endsWith('.js')) {
    moduleName = moduleName.substring(0, moduleName.length - 3);
  }
  return '$moduleName:$functionName';
}

/// A string representing the name and arguments of a query.
///
/// Its serialization isn't stable; tokens never leave the client.
extension type const QueryToken(String value) implements String {}

/// A [QueryToken] of a paginated query.
extension type const PaginatedQueryToken(String value) implements QueryToken {}

/// The [QueryToken] of [udfPath] called with [args].
QueryToken serializePathAndArgs(String udfPath, Map<String, Value> args) =>
    QueryToken(
      jsonEncode({
        'udfPath': canonicalizeUdfPath(udfPath),
        'args': convexToJson(args),
      }),
    );

/// The token of a paginated query; [args] exclude `paginationOpts`.
PaginatedQueryToken serializePaginatedPathAndArgs(
  String udfPath,
  Map<String, Value> args, {
  required int initialNumItems,
  required int id,
}) => PaginatedQueryToken(
  jsonEncode({
    'type': 'paginated',
    'udfPath': canonicalizeUdfPath(udfPath),
    'args': convexToJson(args),
    'options': convexToJson({
      'initialNumItems': initialNumItems.toDouble(),
      'id': id.toDouble(),
    }),
  }),
);

/// Whether [token] came from [serializePaginatedPathAndArgs].
bool serializedQueryTokenIsPaginated(QueryToken token) =>
    (jsonDecode(token) as Map<String, Object?>)['type'] == 'paginated';
