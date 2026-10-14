import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/browser.dart';
import 'package:re_convex/server.dart';

void main() {
  test('convexQueryOptions', () {
    final query =
        makeFunctionReference<QueryType, Map<String, Object?>, String>(
          'jeans style',
        );
    final opts = convexQueryOptions(query: query, args: {'name': 'hey'});
    expect(opts.query, query);
    expect(opts.args, {'name': 'hey'});
    expect(opts, isA<QueryOptions<Map<String, Object?>, String>>());
  });
}
