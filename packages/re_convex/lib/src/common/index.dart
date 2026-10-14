// Ported from convex/src/common/index.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// Validates that the arguments to a Convex function are an object, defaulting
/// `null` to `{}`.
Map<String, Value> parseArgs(Object? args) {
  if (args == null) {
    return <String, Value>{};
  }
  if (!isSimpleObject(args)) {
    throw ArgumentError(
      'The arguments to a Convex function must be an object. Received: $args',
    );
  }
  return args is Map<String, Value>
      ? args
      : (args as Map<Object?, Object?>).cast<String, Value>();
}

/// Throws an [ArgumentError] unless [deploymentUrl] looks like a Convex
/// deployment URL.
void validateDeploymentUrl(String deploymentUrl) {
  if (!(deploymentUrl.startsWith('http:') ||
      deploymentUrl.startsWith('https:'))) {
    throw ArgumentError(
      'Invalid deployment address: Must start with "https://" or "http://". '
      'Found "$deploymentUrl".',
    );
  }

  // Most clients use ".convex.cloud", but localhost and custom domains work.
  final url = Uri.tryParse(deploymentUrl);
  if (url == null || url.host.isEmpty) {
    throw ArgumentError(
      'Invalid deployment address: "$deploymentUrl" is not a valid URL. If you '
      'believe this URL is correct, use the `skipConvexDeploymentUrlCheck` '
      'option to bypass this.',
    );
  }

  // If a user uses .convex.site, this is very likely incorrect.
  if (deploymentUrl.endsWith('.convex.site')) {
    throw ArgumentError(
      'Invalid deployment address: "$deploymentUrl" ends with .convex.site, '
      'which is used for HTTP Actions. Convex deployment URLs typically end '
      'with .convex.cloud? If you believe this URL is correct, use the '
      '`skipConvexDeploymentUrlCheck` option to bypass this.',
    );
  }
}

/// Whether [value] is a plain object: a map whose keys are all strings.
///
/// An untyped `{}` literal is a `Map<dynamic, dynamic>`, so key types are
/// checked rather than the map type.
bool isSimpleObject(Object? value) =>
    value is Map<String, Object?> ||
    (value is Map<Object?, Object?> && value.keys.every((k) => k is String));
