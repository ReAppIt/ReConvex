// Ported from convex/src/server/authentication.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// The identity an admin impersonates (`UserIdentity` without
/// `tokenIdentifier`).
typedef UserIdentityAttributes = Map<String, Value>;
