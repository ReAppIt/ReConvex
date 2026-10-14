// Replaces convex/src/values/base64.ts (vendored base64-js) with dart:convert.
import 'dart:convert';
import 'dart:typed_data';

/// The base64 helpers Convex exports as `Base64`, over `dart:convert`.
///
/// Decoding accepts the URL-safe alphabet too, as Node.js does.
abstract final class Base64 {
  static (int, int) _getLens(String b64) {
    final len = b64.length;
    if (len % 4 > 0) {
      throw const FormatException(
        'Invalid string. Length must be a multiple of 4',
      );
    }
    var validLen = b64.indexOf('=');
    if (validLen == -1) validLen = len;
    final placeHoldersLen = validLen == len ? 0 : 4 - (validLen % 4);
    return (validLen, placeHoldersLen);
  }

  /// The number of bytes [b64] decodes to.
  static int byteLength(String b64) {
    final (validLen, placeHoldersLen) = _getLens(b64);
    return (validLen + placeHoldersLen) * 3 ~/ 4 - placeHoldersLen;
  }

  /// Decodes [b64], whose length must be a multiple of 4.
  static Uint8List toByteArray(String b64) {
    _getLens(b64);
    return base64.decode(b64.replaceAll('-', '+').replaceAll('_', '/'));
  }

  /// Encodes [uint8] with the standard alphabet and padding.
  static String fromByteArray(Uint8List uint8) => base64.encode(uint8);

  /// Encodes [uint8] with the URL-safe alphabet and no padding.
  static String fromByteArrayUrlSafeNoPadding(Uint8List uint8) =>
      base64Url.encode(uint8).replaceAll('=', '');
}
