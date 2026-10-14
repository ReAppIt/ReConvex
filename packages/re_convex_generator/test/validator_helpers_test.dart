import 'package:re_convex_generator/src/validator_helpers.dart';
import 'package:re_convex_generator/src/validator_json.dart';
import 'package:test/test.dart';

ValidatorJson _v(Map<String, Object?> json) => ValidatorJson.fromJson(json);

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
  });
}
