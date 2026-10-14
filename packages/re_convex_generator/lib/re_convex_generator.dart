/// The build_runner builder that generates a typed Convex `api` from the
/// JSON printed by `npx convex function-spec`.
library;

import 'package:build/build.dart';
import 'package:re_convex_generator/src/generator.dart';
import 'package:source_gen/source_gen.dart';

/// The builder factory named in build.yaml.
Builder convexApiBuilder(BuilderOptions options) =>
    SharedPartBuilder([const ConvexApiGenerator()], 're_convex');
