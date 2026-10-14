// Ported from convex/src/values/value.ts (Apache-2.0); modified for Dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/values/base64.dart';

/// A Dart value serializable to JSON: `null`, [bool], [num], [String], or a
/// [List] or string-keyed [Map] of those.
typedef JSONValue = Object?;

/// A Convex value: `null`, [int] (int64), [double] (float64), [bool],
/// [String], [Uint8List] (bytes), [CommitTsPlaceholder], or a [List] or
/// `Map<String, Object?>` of values.
typedef Value = Object?;

/// The types of [Value] that represent numbers: [int] and [double].
typedef NumericValue = num;

/// An identifier for a document in Convex (`Id` / `GenericId`).
///
/// IDs are strings at runtime; generated per-table id types implement this.
extension type const GenericId(String id) implements String {}

/// The largest Convex int64.
const int maxInt64 = 0x7FFFFFFFFFFFFFFF;

/// The placeholder for a transaction's commit timestamp, which is unknown
/// until the mutation commits.
final class CommitTsPlaceholder {
  const CommitTsPlaceholder._();

  @override
  String toString() => '[unresolved commit timestamp]';
}

/// The [CommitTsPlaceholder] singleton.
@internal
const CommitTsPlaceholder commitTsPlaceholder = CommitTsPlaceholder._();

bool _isSpecial(double n) =>
    n.isNaN || n.isInfinite || (n == 0 && n.isNegative);

/// Encodes an int64 as 8 little-endian bytes in base64.
String bigIntToBase64(int value) {
  final bytes = ByteData(8)..setInt64(0, value, Endian.little);
  return Base64.fromByteArray(bytes.buffer.asUint8List());
}

/// Decodes 8 little-endian base64 bytes as an int64.
int base64ToBigInt(String encoded) {
  final integerBytes = Base64.toByteArray(encoded);
  if (integerBytes.lengthInBytes != 8) {
    throw FormatException(
      'Received ${integerBytes.lengthInBytes} bytes, expected 8 for \$integer',
    );
  }
  return ByteData.sublistView(integerBytes).getInt64(0, Endian.little);
}

const int _maxIdentifierLen = 1024;

void _validateObjectField(String k) {
  if (k.length > _maxIdentifierLen) {
    throw ArgumentError(
      'Field name $k exceeds maximum field name length $_maxIdentifierLen.',
    );
  }
  if (k.startsWith(r'$')) {
    throw ArgumentError("Field name $k starts with a '\$', which is reserved.");
  }
  for (var i = 0; i < k.length; i += 1) {
    final charCode = k.codeUnitAt(i);
    // Non-control ASCII characters
    if (charCode < 32 || charCode >= 127) {
      throw ArgumentError(
        "Field name $k has invalid character '${k[i]}': Field names can only "
        'contain non-control ASCII characters',
      );
    }
  }
}

/// Parses a Convex value from its JSON representation.
///
/// Every JSON number becomes a [double]; Int64s arrive as `$integer` and
/// become [int]s, bytes become [Uint8List]s.
Value jsonToConvex(JSONValue value) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is List<Object?>) {
    return <Object?>[for (final element in value) jsonToConvex(element)];
  }
  if (value is! Map<String, Object?>) {
    throw FormatException('Unexpected type of $value');
  }
  if (value.length == 1) {
    final MapEntry(:key, value: field) = value.entries.first;
    switch (key) {
      case r'$bytes':
        if (field is! String) {
          throw FormatException('Malformed \$bytes field on $value');
        }
        return Base64.toByteArray(field);
      case r'$integer':
        if (field is! String) {
          throw FormatException('Malformed \$integer field on $value');
        }
        return base64ToBigInt(field);
      case r'$float':
        if (field is! String) {
          throw FormatException('Malformed \$float field on $value');
        }
        final floatBytes = Base64.toByteArray(field);
        if (floatBytes.lengthInBytes != 8) {
          throw FormatException(
            'Received ${floatBytes.lengthInBytes} bytes, expected 8 for \$float',
          );
        }
        final float = ByteData.sublistView(
          floatBytes,
        ).getFloat64(0, Endian.little);
        if (!_isSpecial(float)) {
          throw FormatException('Float $float should be encoded as a number');
        }
        return float;
      case r'$commitTs':
        if (field != null) {
          throw FormatException('Malformed \$commitTs field on $value');
        }
        return commitTsPlaceholder;
      case r'$set':
        throw const FormatException(
          'Received a Set which is no longer supported as a Convex type.',
        );
      case r'$map':
        throw const FormatException(
          'Received a Map which is no longer supported as a Convex type.',
        );
    }
  }
  final out = <String, Value>{};
  for (final MapEntry(:key, value: field) in value.entries) {
    _validateObjectField(key);
    out[key] = jsonToConvex(field);
  }
  return out;
}

