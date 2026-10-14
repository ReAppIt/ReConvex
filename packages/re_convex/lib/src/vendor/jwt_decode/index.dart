// Replaces convex/src/vendor/jwt-decode/index.ts with dart:convert.
import 'dart:convert';

/// A token that [jwtDecode] can't decode.
class InvalidTokenError implements Exception {
  /// Creates the error.
  const InvalidTokenError(this.message);

  /// What is wrong with the token.
  final String message;

  @override
  String toString() => 'InvalidTokenError: $message';
}

/// Decodes the payload of a JWT, or its header when [header] is true.
///
/// Doesn't verify the signature; throws [InvalidTokenError] on malformed input.
Map<String, Object?> jwtDecode(String token, {bool header = false}) {
  final pos = header ? 0 : 1;
  final parts = token.split('.');
  if (parts.length <= pos) {
    throw InvalidTokenError(
      'Invalid token specified: missing part #${pos + 1}',
    );
  }
  final String decoded;
  try {
    decoded = utf8.decode(base64Url.decode(base64Url.normalize(parts[pos])));
  } on FormatException catch (e) {
    throw InvalidTokenError(
      'Invalid token specified: invalid base64 for part #${pos + 1} '
      '(${e.message})',
    );
  }
  final Object? json;
  try {
    json = jsonDecode(decoded);
  } on FormatException catch (e) {
    throw InvalidTokenError(
      'Invalid token specified: invalid json for part #${pos + 1} '
      '(${e.message})',
    );
  }
  if (json is! Map<String, Object?>) {
    throw InvalidTokenError(
      'Invalid token specified: invalid json for part #${pos + 1} '
      '(not an object)',
    );
  }
  return json;
}
