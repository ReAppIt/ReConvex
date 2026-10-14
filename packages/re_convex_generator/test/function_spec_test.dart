import 'package:re_convex_generator/src/function_spec.dart';
import 'package:re_convex_generator/src/validator_json.dart';
import 'package:test/test.dart';

void main() {
  group('parseFunctionSpec', () {
    test('keeps public functions and strips module extensions', () {
      final specs = parseFunctionSpec('''
{"url": "https://x.convex.cloud", "functions": [
  {"args": {"type": "object", "value": {}}, "functionType": "Query",
   "identifier": "dir/mod.js:fn", "returns": {"type": "string"},
   "visibility": {"kind": "public"}},
  {"args": "{\\"type\\": \\"any\\"}", "functionType": "Action",
   "identifier": "mod.ts:default", "returns": null,
   "visibility": {"kind": "public"}},
  {"args": {"type": "any"}, "functionType": "Mutation",
   "identifier": "mod.js:hidden", "returns": null,
   "visibility": {"kind": "internal"}},
  {"functionType": "HttpAction", "method": "GET", "path": "/x"}
]}''');
      expect([for (final s in specs) s.name], ['dir/mod:fn', 'mod']);
      expect(specs[0].functionType, FunctionType.query);
      expect(specs[0].returns, isA<StringValidator>());
      // A validator sent as a JSON string, and a missing one, are both read.
      expect(specs[1].args, isA<AnyValidator>());
      expect(specs[1].returns, isA<AnyValidator>());
    });

    test('warns about unknown validator kinds', () {
      final warnings = <String>[];
      final specs = parseFunctionSpec(
        '{"functions": [{"args": {"type": "map"}, "functionType": "Query", '
        '"identifier": "a.js:b", "returns": null, '
        '"visibility": {"kind": "public"}}]}',
        onWarning: warnings.add,
      );
      expect(specs.single.args, isA<AnyValidator>());
      expect(warnings.single, contains('a.js:b'));
    });

    test('reads bigint and special float literals', () {
      final validator = ValidatorJson.fromJson({
        'type': 'union',
        'value': [
          {
            'type': 'literal',
            'value': {r'$integer': 'AgAAAAAAAAA='},
          },
          {'type': 'literal', 'value': 1},
        ],
      });
      final members = (validator as UnionValidator).members;
      expect((members[0] as LiteralValidator).value, 2);
      expect((members[1] as LiteralValidator).value, 1.0);
    });
  });
}
