import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/flutter/client.dart';

import '../support/client_node_test_helpers.dart';
import '../support/fakes.dart';

ConvexReactClient _testReactClient(InMemoryWebSocket ws) => ConvexReactClient(
  ws.address,
  ConvexReactClientOptions(webSocketConstructor: ws.webSocketConstructor),
);

void main() {
  test('ConvexReactClient ends subscriptions on close', () async {
    await withInMemoryWebSocket((ws) async {
      final client = _testReactClient(ws);
      final watch = client.watchQuery(anyQuery('myQuery'), noArgs);
      var timesCallbackRan = 0;
      watch.onUpdate(() => timesCallbackRan++);

      expect((await ws.receive())['type'], 'Connect');
      final modify = await ws.receive();
      expect(modify['type'], 'ModifyQuerySet');
      expect(modify['modifications'], [
        {
          'type': 'Add',
          'queryId': 0,
          'udfPath': 'myQuery:default',
          'args': [<String, Object?>{}],
        },
      ]);
      expect(timesCallbackRan, 0);

      ws.send(
        transition(
          startVersion: stateVersion(ts: 0),
          endVersion: stateVersion(querySet: 1, ts: 1),
          modifications: [queryUpdated(0, 0.0)],
        ).json,
      );

      // Close after registering the callback but before it runs.
      final closePromise = client.close();

      expect(timesCallbackRan, 0);

      // After the internal client has closed, same nothing.
      await closePromise;
      expect(timesCallbackRan, 0);
    });
  });
}
