import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/values.dart';

void main() {
  group('Base64', () {
    test('round-trips bytes', () {
      final bytes = Uint8List.fromList([0, 1, 2, 250, 251, 252, 253, 254, 255]);
      final encoded = Base64.fromByteArray(bytes);
      expect(Base64.toByteArray(encoded), bytes);
      expect(Base64.byteLength(encoded), bytes.length);
    });

    test('decodes the URL-safe alphabet', () {
      expect(Base64.toByteArray('-_8='), Base64.toByteArray('+/8='));
    });

    test('requires a length that is a multiple of 4', () {
      expect(() => Base64.toByteArray('AQI'), throwsFormatException);
    });

    test('encodes URL-safe without padding', () {
      expect(
        Base64.fromByteArrayUrlSafeNoPadding(Uint8List.fromList([251, 255])),
        '-_8',
      );
    });
  });
}
