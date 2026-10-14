// Ported from convex/src/values/size.ts (Apache-2.0); modified for Dart.
import 'dart:typed_data';

import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/values/value.dart';

/// The size in bytes of a Convex value, as Convex counts it for bandwidth and
/// document size limits.
int getConvexSize(Value value) {
  if (value == null || value is bool) {
    return 1;
  }
  if (value is int || value is double || value is CommitTsPlaceholder) {
    // 1 byte type marker + 8 bytes value
    return 9;
  }
  if (value is String) {
    // 1 byte type marker + UTF-8 bytes + 1 byte null terminator
    return 2 + _getUtf8ByteLength(value);
  }
  if (value is Uint8List) {
    // 1 byte type marker + byte array length + 1 byte terminator
    return 2 + value.lengthInBytes;
  }
  if (value is List<Object?>) {
    var size = 2; // marker + terminator
    for (final element in value) {
      size += getConvexSize(element);
    }
    return size;
  }
  if (isSimpleObject(value)) {
    var size = 2; // marker + terminator
    for (final MapEntry(:key, value: val) in parseArgs(value).entries) {
      // field name length + null terminator + value size
      size += _getUtf8ByteLength(key) + 1 + getConvexSize(val);
    }
    return size;
  }
  throw ArgumentError('Unsupported value type: ${Error.safeToString(value)}');
}

int _getUtf8ByteLength(String str) {
  var bytes = 0;
  for (var i = 0; i < str.length; i++) {
    final code = str.codeUnitAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      // A high surrogate starts a 4-byte code point.
      bytes += 4;
      i++; // Skip the low surrogate
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// The estimated size of a missing `_id` field: its name plus a 32-char id.
const int systemFieldIdEstimate = 38;

/// The size of a `_creationTime` field: its name (14) plus a float64 (9).
const int systemFieldCreationTimeSize = 23;

/// The size of a document, adding the system fields when they are missing.
///
/// [customIdLength] replaces the estimated length of a missing `_id`.
int getDocumentSize(Map<String, Value> value, {int? customIdLength}) {
  final baseSize = getConvexSize(value);

  final hasId = value.containsKey('_id');
  final hasCreationTime = value.containsKey('_creationTime');

  if (hasId && hasCreationTime) {
    return baseSize;
  }

  var additionalSize = 0;
  if (!hasId) {
    if (customIdLength != null && customIdLength != 0) {
      // 4 bytes for _id field name + 2 bytes for string overhead.
      additionalSize += customIdLength + 6;
    } else {
      additionalSize += systemFieldIdEstimate;
    }
  }
  if (!hasCreationTime) {
    additionalSize += systemFieldCreationTimeSize;
  }
  return baseSize + additionalSize;
}
