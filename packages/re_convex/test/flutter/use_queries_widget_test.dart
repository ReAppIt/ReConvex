@Tags(['widget'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/flutter/use_queries.dart';
import 'package:re_convex/src/server/api.dart';

import '../support/fake_watch.dart';
import '../support/fakes.dart';

Widget _hook(void Function() hook) => HookBuilder(
  builder: (context) {
    hook();
    return const SizedBox();
  },
);

// Flutter creates a watch to subscribe and one per read; React makes more.
void main() {
  testWidgets('Adding a new query', (tester) async {
    final values = <String, Object?>{};
    final watches = <FakeWatch<Object?>>[];
    Object createWatch(
      FunctionReference<QueryType, Object?, Object?> query,
      Map<String, Object?> args, {
      String? journal,
      SubscribeToPaginatedQueryOptions? paginationOptions,
    }) {
      final name = getFunctionName(query);
      final watch = FakeWatch<Object?>()
        ..value = values.containsKey(name) ? (value: values[name]) : null;
      watches.add(watch);
      return watch;
    }

    // Request 1 query.
    var queries = <String, QueryRequest>{
      'query1': QueryRequest(query: anyQuery('query1'), args: noArgs),
    };
    late Map<String, Object?> result;
    await tester.pumpWidget(
      _hook(() => result = useQueriesHelper(queries, createWatch)),
    );

    // Initially the query is loading.
    expect(result, {'query1': null});
    expect(watches, hasLength(2));

    // When the query loads, we get the result.
    values['query1'] = 'query1 result';
    watches[0].setValue((value: 'query1 result'));
    await tester.pump();
    expect(result, {'query1': (value: 'query1 result')});

    // Add a second query, it's initially loading.
    queries = {
      'query1': QueryRequest(query: anyQuery('query1'), args: noArgs),
      'query2': QueryRequest(query: anyQuery('query2'), args: noArgs),
    };
    await tester.pumpWidget(
      _hook(() => result = useQueriesHelper(queries, createWatch)),
    );
    expect(result, {'query1': (value: 'query1 result'), 'query2': null});
    expect(watches, hasLength(6));

    // When the query resolves, we also get the result.
    values['query2'] = 'query2 result';
    watches[3].setValue((value: 'query2 result'));
    await tester.pump();
    expect(result, {
      'query1': (value: 'query1 result'),
      'query2': (value: 'query2 result'),
    });
  });

  testWidgets('Swapping queries and unsubscribing', (tester) async {
    final watches = <FakeWatch<Object?>>[];
    Object createWatch(
      FunctionReference<QueryType, Object?, Object?> query,
      Map<String, Object?> args, {
      String? journal,
      SubscribeToPaginatedQueryOptions? paginationOptions,
    }) {
      final watch = FakeWatch<Object?>();
      watches.add(watch);
      return watch;
    }

    // Request 1 query.
    var queries = <String, QueryRequest>{
      'query': QueryRequest(query: anyQuery('query1'), args: noArgs),
    };
    await tester.pumpWidget(
      _hook(() => useQueriesHelper(queries, createWatch)),
    );

    // One watch was created and we're listening to it.
    expect(watches, hasLength(2));
    expect(watches[0].numCallbacks(), 1);

    // Switch to a different query.
    queries = {'query1': QueryRequest(query: anyQuery('query2'), args: noArgs)};
    await tester.pumpWidget(
      _hook(() => useQueriesHelper(queries, createWatch)),
    );

    // Only the second query's watch is still listened to.
    expect(watches, hasLength(4));
    expect(watches[0].numCallbacks(), 0);
    expect(watches[2].numCallbacks(), 1);

    // After unmount, we've unsubscribed to all the queries.
    await tester.pumpWidget(const SizedBox());
    expect(watches, hasLength(4));
    expect(watches[0].numCallbacks(), 0);
    expect(watches[2].numCallbacks(), 0);
  });

  testWidgets('Local results on initial render', (tester) async {
    const value = 'query1 result';
    final watches = <FakeWatch<Object?>>[];
    Object createWatch(
      FunctionReference<QueryType, Object?, Object?> query,
      Map<String, Object?> args, {
      String? journal,
      SubscribeToPaginatedQueryOptions? paginationOptions,
    }) {
      final watch = FakeWatch<Object?>()..value = (value: value);
      watches.add(watch);
      return watch;
    }

    // Request 1 query.
    final queries = <String, QueryRequest>{
      'query1': QueryRequest(query: anyQuery('query1'), args: noArgs),
    };
    late Map<String, Object?> result;
    await tester.pumpWidget(
      _hook(() {
        result = useQueriesHelper(queries, createWatch);
        // The new value renders right away, without another build.
        expect(result['query1'], (value: value));
      }),
    );

    expect(result, {'query1': (value: 'query1 result')});
    expect(watches, hasLength(2));
  });
}
