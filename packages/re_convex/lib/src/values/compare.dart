// Ported from convex/src/values/compare.ts (Apache-2.0); modified for Dart.
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/values/compare_utf8.dart';
import 'package:re_convex/src/values/value.dart';

final class _Undefined {
  const _Undefined();
}

/// Stands for JS `undefined` in [compareValues]: it sorts before every value.
@internal
const Object undefinedValue = _Undefined();

/// Compares two Convex values in the order Convex indexes sort them.
int compareValues(Value k1, Value k2) =>
    _compareAsTuples(_makeComparable(k1), _makeComparable(k2));

int _compareAsTuples((int, Object?) a, (int, Object?) b) {
  if (a.$1 == b.$1) {
    return _compareSameTypeValues(a.$2, b.$2);
  } else if (a.$1 < b.$1) {
    return -1;
  }
  return 1;
}

int _compareSameTypeValues(Object? v1, Object? v2) {
  if (v1 == null || v1 is _Undefined) {
    return 0;
  }
  if (v1 is double) {
    if (v2 is! double) {
      throw ArgumentError('Unexpected type $v2');
    }
    return _compareNumbers(v1, v2);
  }
  if (v1 is String) {
    if (v2 is! String) {
      throw ArgumentError('Unexpected type $v2');
    }
    return compareUTF8(v1, v2);
  }
  if (v1 is int) {
    final other = v2! as int;
    return v1 < other ? -1 : (v1 == other ? 0 : 1);
  }
  if (v1 is bool) {
    final other = v2! as bool;
    return v1 == other ? 0 : (v1 ? 1 : -1);
  }
  if (v1 is! List<(int, Object?)> || v2 is! List<(int, Object?)>) {
    throw ArgumentError('Unexpected type $v1');
  }
  for (var i = 0; i < v1.length && i < v2.length; i++) {
    final cmp = _compareAsTuples(v1[i], v2[i]);
    if (cmp != 0) {
      return cmp;
    }
  }
  if (v1.length < v2.length) {
    return -1;
  }
  if (v1.length > v2.length) {
    return 1;
  }
  return 0;
}

int _bits(double v) => (ByteData(8)..setFloat64(0, v)).getInt64(0);

int _compareNumbers(double v1, double v2) {
  // Handle NaN values
  if (v1.isNaN || v2.isNaN) {
    final v1Bits = _bits(v1);
    final v2Bits = _bits(v2);
    // The sign bit is the most significant bit (bit 63)
    final v1Sign = v1Bits < 0;
    final v2Sign = v2Bits < 0;

    // If one value is NaN and the other isn't, use sign bits first
    if (v1.isNaN != v2.isNaN) {
      if (v1.isNaN) {
        return v1Sign ? -1 : 1;
      }
      return v2Sign ? 1 : -1;
    }

    // If both are NaN, compare their binary representations
    if (v1Sign != v2Sign) {
      return v1Sign ? -1 : 1; // true means negative
    }
    return v1Bits < v2Bits ? -1 : (v1Bits == v2Bits ? 0 : 1);
  }

  final v1NegativeZero = v1 == 0 && v1.isNegative;
  final v2NegativeZero = v2 == 0 && v2.isNegative;
  if (v1 == v2 && v1NegativeZero == v2NegativeZero) {
    return 0;
  }
  if (v1NegativeZero) {
    return v2 == 0 ? -1 : -v2.sign.toInt();
  }
  if (v2NegativeZero) {
    return v1 == 0 ? 1 : v1.sign.toInt();
  }

  // Handle regular number comparison
  return v1 < v2 ? -1 : 1;
}

// Compares like a tuple: the type rank, then the comparable value.
(int, Object?) _makeComparable(Value v) {
  if (v is _Undefined) {
    return (0, v);
  }
  if (v == null) {
    return (1, null);
  }
  if (v is int) {
    return (2, v);
  }
  if (v is CommitTsPlaceholder) {
    return (2, maxInt64);
  }
  if (v is double) {
    return (3, v);
  }
  if (v is bool) {
    return (4, v);
  }
  if (v is String) {
    return (5, v);
  }
  if (v is Uint8List) {
    return (6, [for (final byte in v) _makeComparable(byte.toDouble())]);
  }
  if (v is List<Object?>) {
    return (7, [for (final element in v) _makeComparable(element)]);
  }
  // Otherwise, it's an object.
  final object = parseArgs(v);
  final keys = object.keys.toList()..sort();
  return (
    9,
    [
      for (final k in keys) _makeComparable(<Object?>[k, object[k]]),
    ],
  );
}
