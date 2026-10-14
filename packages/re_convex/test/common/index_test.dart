import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/common/index.dart';

Matcher _throwsInvalid() => throwsA(
  isA<ArgumentError>().having(
    (e) => e.message as String,
    'message',
    contains('Invalid deployment address'),
  ),
);

void main() {
  group('validateDeploymentUrl', () {
    test('localhost is valid', () {
      validateDeploymentUrl('http://127.0.0.1:8000');
      validateDeploymentUrl('http://localhost:8000');
      validateDeploymentUrl('http://0.0.0.0:8000');
    });

    test('real URLs are valid', () {
      validateDeploymentUrl('https://small-mouse-123.convex.cloud');
    });

    test('vanity domain works', () {
      validateDeploymentUrl('https://tshirts.com');
    });

    test('wrong protocol throws', () {
      expect(
        () => validateDeploymentUrl('ws://small-mouse-123.convex.cloud'),
        _throwsInvalid(),
      );
    });

    test('invalid url throws', () {
      expect(
        () => validateDeploymentUrl('https://:small-mouse-123:'),
        _throwsInvalid(),
      );
    });

    test('.convex.site domain throws', () {
      expect(
        () => validateDeploymentUrl('https://small-mouse-123.convex.site'),
        _throwsInvalid(),
      );
    });
  });

  group('parseArgs', () {
    test('defaults null to an empty object', () {
      expect(parseArgs(null), isEmpty);
    });

    test('accepts untyped maps with string keys', () {
      expect(parseArgs(<dynamic, dynamic>{}), isEmpty);
      expect(parseArgs(<dynamic, dynamic>{'a': 1.0}), {'a': 1.0});
      expect(() => parseArgs(<dynamic, dynamic>{1: 1.0}), throwsArgumentError);
    });

    test('rejects non-objects', () {
      expect(() => parseArgs(<Object?>[1]), throwsArgumentError);
    });
  });
}
