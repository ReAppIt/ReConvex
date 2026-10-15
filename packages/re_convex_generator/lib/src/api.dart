// Ported from convex/src/cli/codegen_templates/api.ts (Apache-2.0); modified for Dart.
import 'package:re_convex_generator/src/common.dart';
import 'package:re_convex_generator/src/function_spec.dart';
import 'package:re_convex_generator/src/naming.dart';
import 'package:re_convex_generator/src/validator_helpers.dart';
import 'package:re_convex_generator/src/validator_json.dart';

final class _Node {
  final Map<String, _Node> children = {};
  final Map<String, FunctionSpec> functions = {};
}

/// Builds the `api` object: one private class per module or directory, with
/// a typed `FunctionReference` getter per function.
///
/// Throws a [FormatException] when two members would share a name.
String apiCodegen(List<FunctionSpec> functions, String apiName) {
  final types = TypeMapper()
    ..preferDocumentNames([
      for (final function in functions) ...[function.args, function.returns],
    ]);
  final root = _Node();
  final sorted = [...functions]
    ..sort((a, b) {
      final byPath = compareModulePaths(a.modulePath, b.modulePath);
      return byPath != 0 ? byPath : a.exportName.compareTo(b.exportName);
    });
  for (final function in sorted) {
    var node = root;
    for (final segment in function.modulePath.split('/')) {
      node = node.children[segment] ??= _Node();
    }
    node.functions[function.exportName] = function;
  }

  final classes = <String>[];
  final decoders = <String>[];
  final apiClass = '_\$${pascal(apiName)}';
  final usedClassNames = <String>{};

  String emitNode(_Node node, List<String> path) {
    var className = '$apiClass${path.map(pascal).join()}';
    for (var i = 2; !usedClassNames.add(className); i++) {
      className = '$apiClass${path.map(pascal).join()}$i';
    }
    // Reserve the slot first, so classes appear top-down.
    final classIndex = classes.length;
    classes.add('');
    final members = <String, String>{};
    final buffer = StringBuffer()
      ..writeln('final class $className {')
      ..writeln('  const $className();');

    void addMember(String getter, String description, String code) {
      final existing = members[getter];
      if (existing != null) {
        throw FormatException(
          '$description and $existing are both generated as '
          '`$getter` in `${path.isEmpty ? apiName : path.join('/')}`.',
        );
      }
      members[getter] = description;
      buffer
        ..writeln()
        ..write(code);
    }

    for (final MapEntry(key: segment, value: child) in node.children.entries) {
      final childClass = emitNode(child, [...path, segment]);
      addMember(
        lowerCamel(segment),
        'module `${[...path, segment].join('/')}`',
        '  /// The `${[...path, segment].join('/')}` functions.\n'
            '  $childClass get ${lowerCamel(segment)} => const $childClass();\n',
      );
    }
    for (final function in node.functions.values) {
      final prefix = pascal(
        '${function.modulePath.replaceAll('/', '_')}_${function.exportName}',
      );
      final args = function.args;
      final String argsType;
      if (args is ObjectValidator) {
        argsType = types.declareObject(
          args,
          types.reserveName('${prefix}Args'),
          dedupe: false,
        );
      } else {
        argsType = 'Map<String, Object?>';
      }
      final returns = types.map(
        function.returns,
        '${prefix}Result',
        itemContext: '${prefix}Item',
      );
      final reference =
          'FunctionReference<${function.functionType.marker}, $argsType, '
          '${returns.code}>';
      final String decode;
      if (returns.castable) {
        decode = '';
      } else {
        final decoder = '_\$decode${prefix}Result';
        decoders.add(
          '${returns.code} $decoder(Object? value) => '
          '${returns.decode('value')};',
        );
        decode = ', decode: $decoder';
      }
      addMember(
        lowerCamel(function.exportName),
        '`${function.name}`',
        '  /// `${function.name}` (${function.functionType.name}).\n'
            '  $reference get ${lowerCamel(function.exportName)} =>\n'
            '      const $reference(${stringLiteral(function.name)}$decode);\n',
      );
    }
    buffer.write('}');
    classes[classIndex] = buffer.toString();
    return className;
  }

  final rootClass = emitNode(root, const []);
  return [
    '/// The functions of the Convex deployment, like `$apiName` from\n'
        '/// `convex/_generated/api`.\n'
        'const $apiName = $rootClass();',
    ...classes,
    ...decoders,
    ...types.declarations,
  ].join('\n\n');
}
