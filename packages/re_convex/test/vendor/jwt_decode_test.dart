import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/vendor/jwt_decode/index.dart';

String _part(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  group('jwtDecode', () {
    final token =
        '${_part({'alg': 'HS256'})}.${_part({'sub': 'ü', 'iat': 1})}.sig';

    test('decodes the payload', () {
      expect(jwtDecode(token), {'sub': 'ü', 'iat': 1});
    });

    test('decodes the header', () {
      expect(jwtDecode(token, header: true), {'alg': 'HS256'});
    });

    test('throws InvalidTokenError on malformed tokens', () {
      expect(() => jwtDecode('abc'), throwsA(isA<InvalidTokenError>()));
      expect(() => jwtDecode('a.!!!.c'), throwsA(isA<InvalidTokenError>()));
    });
  });
}
