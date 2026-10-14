import 'package:re_convex_generator/src/api.dart';
import 'package:re_convex_generator/src/common.dart';
import 'package:re_convex_generator/src/function_spec.dart';

/// The generated part for [functions], read from [functionSpecPath]; the
/// top-level constant is named [apiName].
String emitApi({
  required List<FunctionSpec> functions,
  required String apiName,
  required String functionSpecPath,
}) => '${header(functionSpecPath)}\n${apiCodegen(functions, apiName)}\n';
