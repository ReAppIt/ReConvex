// Ported from convex/src/cli/codegen_templates/validator_helpers.ts (Apache-2.0); modified for Dart.
import 'package:re_convex_generator/src/dart_type.dart';
import 'package:re_convex_generator/src/naming.dart';
import 'package:re_convex_generator/src/validator_json.dart';

/// Type names the generated code can't redeclare.
const Set<String> _takenTypeNames = {
  'Api',
  'FunctionReference',
  'GenericId',
  'List',
  'Map',
  'Null',
  'Object',
  'PaginationOptions',
  'PaginationResult',
  'String',
  'Uint8List',
  'bool',
  'double',
  'int',
};

final class _Field {
  _Field({
    required this.key,
    required this.getter,
    required this.type,
    required this.optional,
    this.literal,
    this.paginationOptions = false,
  });

  final String key;
  final String getter;
  final DartType type;
  final bool optional;
  // The value of a required single-literal field, set by constructors.
  final String? literal;
  // `paginationOpts`: optional in constructors, which paginated clients fill.
  final bool paginationOptions;
}

/// Maps validators to Dart types, collecting the declarations they need.
///
/// Objects become extension types over the raw map, string-literal unions
/// tolerant extension types over `String`, ids per-table id types.
class TypeMapper {
  /// The generated declarations, in creation order.
  final List<String> declarations = [];

  final Set<String> _usedNames = {..._takenTypeNames};
  final Map<String, String> _objectNamesByKey = {};
  final Map<String, String> _literalNamesByKey = {};
  final Map<String, String> _unionNamesByKey = {};
  final Map<String, String> _idNamesByTable = {};
  final Map<String, String> _preferredNames = {};

  /// Names each object and union that a document in [validators] holds after
  /// the shallowest document field holding it, like `TasksDocStatus`, for
  /// whichever function declares it first; call before [map].
  void preferDocumentNames(Iterable<ValidatorJson> validators) {
    final best = <String, ({int depth, String table, String name})>{};
    void offer(String key, String? table, String name, int depth) {
      if (table == null) return;
      final current = best[key];
      if (current == null ||
          depth < current.depth ||
          depth == current.depth &&
              (table.compareTo(current.table) < 0 ||
                  table == current.table && name.compareTo(current.name) < 0)) {
        best[key] = (depth: depth, table: table, name: name);
      }
    }

    // [table] is the enclosing document's; null outside one.
    void walk(ValidatorJson validator, String? table, String name, int depth) {
      switch (validator) {
        case ArrayValidator(:final value):
          walk(value, table, '${name}Item', depth + 1);
        case RecordValidator(:final values):
          walk(values, table, '${name}Value', depth + 1);
        case final ObjectValidator object:
          if (_paginationItem(object) case final item?) {
            walk(item, table, '${name}Item', depth + 1);
            return;
          }
          final document = _documentTable(object);
          if (document == null) offer(object.key, table, name, depth);
          final (fieldTable, base, baseDepth) = document == null
              ? (table, name, depth)
              : (document, '${pascal(document)}Doc', 0);
          for (final MapEntry(:key, value: field) in object.fields.entries) {
            if (_isPaginationOpts(key, field)) continue;
            walk(
              field.fieldType,
              fieldTable,
              '$base${pascal(key)}',
              baseDepth + 1,
            );
          }
        case UnionValidator(:final members):
          final nonNull = members.where((m) => !_isNull(m)).toList();
          if (nonNull.isEmpty) return;
          if (nonNull.length == 1) {
            walk(nonNull.single, table, name, depth);
          } else if (_stringLiterals(nonNull) case final values?) {
            offer(_literalKey(values), table, name, depth);
          } else if (_discriminatedVariants(nonNull) case final union?) {
            offer(UnionValidator(nonNull).key, table, name, depth);
            for (final MapEntry(key: tag, value: variant)
                in union.variants.entries) {
              walk(variant, table, '$name${pascal(tag)}', depth + 1);
            }
          } else {
            // Other unions declare no types, but a member may be a document.
            for (final member in nonNull) {
              walk(member, null, name, depth);
            }
          }
        default:
          return;
      }
    }

    for (final validator in validators) {
      walk(validator, null, '', 0);
    }
    _preferredNames.addAll({
      for (final MapEntry(:key, :value) in best.entries) key: value.name,
    });
  }

