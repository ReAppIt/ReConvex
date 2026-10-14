// Ported from convex/src/server/registration.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// The arguments of a function that takes none: pass `const {}`.
typedef EmptyObject = Map<String, Value>;

/// The arguments of a function without an argument validator.
typedef DefaultFunctionArgs = Map<String, Value>;
