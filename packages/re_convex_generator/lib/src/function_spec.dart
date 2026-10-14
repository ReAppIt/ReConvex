// Ported from convex/src/cli/lib/functionSpec.ts (Apache-2.0); modified for Dart.
import 'dart:convert';

import 'package:re_convex_generator/src/validator_json.dart';

/// A Convex function type.
enum FunctionType {
  /// A query.
  query('Query', 'QueryType'),

  /// A mutation.
  mutation('Mutation', 'MutationType'),

  /// An action.
  action('Action', 'ActionType');

  const FunctionType(this.specName, this.marker);

  /// The name in the function spec, like `Query`.
  final String specName;

  /// The re_convex marker type, like `QueryType`.
  final String marker;
}

/// A public function from `npx convex function-spec`.
final class FunctionSpec {
  /// Creates the spec.
  const FunctionSpec({
    required this.modulePath,
    required this.exportName,
    required this.functionType,
    required this.args,
    required this.returns,
  });

  /// The module path without extension, like `admin/users`.
  final String modulePath;

  /// The exported name, like `list` or `default`.
  final String exportName;

  /// Query, mutation or action.
  final FunctionType functionType;

  /// The argument validator; [AnyValidator] when none was declared.
  final ValidatorJson args;

  /// The return validator; [AnyValidator] when none was declared.
  final ValidatorJson returns;

  /// The name the client sends, like `admin/users:sync`; a `default` export
  /// is named by its module.
  String get name =>
      exportName == 'default' ? modulePath : '$modulePath:$exportName';
}

/// Parses the JSON printed by `npx convex function-spec`.
///
/// Keeps public queries, mutations and actions; internal functions, HTTP
/// actions and the deployment `url` are skipped.
List<FunctionSpec> parseFunctionSpec(
  String source, {
  void Function(String message)? onWarning,
}) {
  final Object? json;
  try {
    json = jsonDecode(source);
  } on FormatException catch (e) {
    throw FormatException('Invalid function spec JSON: ${e.message}');
  }
  final functions = json is Map<String, Object?> ? json['functions'] : null;
  if (functions is! List<Object?>) {
    throw const FormatException(
      'Expected the output of `npx convex function-spec`: an object with '
      'a "functions" list.',
    );
  }
  final specs = <FunctionSpec>[];
  for (final function in functions) {
    if (function is! Map<String, Object?>) continue;
    final functionType = FunctionType.values
        .where((t) => t.specName == function['functionType'])
        .firstOrNull;
    if (functionType == null) continue; // HttpAction
    final visibility = function['visibility'];
    if (visibility is Map<String, Object?> && visibility['kind'] != 'public') {
      continue;
    }
    final identifier = function['identifier']! as String;
    final separator = identifier.lastIndexOf(':');
    final modulePath = _stripExtension(
      separator == -1 ? identifier : identifier.substring(0, separator),
    );
    final exportName = separator == -1
        ? 'default'
        : identifier.substring(separator + 1);
    specs.add(
      FunctionSpec(
        modulePath: modulePath,
        exportName: exportName,
        functionType: functionType,
        args: _validator(function['args'], identifier, onWarning),
        returns: _validator(function['returns'], identifier, onWarning),
      ),
    );
  }
  specs.sort((a, b) => a.name.compareTo(b.name));
  return specs;
}

String _stripExtension(String modulePath) {
  final path = modulePath.replaceAll(r'\', '/');
  final lastSlash = path.lastIndexOf('/');
  final lastDot = path.lastIndexOf('.');
  return lastDot > lastSlash ? path.substring(0, lastDot) : path;
}

// Validators may arrive as JSON strings; `null` means none was declared.
ValidatorJson _validator(
  Object? json,
  String identifier,
  void Function(String message)? onWarning,
) {
  final decoded = json is String ? jsonDecode(json) : json;
  if (decoded == null) return const AnyValidator();
  return ValidatorJson.fromJson(
    decoded,
    onWarning: (message) => onWarning?.call('$identifier: $message'),
  );
}