  /// Reserves a unique type name based on [candidate].
  String reserveName(String candidate) {
    var name = candidate;
    for (var i = 2; _usedNames.contains(name); i++) {
      name = '$candidate$i';
    }
    _usedNames.add(name);
    return name;
  }

  /// The Dart type of [validator]; [context] names any type it declares.
  ///
  /// [itemContext] names the elements of a top-level array.
  DartType map(
    ValidatorJson validator,
    String context, {
    String? itemContext,
  }) => switch (validator) {
    NullValidator() => const NamedType('Null'),
    NumberValidator() => const NamedType('double'),
    // Clients only see committed values, which are int64s.
    BigIntValidator() || CommitTsValidator() => const NamedType('int'),
    BooleanValidator() => const NamedType('bool'),
    StringValidator() => const NamedType('String'),
    BytesValidator() => const NamedType('Uint8List'),
    AnyValidator() => const NamedType('Object?'),
    LiteralValidator(:final value) => _literalType(value),
    IdValidator(:final tableName) => NamedType(idType(tableName)),
    ArrayValidator(:final value) => ListType(
      map(value, itemContext ?? '${context}Item'),
    ),
    RecordValidator(:final keys, :final values) => MapType(
      _recordKeyType(keys),
      map(values, '${context}Value'),
    ),
    final ObjectValidator object => _objectType(object, context),
    final UnionValidator union => _unionType(union, context),
  };

  static DartType _literalType(Object? value) => switch (value) {
    String() => const NamedType('String'),
    int() => const NamedType('int'),
    double() => const NamedType('double'),
    bool() => const NamedType('bool'),
    _ => const NamedType('Null'),
  };

  DartType _recordKeyType(ValidatorJson keys) => switch (keys) {
    IdValidator(:final tableName) => NamedType(idType(tableName)),
    _ => const NamedType('String'),
  };

  /// The name of the id type of [tableName], declaring it once.
  String idType(String tableName) {
    final existing = _idNamesByTable[tableName];
    if (existing != null) return existing;
    final name = reserveName('${pascal(tableName)}Id');
    _idNamesByTable[tableName] = name;
    declarations.add(
      '/// An id in the `$tableName` table.\n'
      'extension type const $name(String id) implements GenericId {}',
    );
    return name;
  }

  DartType _objectType(ObjectValidator object, String context) {
    final pagination = _paginationItem(object);
    if (pagination != null) {
      final item = map(pagination, '${context}Item');
      return NamedType('PaginationResult<${item.code}>');
    }
    final existing = _objectNamesByKey[object.key];
    if (existing != null) return NamedType(existing);
    final document = _documentTable(object);
    final candidate = document != null
        ? '${pascal(document)}Doc'
        : _preferredNames[object.key] ?? context;
    return NamedType(declareObject(object, reserveName(candidate)));
  }

  // The table of a document: an object with an `_id` and a `_creationTime`.
  static String? _documentTable(ObjectValidator object) {
    final id = object.fields['_id']?.fieldType;
    return id is IdValidator && object.fields.containsKey('_creationTime')
        ? id.tableName
        : null;
  }

  // The item validator when [object] is a `paginationResultValidator` shape.
  static ValidatorJson? _paginationItem(ObjectValidator object) {
    final fields = object.fields;
    final page = fields['page'];
    if (page == null ||
        page.optional ||
        page.fieldType is! ArrayValidator ||
        fields['isDone']?.fieldType is! BooleanValidator ||
        fields['continueCursor']?.fieldType is! StringValidator) {
      return null;
    }
    const known = {
      'page',
      'isDone',
      'continueCursor',
      'splitCursor',
      'pageStatus',
    };
    if (!fields.keys.every(known.contains)) return null;
    return (page.fieldType as ArrayValidator).value;
  }

  static bool _isPaginationOpts(String key, ObjectFieldType field) {
    final type = field.fieldType;
    return key == 'paginationOpts' &&
        type is ObjectValidator &&
        type.fields.containsKey('numItems') &&
        type.fields.containsKey('cursor');
  }

