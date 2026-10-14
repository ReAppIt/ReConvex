import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/vendor/long.dart';

void main() {
  group('Long', () {
    test('round-trips little-endian bytes', () {
      final bytes = [1, 2, 3, 4, 5, 6, 7, 0xff];
      expect(Long.fromBytesLE(bytes).toBytesLE(), bytes);
    });

    test('compares as unsigned', () {
      final small = Long.fromNumber(5);
      final huge = Long.fromBytesLE([0, 0, 0, 0, 0, 0, 0, 0x80]);
      expect(small.comp(huge), -1);
      expect(huge.comp(small), 1);
      expect(small.lessThanOrEqual(small), isTrue);
      expect(huge.toString(), '9223372036854775808');
    });

    test('clamps numbers like Long.js', () {
      expect(Long.fromNumber(-1), Long.fromNumber(0));
      expect(Long.fromNumber(double.nan), Long.fromNumber(0));
      expect(Long.fromNumber(1e30).toString(), '18446744073709551615');
    });
  });
}