const int _maxValueForErrorLen = 16384;

Object? _toErrorJson(Object? value) => switch (value) {
  null || bool() || String() => value,
  // JSON.stringify can't print bigints; upstream prints them as `123n`.
  int() => '${value}n',
  double() => value.isFinite ? value : null,
  Uint8List() || ByteBuffer() => <String, Object?>{},
  List<Object?>() => [for (final element in value) _toErrorJson(element)],
  Map<Object?, Object?>() => {
    for (final MapEntry(:key, :value) in value.entries)
      '$key': _toErrorJson(value),
  },
  _ => value.toString(),
};

/// Formats [value] as JSON for an error message, truncated to 16 KiB.
String stringifyValueForError(Object? value) {
  final str = jsonEncode(_toErrorJson(value));
  if (str.length > _maxValueForErrorLen) {
    const rest = '[...truncated]';
    var truncateAt = _maxValueForErrorLen - rest.length;
    final codeUnit = str.codeUnitAt(truncateAt - 1);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      // don't split a surrogate pair in half
      truncateAt -= 1;
    }
    return str.substring(0, truncateAt) + rest;
  }
  return str;
}

JSONValue _convexToJsonInternal(
  Value value,
  Value originalValue,
  String context,
) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  if (value is int) {
    return {r'$integer': bigIntToBase64(value)};
  }
  if (value is double) {
    if (_isSpecial(value)) {
      final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
      return {r'$float': Base64.fromByteArray(bytes.buffer.asUint8List())};
    }
    return value;
  }
  if (value is Uint8List) {
    return {r'$bytes': Base64.fromByteArray(value)};
  }
  if (value is ByteBuffer) {
    return {r'$bytes': Base64.fromByteArray(value.asUint8List())};
  }
  if (value is CommitTsPlaceholder) {
    return {r'$commitTs': null};
  }
  if (value is TypedData) {
    throw ArgumentError(
      _errorMessageForUnsupportedType(
        context,
        '${Error.safeToString(value)} ',
        value,
        originalValue,
      ),
    );
  }
  if (value is List<Object?>) {
    return [
      for (var i = 0; i < value.length; i++)
        _convexToJsonInternal(value[i], originalValue, '$context[$i]'),
    ];
  }
  if (value is Set<Object?>) {
    throw ArgumentError(
      _errorMessageForUnsupportedType(
        context,
        'Set',
        value.toList(),
        originalValue,
      ),
    );
  }
  if (!isSimpleObject(value)) {
    throw ArgumentError(
      _errorMessageForUnsupportedType(
        context,
        value is Map ? 'Map' : '${Error.safeToString(value)} ',
        value,
        originalValue,
      ),
    );
  }

  final out = <String, JSONValue>{};
  final entries = parseArgs(value).entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final MapEntry(key: k, value: v) in entries) {
    _validateObjectField(k);
    out[k] = _convexToJsonInternal(v, originalValue, '$context.$k');
  }
  return out;
}

String _errorMessageForUnsupportedType(
  String context,
  String typeName,
  Object? value,
  Object? originalValue,
) {
  if (context.isNotEmpty) {
    return '$typeName${stringifyValueForError(value)} is not a supported '
        'Convex type (present at path $context in original object '
        '${stringifyValueForError(originalValue)}). To learn about Convex\'s '
        'supported types, see https://docs.convex.dev/using/types.';
  }
  return '$typeName${stringifyValueForError(value)} is not a supported '
      'Convex type.';
}

/// Converts a Convex value to its JSON representation; [jsonToConvex]
/// recreates it.
///
/// Dart [int]s become int64s; use [double]s for Convex `number`s.
JSONValue convexToJson(Value value) => _convexToJsonInternal(value, value, '');