  /// Declares [object] as the extension type [name]; returns [name].
  ///
  /// [implementsName] is the discriminated union it is a variant of.
  String declareObject(
    ObjectValidator object,
    String name, {
    String? implementsName,
    bool dedupe = true,
  }) {
    if (dedupe) _objectNamesByKey[object.key] = name;
    final fields = <_Field>[];
    final getters = <String>{};
    for (final MapEntry(:key, value: field) in object.fields.entries) {
      var getter = fieldName(key);
      while (!getters.add(getter)) {
        getter = '\$$getter';
      }
      final type = _isPaginationOpts(key, field)
          ? const NamedType('PaginationOptions')
          : map(field.fieldType, '$name${pascal(key)}');
      final fieldType = field.fieldType;
      fields.add(
        _Field(
          key: key,
          getter: getter,
          type: type,
          optional: field.optional,
          literal:
              !field.optional &&
                  fieldType is LiteralValidator &&
                  fieldType.value is String
              ? stringLiteral(fieldType.value! as String)
              : null,
          paginationOptions: _isPaginationOpts(key, field),
        ),
      );
    }
    declarations.add(_emitObject(name, fields, implementsName));
    return name;
  }

  static String _emitObject(
    String name,
    List<_Field> fields,
    String? implementsName,
  ) {
    final buffer = StringBuffer()
      ..write('extension type $name.fromValue(Map<String, Object?> json)')
      ..writeln(
        implementsName == null ? ' {' : ' implements $implementsName {',
      );

    final params = <String>[];
    final entries = <String>[];
    for (final field in fields) {
      final key = stringLiteral(field.key);
      final literal = field.literal;
      if (literal != null) {
        entries.add('$key: $literal');
      } else if (field.paginationOptions) {
        params.add('PaginationOptions? ${field.getter}');
        entries.add('if (${field.getter} != null) $key: ${field.getter}');
      } else if (field.optional && field.type.isNullable) {
        // Absent and null differ: `(value: null)` sends null.
        params.add('({${field.type.code} value})? ${field.getter}');
        entries.add('if (${field.getter} != null) $key: ${field.getter}.value');
      } else if (field.optional) {
        params.add('${field.type.code}? ${field.getter}');
        entries.add('if (${field.getter} != null) $key: ${field.getter}');
      } else {
        params.add('required ${field.type.code} ${field.getter}');
        entries.add('$key: ${field.getter}');
      }
    }
    if (params.isEmpty) {
      buffer.writeln(
        '  const $name() : json = const <String, Object?>{${entries.join(', ')}};',
      );
    } else {
      buffer.writeln(
        '  $name({${params.join(', ')}}) : '
        'json = <String, Object?>{${entries.join(', ')}};',
      );
    }

    for (final field in fields) {
      final raw = 'json[${stringLiteral(field.key)}]';
      buffer.writeln();
      if (field.optional && field.type.isNullable) {
        buffer.writeln(
          '  ({${field.type.code} value})? get ${field.getter} => '
          'json.containsKey(${stringLiteral(field.key)}) '
          '? (value: ${field.type.asNullable.decode(raw)}) : null;',
        );
      } else if (field.optional || field.paginationOptions) {
        final type = field.type.asNullable;
        buffer.writeln(
          '  ${type.code} get ${field.getter} => ${type.decode(raw)};',
        );
      } else {
        buffer.writeln(
          '  ${field.type.code} get ${field.getter} => '
          '${field.type.decode(raw)};',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('  /// Any field of the raw object.')
      ..writeln('  Object? operator [](String key) => json[key];')
      ..write('}');
    return buffer.toString();
  }

  static bool _isNull(ValidatorJson v) =>
      v is NullValidator || (v is LiteralValidator && v.value == null);

  // The values of a union of two or more string literals, or null.
  static List<String>? _stringLiterals(List<ValidatorJson> members) =>
      members.length > 1 &&
          members.every((m) => m is LiteralValidator && m.value is String)
      ? [for (final m in members) (m as LiteralValidator).value! as String]
      : null;

  static String _literalKey(List<String> values) =>
      ([...values]..sort()).join('\u0000');

  DartType _unionType(UnionValidator union, String context) {
    final nonNull = union.members.where((m) => !_isNull(m)).toList();
    final hasNull = nonNull.length != union.members.length;
    DartType nullable(DartType type) => hasNull ? type.asNullable : type;

    if (nonNull.isEmpty) return const NamedType('Null');
    if (nonNull.length == 1) return nullable(map(nonNull.single, context));

    if (_stringLiterals(nonNull) case final values?) {
      return nullable(NamedType(_literalUnion(values, context)));
    }

    final variants = _discriminatedVariants(nonNull);
    if (variants != null) {
      final key = UnionValidator(nonNull).key;
      final name = _unionNamesByKey[key] ??= _discriminatedUnion(
        variants,
        _preferredNames[key] ?? context,
      );
      return nullable(NamedType(name));
    }

    final types = {for (final m in nonNull) _simpleType(m)};
    if (types.length == 1 && types.single != null) {
      return nullable(NamedType(types.single!));
    }
    if (types.every((t) => t == 'String' || (t?.endsWith('Id') ?? false))) {
      return nullable(const NamedType('String'));
    }
    return nullable(const NamedType('Object'));
  }

  // The type of a member that declares nothing but ids, or null.
  String? _simpleType(ValidatorJson validator) => switch (validator) {
    NumberValidator() => 'double',
    BigIntValidator() || CommitTsValidator() => 'int',
    BooleanValidator() => 'bool',
    StringValidator() => 'String',
    BytesValidator() => 'Uint8List',
    IdValidator(:final tableName) => idType(tableName),
    LiteralValidator(:final value) => _literalType(value).code,
    _ => null,
  };

  String _literalUnion(List<String> values, String context) {
    final key = _literalKey(values);
    final existing = _literalNamesByKey[key];
    if (existing != null) return existing;
    final name = reserveName(_preferredNames[key] ?? context);
    _literalNamesByKey[key] = name;
    final constants = <String>{};
    final buffer = StringBuffer()
      ..writeln(
        'extension type const $name._(String value) implements String {',
      );
    for (final value in values) {
      var constant = lowerCamel(value);
      if (constant == 'values' || constant == 'value') {
        constant = '${constant}_';
      }
      while (!constants.add(constant)) {
        constant = '\$$constant';
      }
      buffer.writeln(
        '  static const $constant = $name._(${stringLiteral(value)});',
      );
    }
    buffer
      ..writeln()
      ..writeln('  /// The values this version of the API knows.')
      ..writeln('  static const values = <$name>[${constants.join(', ')}];')
      ..write('}');
    declarations.add(buffer.toString());
    return name;
  }

  // Variants by tag, when one string-literal field tells all apart.
  static ({String field, Map<String, ObjectValidator> variants})?
  _discriminatedVariants(List<ValidatorJson> members) {
    if (!members.every((m) => m is ObjectValidator)) return null;
    final objects = members.cast<ObjectValidator>();
    for (final candidate in objects.first.fields.keys) {
      final tags = <String, ObjectValidator>{};
      for (final object in objects) {
        final field = object.fields[candidate];
        final type = field?.fieldType;
        if (field == null ||
            field.optional ||
            type is! LiteralValidator ||
            type.value is! String ||
            tags.containsKey(type.value)) {
          tags.clear();
          break;
        }
        tags[type.value! as String] = object;
      }
      if (tags.length == objects.length) {
        return (field: candidate, variants: tags);
      }
    }
    return null;
  }

  String _discriminatedUnion(
    ({String field, Map<String, ObjectValidator> variants}) union,
    String context,
  ) {
    final name = reserveName(context);
    final field = stringLiteral(union.field);
    final buffer = StringBuffer()
      ..writeln('extension type $name.fromValue(Map<String, Object?> json) {')
      ..writeln('  /// The `${union.field}` that tells the variants apart.')
      ..writeln(
        '  String get ${fieldName(union.field)} => json[$field] as String;',
      );
    final declarationIndex = declarations.length;
    for (final MapEntry(key: tag, value: object) in union.variants.entries) {
      final variant =
          _objectNamesByKey[object.key] ??
          declareObject(
            object,
            reserveName(_preferredNames[object.key] ?? '$name${pascal(tag)}'),
            implementsName: name,
          );
      buffer
        ..writeln()
        ..writeln('  /// This value as a `$tag` variant, or `null`.')
        ..writeln(
          '  $variant? get as${pascal(tag)} => json[$field] == '
          '${stringLiteral(tag)} ? $variant.fromValue(json) : null;',
        );
    }
    buffer
      ..writeln()
      ..writeln('  /// Any field of the raw object.')
      ..writeln('  Object? operator [](String key) => json[key];')
      ..write('}');
    // Declare the union before its variants, which implement it.
    declarations.insert(declarationIndex, buffer.toString());
    return name;
  }
}
