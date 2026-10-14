import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/server.dart';

void main() {
  group('getFunctionName', () {
    test('returns the name of a reference', () {
      final reference = makeFunctionReference<QueryType, Object?, Object?>(
        'dir/module:fn',
      );
      expect(getFunctionName(reference), 'dir/module:fn');
    });
  });

  group('FunctionReference', () {
    test('compares by name', () {
      expect(
        makeFunctionReference<QueryType, Object?, Object?>('a:b'),
        const FunctionReference<MutationType, Object?, Object?>('a:b'),
      );
    });

    test('decodes results with a cast or the decode function', () {
      const plain = FunctionReference<QueryType, Object?, String>('a:b');
      expect(plain.decodeResult('x'), 'x');
      final listed = makeFunctionReference<QueryType, Object?, List<String>>(
        'a:c',
        decode: (value) => (value! as List<Object?>).cast(),
      );
      expect(listed.decodeResult(<Object?>['x']), isA<List<String>>());
    });
  });
}
