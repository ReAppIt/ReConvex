import 'package:meta/meta_meta.dart';

/// Generates the typed `api` of this library from `npx convex function-spec`.
///
/// [functionSpec] is relative to the package root; list it under `sources`.
@Target({TargetKind.library})
class ConvexApi {
  /// Creates the annotation.
  const ConvexApi(this.functionSpec, {this.name = 'api'});

  /// The path of the function-spec JSON.
  final String functionSpec;

  /// The name of the generated top-level constant.
  final String name;
}
