import 'package:re_convex_generator/src/validator_helpers.dart';
import 'package:re_convex_generator/src/validator_json.dart';
import 'package:test/test.dart';

ValidatorJson _v(Map<String, Object?> json) => ValidatorJson.fromJson(json);

Map<String, Object?> _object(Map<String, Map<String, Object?>> fields) => {
  'type': 'object',
  'value': {
    for (final MapEntry(:key, :value) in fields.entries)
      key: {'fieldType': value, 'optional': false},
  },
};

Map<String, Object?> _document(
  String table,
  Map<String, Map<String, Object?>> fields,
) => _object({
  '_creationTime': {'type': 'number'},
  '_id': {'type': 'id', 'tableName': table},
  ...fields,
});

Map<String, Object?> _array(Map<String, Object?> value) => {
  'type': 'array',
  'value': value,
};

Map<String, Object?> _union(List<Map<String, Object?>> members) => {
  'type': 'union',
  'value': members,
};

Map<String, Object?> _literals(List<String> values) => _union([
  for (final value in values) {'type': 'literal', 'value': value},
]);

final _macros = _object({
  'kcal': {'type': 'number'},
});

void main() {
  group('TypeMapper', () {
    late TypeMapper types;
    setUp(() => types = TypeMapper());

    String code(Map<String, Object?> json) => types.map(_v(json), 'Ctx').code;

    test('maps primitives', () {
      expect(code({'type': 'number'}), 'double');
      expect(code({'type': 'bigint'}), 'int');
      expect(code({'type': 'bytes'}), 'Uint8List');
      expect(code({'type': 'any'}), 'Object?');
      expect(code({'type': 'literal', 'value': 'x'}), 'String');
    });

    test('maps unions', () {
      expect(
        code({
          'type': 'union',
          'value': [
            {'type': 'string'},
            {'type': 'null'},
          ],
        }),
        'String?',
      );
      expect(
        code({
          'type': 'union',
          'value': [
            {'type': 'string'},
            {'type': 'number'},
          ],
        }),
        'Object',
      );
      expect(
        code({
          'type': 'union',
          'value': [
            {'type': 'id', 'tableName': 'a'},
            {'type': 'string'},
          ],
        }),
        'String',
      );
    });

    test('decodes lists with a cast, and nested lists by mapping', () {
      final list = types.map(
        _v({
          'type': 'array',
          'value': {'type': 'string'},
        }),
        'Ctx',
      );
      expect(list.decode('raw'), '(raw as List<Object?>).cast<String>()');
      final nested = types.map(
        _v({
          'type': 'array',
          'value': {
            'type': 'array',
            'value': {'type': 'string'},
          },
        }),
        'Ctx',
      );
      expect(nested.castable, isFalse);
      expect(nested.decode('raw'), contains('for (final e0 in raw'));
    });

    test('names documents after their table and reuses equal shapes', () {
      final doc = {
        'type': 'object',
        'value': {
          '_creationTime': {
            'fieldType': {'type': 'number'},
            'optional': false,
          },
          '_id': {
            'fieldType': {'type': 'id', 'tableName': 'tasks'},
            'optional': false,
          },
        },
      };
      expect(code(doc), 'TasksDoc');
      expect(types.map(_v(doc), 'Other').code, 'TasksDoc');
    });

    test('names shapes after the document field that holds them', () {
      final status = _literals(['open', 'done']);
      final kind = _literals(['a', 'b']);
      final tag = _union([
        _object({
          'kind': {'type': 'literal', 'value': 'text'},
        }),
        _object({
          'kind': {'type': 'literal', 'value': 'image'},
        }),
      ]);
      types.preferDocumentNames([
        _v(
          _object({
            'log': _union([
              _document('logs', {'macros': _macros}),
              {'type': 'null'},
            ]),
          }),
        ),
        _v(_array(_document('tasks', {'status': status}))),
        _v(
          _object({
            'continueCursor': {'type': 'string'},
            'isDone': {'type': 'boolean'},
            'page': _array(_document('notes', {'kind': kind, 'body': tag})),
          }),
        ),
      ]);
      expect(code(_macros), 'LogsDocMacros');
      expect(code(status), 'TasksDocStatus');
      expect(code(kind), 'NotesDocKind');
      expect(code(tag), 'NotesDocBody');
      expect(
        types.declarations,
        contains(startsWith('extension type NotesDocBodyText.fromValue(')),
      );
    });

    test('prefers the shallowest field, then the first table and path', () {
      final unit = _literals(['g', 'ml']);
      types.preferDocumentNames([
        _v(
          _document('analyses', {
            'items': _array(_object({'macros': _macros, 'unit': unit})),
          }),
        ),
        _v(_document('products', {'macros': _macros})),
        _v(_document('logs', {'macros': _macros, 'unit': unit, 'size': unit})),
      ]);
      expect(code(_macros), 'LogsDocMacros');
      expect(code(unit), 'LogsDocSize');
    });

    test('keeps the context for shapes no document holds', () {
      types.preferDocumentNames([
        _v(_object({'macros': _macros})),
      ]);
      expect(code(_macros), 'Ctx');
    });
  });
}
