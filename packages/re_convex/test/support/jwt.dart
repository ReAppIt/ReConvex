import 'dart:convert';

String _part(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

/// An unsigned-looking JWT with [payload]; the client never verifies the
/// signature (`jwt-encode` upstream).
String jwtEncode(Map<String, Object?> payload) =>
    '${_part({'alg': 'HS256', 'typ': 'JWT'})}.${_part(payload)}.c2lnbmF0dXJl';
