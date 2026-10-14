import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/client.dart';

import '../../support/fakes.dart';

void main() {
  test('localQueryResult reflects optimistic results', () async {
    final client = BaseConvexClient(
      'http://127.0.0.1:8000',
      (_) {
        // ignore updates.
      },
      BaseConvexClientOptions(
        webSocketConstructor: offlineWebSocketConstructor,
        logger: instantiateNoopLogger(),
      ),
    );

    expect(client.localQueryResult('myUdf', noArgs), isNull);

    // don't wait for mutation to complete
    unawaited(
      client
          .mutation(
            'myUdf',
            noArgs,
            optimisticUpdate: (localQueryStore, _) {
              localQueryStore.setQuery(anyQuery('myUdf'), noArgs, (
                value: true,
              ));
            },
          )
          .then((_) {}, onError: (_) {}),
    );
    expect(client.localQueryResult('myUdf', noArgs), (value: true));
    await client.close();
  });
}
