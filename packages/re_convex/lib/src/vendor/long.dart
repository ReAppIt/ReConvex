// Replaces convex/src/vendor/long.ts (a Long.js subset) with a Dart int.

/// An unsigned 64-bit integer, kept in the 64 bits of a Dart [int].
final class Long {
  const Long._(this._bits);

  /// Reads 8 little-endian bytes.
  factory Long.fromBytesLE(List<int> bytes) {
    var bits = 0;
    for (var i = 7; i >= 0; i--) {
      bits = (bits << 8) | (bytes[i] & 0xff);
    }
    return Long._(bits);
  }

  /// Clamps [value] to the unsigned 64-bit range, as Long.js does.
  factory Long.fromNumber(num value) {
    if (value.isNaN || value < 0) return _zero;
    if (value is int) return Long._(value);
    if (value >= 18446744073709551616.0) return _maxUnsignedValue;
    return Long._(BigInt.from(value).toSigned(64).toInt());
  }

  static const Long _zero = Long._(0);
  static const Long _maxUnsignedValue = Long._(-1);
  static const int _signBit = 1 << 63;

  final int _bits;

  /// The 8 little-endian bytes of this value.
  List<int> toBytesLE() => [
    for (var i = 0; i < 8; i++) (_bits >> (8 * i)) & 0xff,
  ];

  /// Whether both values are equal.
  bool equals(Long other) => _bits == other._bits;

  /// Whether the values differ.
  bool notEquals(Long other) => !equals(other);

  /// Compares as unsigned: -1, 0 or 1.
  int comp(Long other) {
    if (equals(other)) return 0;
    return (other._bits ^ _signBit) > (_bits ^ _signBit) ? -1 : 1;
  }

  /// Whether this value is at most [other].
  bool lessThanOrEqual(Long other) => comp(other) <= 0;

  @override
  bool operator ==(Object other) => other is Long && equals(other);

  @override
  int get hashCode => _bits.hashCode;

  @override
  String toString() => BigInt.from(_bits).toUnsigned(64).toString();
}
