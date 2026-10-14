import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:re_convex_generator/re_convex_generator.dart';
import 'package:test/test.dart';

// Stands in for package:re_convex, which the generator finds by name.
const _reConvexStub = '''
class ConvexApi {
  const ConvexApi(this.functionSpec, {this.name = 'api'});
  final String functionSpec;
  final String name;
}
''';

String _library({
  String annotation = "@ConvexApi('convex/function_spec.json')",
}) =>
    '''
$annotation
library;

import 'package:re_convex/re_convex.dart';

part 'api.g.dart';
''';

Future<TestBuilderResult> _build(
  String spec, {
  String? library,
  bool withSpec = true,
}) => testBuilder(
  convexApiBuilder(BuilderOptions.empty),
  {
    're_convex|lib/re_convex.dart': _reConvexStub,
    if (withSpec) 'a|convex/function_spec.json': spec,
    'a|lib/api.dart': library ?? _library(),
  },
  rootPackage: 'a',
  flattenOutput: true,
);

Future<String> _generate(String spec, {String? library}) async {
  final result = await _build(spec, library: library);
  expect(result.succeeded, isTrue, reason: result.errors.join('\n'));
  return result.readerWriter.testing.readString(
    AssetId('a', 'lib/api.re_convex.g.part'),
  );
}

Future<String> _failure(String spec, {bool withSpec = true}) async {
  final result = await _build(spec, withSpec: withSpec);
  expect(result.succeeded, isFalse);
  return result.errors.join('\n');
}

String _spec(String functions) => '{"url": "u", "functions": [$functions]}';

void main() {
  final fixture = File('test/fixtures/function_spec.json').readAsStringSync();

  group('generator', () {
    test('emits the api object and a typed reference per function', () async {
      final out = await _generate(fixture);
      expect(out, contains('// ignore_for_file: type=lint'));
      expect(out, contains('// generated_from: convex/function_spec.json'));
      expect(out, contains(r'const api = _$Api();'));
      expect(out, contains(r'_$ApiAdminUsers get users'));
      expect(
        out,
        contains(
          'FunctionReference<QueryType, MessagesListArgs, '
          'PaginationResult<MessagesDoc>>',
        ),
      );
      expect(out, contains("'messages:list'"));
      // A default export is named by its module.
      expect(out, contains("('channels', decode: "));
      expect(out, contains(' get default_ =>'));
      // A reserved word gets a suffix; other names stay.
      expect(out, contains(' get new_ =>'));
      expect(out, contains(' get sync =>'));
      // Internal functions and HTTP actions are skipped.
      expect(out, isNot(contains('purge')));
      expect(out, isNot(contains('webhook')));
    });

    test('maps every validator kind', () async {
      final out = await _generate(fixture);
      expect(
        out,
        contains(
          'extension type const MessagesId(String id) implements GenericId {}',
        ),
      );
      expect(
        out,
        contains(
          'extension type const MessagesDocStatus._(String value) '
          'implements String {',
        ),
      );
      expect(out, contains("static const sent = MessagesDocStatus._('sent');"));
      expect(out, contains('Map<String, int>? reactions'));
      expect(out, contains('Uint8List? avatar'));
      expect(out, contains('({String? value})? nickname'));
      expect(out, contains('required MessagesDocContent content'));
      expect(out, contains('implements MessagesDocContent {'));
      expect(out, contains("'kind': 'text'"));
      expect(out, contains('PaginationOptions? paginationOpts'));
      expect(out, contains('const MessagesCountArgs()'));
      expect(out, contains('List<List<double>>'));
      expect(out, contains('required double priority'));
      // Structurally equal unions share one type.
      expect(out, isNot(contains('MessagesSendArgsContent')));
    });

    test('ignores libraries without the annotation', () async {
      final result = await _build(
        fixture,
        library: "library;\n\nimport 'package:re_convex/re_convex.dart';\n",
      );
      expect(result.succeeded, isTrue);
      expect(
        result.readerWriter.testing.exists(
          AssetId('a', 'lib/api.re_convex.g.part'),
        ),
        isFalse,
      );
    });

    test('names the constant after `name`', () async {
      final out = await _generate(
        fixture,
        library: _library(
          annotation:
              "@ConvexApi('convex/function_spec.json', name: 'backend')",
        ),
      );
      expect(out, contains(r'const backend = _$Backend();'));
    });

    test('fails on a missing spec, with how to make one', () async {
      final errors = await _failure('', withSpec: false);
      expect(errors, contains('npx convex function-spec'));
    });

    test('fails on JSON that is not a function spec', () async {
      expect(
        await _failure('{"nope": true}'),
        contains('Expected the output of `npx convex function-spec`'),
      );
      expect(await _failure('{'), contains('Invalid function spec JSON'));
    });

    test('fails when two functions get the same getter', () async {
      final errors = await _failure(
        _spec(
          '{"args": {"type": "any"}, "functionType": "Query", '
          '"identifier": "a.js:user_name", "returns": null, '
          '"visibility": {"kind": "public"}}, '
          '{"args": {"type": "any"}, "functionType": "Query", '
          '"identifier": "a.js:userName", "returns": null, '
          '"visibility": {"kind": "public"}}',
        ),
      );
      expect(errors, contains('`a:userName`'));
      expect(errors, contains('`a:user_name`'));
    });
  });
}
