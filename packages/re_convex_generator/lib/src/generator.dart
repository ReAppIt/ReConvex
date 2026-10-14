import 'dart:io';

import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'package:re_convex_generator/src/emit.dart';
import 'package:re_convex_generator/src/function_spec.dart';
import 'package:source_gen/source_gen.dart';

/// Emits the typed `api` for a library whose `library;` directive carries
/// re_convex's `@ConvexApi`; every other library yields nothing.
final class ConvexApiGenerator extends Generator {
  /// Creates the generator.
  const ConvexApiGenerator();

  static const _checker = TypeChecker.typeNamedLiterally(
    'ConvexApi',
    inPackage: 're_convex',
  );

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final annotation = _checker.firstAnnotationOf(library.element);
    if (annotation == null) return null;
    final reader = ConstantReader(annotation);
    final functionSpecPath = reader.read('functionSpec').stringValue;
    final apiName = reader.read('name').stringValue;

    final source = await _read(buildStep, functionSpecPath, library);
    try {
      final functions = parseFunctionSpec(
        source,
        onWarning: (message) => log.warning('$functionSpecPath: $message'),
      );
      return emitApi(
        functions: functions,
        apiName: apiName,
        functionSpecPath: functionSpecPath,
      );
    } on FormatException catch (error) {
      throw InvalidGenerationSourceError(
        '$functionSpecPath: ${error.message}',
        element: library.element,
      );
    }
  }

  // Unlisted under `sources`, a file outside lib/ is read untracked.
  Future<String> _read(
    BuildStep buildStep,
    String path,
    LibraryReader library,
  ) async {
    final id = AssetId(buildStep.inputId.package, path);
    if (await buildStep.canRead(id)) return buildStep.readAsString(id);
    final file = File(p.join(Directory.current.path, path));
    if (file.existsSync()) {
      log.warning(
        '$path is not a build asset, so editing it will not rebuild the api; '
        'list it under `sources` in build.yaml.',
      );
      return file.readAsString();
    }
    throw InvalidGenerationSourceError(
      '$path is missing (run `npx convex function-spec > $path` and list it '
      'under `sources` in build.yaml)',
      element: library.element,
    );
  }
}
