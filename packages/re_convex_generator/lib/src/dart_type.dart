/// A Dart type for a Convex validator, and how to read it from a raw value.
///
/// Types keep the raw value's shape, so writing one back is the identity.
sealed class DartType {
  const DartType();

  /// The type as written, like `List<MessagesDoc>?`.
  String get code;

  /// Whether `raw as T` turns a raw Convex value into this type.
  bool get castable;

  /// Whether `null` is a value of this type.
  bool get isNullable;

  /// An expression that turns the raw `Object?` expression [raw] into this
  /// type; [depth] keeps loop variables of nested collections apart.
  String decode(String raw, [int depth = 0]);

  /// This type, accepting `null`.
  DartType get asNullable => isNullable ? this : NullableType(this);
}

/// A type that a cast reads: primitives and the generated extension types.
final class NamedType extends DartType {
  /// Creates the type.
  const NamedType(this.name);

  /// The type name, like `String` or `MessagesDoc`.
  final String name;

  @override
  String get code => name;

  @override
  bool get castable => true;

  @override
  bool get isNullable => name == 'Object?' || name == 'Null';

  @override
  String decode(String raw, [int depth = 0]) =>
      name == 'Object?' ? raw : '$raw as $name';
}

/// [inner], accepting `null`.
final class NullableType extends DartType {
  /// Creates the type.
  const NullableType(this.inner);

  /// The non-nullable type.
  final DartType inner;

  @override
  String get code => '${inner.code}?';

  @override
  bool get castable => inner.castable;

  @override
  bool get isNullable => true;

  @override
  String decode(String raw, [int depth = 0]) => castable
      ? '$raw as $code'
      : '($raw == null ? null : ${inner.decode(raw, depth)})';
}

/// A list of [element]s.
final class ListType extends DartType {
  /// Creates the type.
  const ListType(this.element);

  /// The element type.
  final DartType element;

  @override
  String get code => 'List<${element.code}>';

  @override
  bool get castable => false;

  @override
  bool get isNullable => false;

  @override
  String decode(String raw, [int depth = 0]) {
    if (element.castable) {
      return '($raw as List<Object?>).cast<${element.code}>()';
    }
    final e = 'e$depth';
    return '<${element.code}>[for (final $e in $raw as List<Object?>) '
        '${element.decode(e, depth + 1)}]';
  }
}

/// A map from [key]s to [value]s.
final class MapType extends DartType {
  /// Creates the type.
  const MapType(this.key, this.value);

  /// The key type: `String` or an id type.
  final DartType key;

  /// The value type.
  final DartType value;

  @override
  String get code => 'Map<${key.code}, ${value.code}>';

  @override
  bool get castable => false;

  @override
  bool get isNullable => false;

  @override
  String decode(String raw, [int depth = 0]) {
    if (value.castable) {
      return '($raw as Map<String, Object?>).cast<${key.code}, ${value.code}>()';
    }
    final k = 'k$depth';
    final v = 'v$depth';
    return '<${key.code}, ${value.code}>{for (final MapEntry(key: $k, value: $v) '
        'in ($raw as Map<String, Object?>).entries) $k as ${key.code}: '
        '${value.decode(v, depth + 1)}}';
  }
}
