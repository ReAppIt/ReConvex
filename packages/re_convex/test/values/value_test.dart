import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/values/compare.dart';
import 'package:re_convex/src/values/value.dart';

const int _minInt64 = -0x8000000000000000;

// `double.nan`'s sign bit depends on the platform, so build NaNs from bits.
double _nan({required bool negative}) =>
    (ByteData(8)
          ..setUint64(0, negative ? 0xFFF8000000000000 : 0x7FF8000000000000))
        .getFloat64(0);

Matcher _throwsMessage(Pattern pattern) => throwsA(
  isA<ArgumentError>().having(
    (e) => e.message as String,
    'message',
    pattern is String ? contains(pattern) : matches(pattern),
  ),
);

void main() {
  group('convexToJson', () {
    test('serializes objects', () {
      expect(convexToJson({'property': 'value'}), {'property': 'value'});
    });

    test('serializes objects with BigInt values', () {
      expect(convexToJson({'property': 5151996}), {
        'property': {r'$integer': '/JxOAAAAAAA='},
      });
    });

    test('throws an error on class instances', () {
      expect(
        () => convexToJson(DateTime.utc(1970)),
        _throwsMessage(RegExp('DateTime.*is not a supported Convex type')),
      );
    });

    test('throws an error on class instances inside object', () {
      expect(
        () => convexToJson({'hello': DateTime.utc(1970)}),
        _throwsMessage(
          RegExp(
            r'DateTime.*is not a supported Convex type \(present at path '
            r'\.hello in original object',
          ),
        ),
      );
    });

    // BigInts throw in JSON.stringify, so ensure we can format them in errors.
    test("doesn't crash on bigint error", () {
      expect(
        () => convexToJson({
          'bigint': 123,
          'bad': [<int>{}],
        }),
        _throwsMessage(
          'is not a supported Convex type (present at path .bad[0] in '
          'original object {"bigint":"123n","bad":[',
        ),
      );
    });

    test('sorts object keys', () {
      expect(
        (convexToJson({'b': 1.0, 'a': 2.0})! as Map<String, Object?>).keys,
        ['a', 'b'],
      );
    });

    test('encodes special floats, bytes and the commit timestamp', () {
      expect(convexToJson(_nan(negative: false)), {r'$float': 'AAAAAAAA+H8='});
      expect(convexToJson(-0.0), {r'$float': 'AAAAAAAAAIA='});
      expect(convexToJson(1.5), 1.5);
      expect(convexToJson(Uint8List.fromList([1, 2, 3])), {r'$bytes': 'AQID'});
      expect(convexToJson(commitTsPlaceholder), {r'$commitTs': null});
    });

    test('rejects reserved and non-ASCII field names', () {
      expect(
        () => convexToJson({r'$id': 1.0}),
        _throwsMessage("starts with a '\$', which is reserved."),
      );
      expect(
        () => convexToJson({'héllo': 1.0}),
        _throwsMessage('Field names can only contain non-control ASCII'),
      );
    });
  });

  group('jsonToConvex', () {
    test('deserializes object with BigInt value', () {
      expect(
        jsonToConvex({
          'property': {r'$integer': '/JxOAAAAAAA='},
        }),
        {'property': 5151996},
      );
    });

    test('decodes every JSON number as a double', () {
      final value = jsonToConvex({
        'n': 5,
        'list': <Object?>[1],
      });
      expect((value! as Map<String, Object?>)['n'], isA<double>());
      expect(value, {
        'n': 5.0,
        'list': [1.0],
      });
    });

    test('decodes special floats, bytes and the commit timestamp', () {
      expect(jsonToConvex({r'$float': 'AAAAAAAA+H8='}), isNaN);
      expect(jsonToConvex({r'$bytes': 'AQID'}), Uint8List.fromList([1, 2, 3]));
      expect(jsonToConvex({r'$commitTs': null}), commitTsPlaceholder);
      expect(
        () => jsonToConvex({r'$float': 'AAAAAAAA8D8='}),
        throwsFormatException,
      );
      expect(() => jsonToConvex({r'$set': <Object?>[]}), throwsFormatException);
    });
  });

  group('Our hand-rolled bigint code matches the fast implementation', () {
    test('bigInt to bytes to bigint match', () {
      final random = Random(42);
      final tests = [
        0,
        1,
        -1,
        maxInt64,
        _minInt64,
        for (var i = 0; i < 100; i++)
          (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32),
      ];
      for (final num in tests) {
        expect(base64ToBigInt(bigIntToBase64(num)), num);
      }
    });
  });

  group('compare', () {
    test('NaNs and negative zero', () {
      final positiveNaN = _nan(negative: false);
      final negativeNaN = _nan(negative: true);
      final values = [negativeNaN, -0.0, 0.0, 1.0, positiveNaN];
      const repr = ['-NaN', '-0', '0', '1', '+NaN'];

      for (var i = 0; i < values.length; i++) {
        for (var j = i + 1; j < values.length; j++) {
          expect(
            compareValues(values[i], values[j]),
            -1,
            reason: 'compare ${repr[i]} ${repr[j]}',
          );
          expect(
            compareValues(values[j], values[i]),
            1,
            reason: 'compare ${repr[j]} ${repr[i]}',
          );
        }
      }
    });

    test('orders values by type, then value', () {
      final ordered = <Object?>[
        undefinedValue,
        null,
        -3,
        5,
        1.5,
        false,
        true,
        'a',
        'b',
        Uint8List.fromList([1]),
        <Object?>[1.0],
        <String, Object?>{'a': 1.0},
      ];
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(compareValues(ordered[i], ordered[i + 1]), lessThan(0));
      }
    });
  });

  group('stringifyValueForError', () {
    test('truncates long values without splitting a surrogate pair', () {
      final long = 'a' * 16368 + '😀' * 10;
      final str = stringifyValueForError(long);
      expect(str, endsWith('a[...truncated]'));
      expect(str.length, 16383);
    });
  });
}
