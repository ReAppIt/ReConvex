@Tags(['widget'])
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/flutter/client.dart';

import '../support/fakes.dart';

const _address = 'https://127.0.0.1:3001';

ConvexReactClient _createClientWithQuery() {
  final client = ConvexReactClient(
    _address,
    ConvexReactClientOptions(
      webSocketConstructor: offlineWebSocketConstructor,
      logger: instantiateNoopLogger(),
    ),
  );
  // Use an optimistic update to set up a query to have a result.
  unawaited(
    client
        .mutation(
          anyMutation('myMutation'),
          noArgs,
          optimisticUpdate: (localStore, _) {
            localStore.setQuery(anyQuery('myQuery'), noArgs, (
              value: 'queryResult',
            ));
          },
        )
        .then((_) {}, onError: (_) {}),
  );
  return client;
}

Future<void> _render(
  WidgetTester tester,
  ConvexReactClient client,
  void Function() hook,
) => tester.pumpWidget(
  ConvexProvider(
    client: client,
    child: HookBuilder(
      builder: (context) {
        hook();
        return const SizedBox();
      },
    ),
  ),
);

Future<void> _unmount(WidgetTester tester, ConvexReactClient client) async {
  await tester.pumpWidget(const SizedBox());
  await client.close();
}

void main() {
  group('useQuery', () {
    testWidgets('returns the result', (tester) async {
      final client = _createClientWithQuery();
      ({Object? value})? result;
      await _render(
        tester,
        client,
        () => result = useQuery(anyQuery('myQuery'), noArgs),
      );
      expect(result, (value: 'queryResult'));
      await _unmount(tester, client);
    });

    testWidgets('returns undefined when skipped', (tester) async {
      final client = _createClientWithQuery();
      ({Object? value})? result = (value: 'not rendered');
      await _render(
        tester,
        client,
        () => result = useQuery(anyQuery('myQuery'), null, skip: true),
      );
      expect(result, isNull);
      await _unmount(tester, client);
    });

    testWidgets('object form returns success result', (tester) async {
      final client = _createClientWithQuery();
      UseQueryResult<Object?>? result;
      await _render(
        tester,
        client,
        () => result = useQuery_experimental(
          query: anyQuery('myQuery'),
          args: noArgs,
        ),
      );
      expect(
        result,
        isA<UseQuerySuccess<Object?>>()
            .having((r) => r.data, 'data', 'queryResult')
            .having((r) => r.status, 'status', 'success'),
      );
      await _unmount(tester, client);
    });

    testWidgets('object form returns pending when skipped', (tester) async {
      final client = _createClientWithQuery();
      UseQueryResult<Object?>? result;
      await _render(
        tester,
        client,
        () => result = useQuery_experimental(
          query: anyQuery('myQuery'),
          args: null,
          skip: true,
        ),
      );
      expect(
        result,
        isA<UseQueryPending<Object?>>().having(
          (r) => r.status,
          'status',
          'pending',
        ),
      );
      await _unmount(tester, client);
    });
  });
}
