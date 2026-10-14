// Ported from convex/src/values/validators.ts (Apache-2.0); modified for Dart.
import 'dart:convert';
import 'dart:typed_data';

/// A validator as Convex serializes it (`ValidatorJSON` upstream).
sealed class ValidatorJson {
  const ValidatorJson();

  /// Parses [json]; `map`, `set` and unknown kinds become [AnyValidator],
  /// reported through [onWarning].
  factory ValidatorJson.fromJson(
    Object? json, {
    void Function(String message)? onWarning,
  }) {
    if (json is! Map<String, Object?>) {
      throw FormatException('Expected a validator object, got $json');
    }
    ValidatorJson child(Object? value) =>
        ValidatorJson.fromJson(value, onWarning: onWarning);
    return switch (json['type']) {
      'null' => const NullValidator(),
      'number' => const NumberValidator(),
      'bigint' => const BigIntValidator(),
      'commitTs' => const CommitTsValidator(),
      'boolean' => const BooleanValidator(),
      'string' => const StringValidator(),
      'bytes' => const BytesValidator(),
      'any' => const AnyValidator(),
      'literal' => LiteralValidator(_literalValue(json['value'])),
      'id' => IdValidator(json['tableName']! as String),
      'array' => ArrayValidator(child(json['value'])),
      'record' => RecordValidator(
        child(json['keys']),
        child((json['values']! as Map<String, Object?>)['fieldType']),
      ),
      'object' => ObjectValidator({
        for (final MapEntry(:key, :value)
            in (json['value']! as Map<String, Object?>).entries)
          key: _field(value! as Map<String, Object?>, child),
      }),
      'union' => UnionValidator([
        for (final member in json['value']! as List<Object?>) child(member),
      ]),
      final type => () {
        onWarning?.call('Unsupported validator type $type; using any.');
        return const AnyValidator();
      }(),
    };
  }

  /// A key identifying the structure of this validator.
  String get key;
}

ObjectFieldType _field(
  Map<String, Object?> json,
  ValidatorJson Function(Object? value) child,
) => ObjectFieldType(
  child(json['fieldType']),
  optional: json['optional'] == true,
);

Object? _literalValue(Object? json) {
  if (json is Map<String, Object?> && json.length == 1) {
    final MapEntry(:key, :value) = json.entries.first;
    final bytes = ByteData.sublistView(base64.decode(value! as String));
    if (key == r'$integer') return bytes.getInt64(0, Endian.little);
    if (key == r'$float') return bytes.getFloat64(0, Endian.little);
  }
  return json is num ? json.toDouble() : json;
}

/// `v.null()`.
final class NullValidator extends ValidatorJson {
  /// Creates the validator.
  const NullValidator();

  @override
  String get key => 'null';
}

/// `v.number()` / `v.float64()`.
final class NumberValidator extends ValidatorJson {
  /// Creates the validator.
  const NumberValidator();

  @override
  String get key => 'number';
}

/// `v.int64()` / `v.bigint()`.
final class BigIntValidator extends ValidatorJson {
  /// Creates the validator.
  const BigIntValidator();

  @override
  String get key => 'bigint';
}

/// `v.commitTs()`.
final class CommitTsValidator extends ValidatorJson {
  /// Creates the validator.
  const CommitTsValidator();

  @override
  String get key => 'commitTs';
}

/// `v.boolean()`.
final class BooleanValidator extends ValidatorJson {
  /// Creates the validator.
  const BooleanValidator();

  @override
  String get key => 'boolean';
}

/// `v.string()`.
final class StringValidator extends ValidatorJson {
  /// Creates the validator.
  const StringValidator();

  @override
  String get key => 'string';
}

/// `v.bytes()`.
final class BytesValidator extends ValidatorJson {
  /// Creates the validator.
  const BytesValidator();

  @override
  String get key => 'bytes';
}

/// `v.any()`.
final class AnyValidator extends ValidatorJson {
  /// Creates the validator.
  const AnyValidator();

  @override
  String get key => 'any';
}

/// `v.literal(value)`; [value] is a `String`, `double`, `int`, `bool` or
/// `null`.
final class LiteralValidator extends ValidatorJson {
  /// Creates the validator.
  const LiteralValidator(this.value);

  /// The literal value.
  final Object? value;

  @override
  String get key =>
      'literal(${value is int ? '${value}n' : jsonEncode(value)})';
}

/// `v.id(tableName)`.
final class IdValidator extends ValidatorJson {
  /// Creates the validator.
  const IdValidator(this.tableName);

  /// The table the id belongs to.
  final String tableName;

  @override
  String get key => 'id(${jsonEncode(tableName)})';
}

/// `v.array(value)`.
final class ArrayValidator extends ValidatorJson {
  /// Creates the validator.
  const ArrayValidator(this.value);

  /// The element validator.
  final ValidatorJson value;

  @override
  String get key => 'array(${value.key})';
}

/// `v.record(keys, values)`.
final class RecordValidator extends ValidatorJson {
  /// Creates the validator.
  const RecordValidator(this.keys, this.values);

  /// The key validator: a string, an id or a union of those.
  final ValidatorJson keys;

  /// The value validator.
  final ValidatorJson values;

  @override
  String get key => 'record(${keys.key},${values.key})';
}

/// A field of an [ObjectValidator].
final class ObjectFieldType {
  /// Creates the field.
  const ObjectFieldType(this.fieldType, {required this.optional});

  /// The field's validator.
  final ValidatorJson fieldType;

  /// Whether the field may be absent (`v.optional`).
  final bool optional;
}

/// `v.object(fields)`; [fields] keep the spec's (alphabetical) order.
final class ObjectValidator extends ValidatorJson {
  /// Creates the validator.
  const ObjectValidator(this.fields);

  /// The fields by name.
  final Map<String, ObjectFieldType> fields;

  @override
  String get key =>
      'object(${[for (final MapEntry(:key, :value) in fields.entries) '${jsonEncode(key)}${value.optional ? '?' : ''}:${value.fieldType.key}'].join(',')})';
}

/// `v.union(...members)`.
final class UnionValidator extends ValidatorJson {
  /// Creates the validator.
  const UnionValidator(this.members);

  /// The member validators.
  final List<ValidatorJson> members;

  @override
  String get key => 'union(${[for (final m in members) m.key].join(',')})';
}
