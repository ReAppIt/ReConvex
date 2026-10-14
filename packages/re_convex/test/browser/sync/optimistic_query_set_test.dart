import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates_impl.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/values/value.dart';

import '../../support/fakes.dart';

FunctionResult _success(Value value) =>
    FunctionSuccess(value: value, logLines: const []);

void main() {
  late OptimisticQueryResults optimisticQuerySet;
  setUp(() {
    optimisticQuerySet = OptimisticQueryResults();
  });

  Value valueOf(QueryToken token) =>
      optimisticQuerySet.queryResult(token)?.value;

  test('server results are returned back if no optimistic updates exist', () {
    final queryToken1 = serializePathAndArgs('query1', {});
    final queryToken2 = serializePathAndArgs('query2', {});
    final QueryResultsMap queryResults = {
      queryToken1: Query(
        result: _success('query1 result'),
        udfPath: 'query1',
        args: {},
      ),
      queryToken2: Query(
        result: _success('query2 result'),
        udfPath: 'query2',
        args: {},
      ),
    };
    final changedQueries = optimisticQuerySet.ingestQueryResultsFromServer(
      queryResults,
      {},
    );

    expect(changedQueries, [queryToken1, queryToken2]);
    expect(valueOf(queryToken1), 'query1 result');
    expect(valueOf(queryToken2), 'query2 result');
  });

  test('errors are thrown if we receive an error from the server', () {
    final queryToken = serializePathAndArgs('query', {});
    final QueryResultsMap serverQueryResults = {
      queryToken: Query(
        result: const FunctionFailure(
          errorMessage: 'Server Error',
          logLines: [],
        ),
        udfPath: 'query',
        args: {},
      ),
    };
    final changedQueries = optimisticQuerySet.ingestQueryResultsFromServer(
      serverQueryResults,
      {},
    );
    expect(changedQueries, [queryToken]);
    expect(
      () => optimisticQuerySet.queryResult(queryToken),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('[CONVEX Q(query)] Server Error'),
        ),
      ),
    );
  });

  test('optimistic updates edit query results', () {
    final queryToken = serializePathAndArgs('query', {});
    QueryResultsMap createQueryResults(double value) => {
      queryToken: Query(result: _success(value), udfPath: 'query', args: {}),
    };

    // Add a query to our store
    final changedQueries = optimisticQuerySet.ingestQueryResultsFromServer(
      createQueryResults(100),
      {},
    );
    expect(changedQueries, [queryToken]);
    expect(valueOf(queryToken), 100);

    // Edit the query with an optimistic update and confirm it ran.
    final changedQueries2 = optimisticQuerySet.applyOptimisticUpdate((
      localStore,
    ) {
      final oldResult = localStore.getQuery(anyQuery('query'), noArgs)!.value;
      localStore.setQuery(anyQuery('query'), noArgs, (
        value: (oldResult! as double) + 1,
      ));
    }, 0);
    expect(changedQueries2, [queryToken]);
    expect(valueOf(queryToken), 101);

    // A new server result while the update is in place replays it on top.
    final changedQueries3 = optimisticQuerySet.ingestQueryResultsFromServer(
      createQueryResults(200),
      {},
    );
    expect(changedQueries3, [queryToken]);
    expect(valueOf(queryToken), 201);

    // The update can be dropped
    final changedQueries4 = optimisticQuerySet.ingestQueryResultsFromServer(
      createQueryResults(300),
      {0},
    );
    expect(changedQueries4, [queryToken]);
    expect(valueOf(queryToken), 300);
  });

  test('optimistic updates only notify changed queries', () {
    // Set up 2 queries
    final queryToken1 = serializePathAndArgs('query1', {});
    final queryToken2 = serializePathAndArgs('query2', {});
    final QueryResultsMap queryResults = {
      queryToken1: Query(
        result: _success('query1 result'),
        udfPath: 'query1',
        args: {},
      ),
      queryToken2: Query(
        result: _success('query2 result'),
        udfPath: 'query2',
        args: {},
      ),
    };
    final changedQueries = optimisticQuerySet.ingestQueryResultsFromServer(
      queryResults,
      {},
    );
    // Confirm they were both added
    expect(changedQueries, [queryToken1, queryToken2]);
    expect(valueOf(queryToken1), 'query1 result');
    expect(valueOf(queryToken2), 'query2 result');

    // Update the first query
    final changedQueries2 = optimisticQuerySet.applyOptimisticUpdate((
      localStore,
    ) {
      localStore.setQuery(anyQuery('query1'), noArgs, (
        value: 'new query1 result',
      ));
    }, 0);

    // Only the first query changed
    expect(changedQueries2, [queryToken1]);
    expect(valueOf(queryToken1), 'new query1 result');
    expect(valueOf(queryToken2), 'query2 result');
  });

  test('optimistic updates stack', () {
    // Start our server query value at 2.
    final queryToken = serializePathAndArgs('query', {});
    final QueryResultsMap serverQueryResults = {
      queryToken: Query(result: _success(2.0), udfPath: 'query', args: {}),
    };
    optimisticQuerySet.ingestQueryResultsFromServer(serverQueryResults, {});
    expect(valueOf(queryToken), 2);

    double current(OptimisticLocalStore store) =>
        store.getQuery(anyQuery('query'), noArgs)!.value! as double;

    // The first update adds 1.
    optimisticQuerySet.applyOptimisticUpdate((localStore) {
      localStore.setQuery(anyQuery('query'), noArgs, (
        value: current(localStore) + 1,
      ));
    }, 0);
    expect(valueOf(queryToken), 3);

    // The second update multiplies by 2.
    optimisticQuerySet.applyOptimisticUpdate((localStore) {
      localStore.setQuery(anyQuery('query'), noArgs, (
        value: current(localStore) * 2,
      ));
    }, 1);
    expect(valueOf(queryToken), 6);

    // Drop the first update. Now we're just multiplying by 2.
    optimisticQuerySet.ingestQueryResultsFromServer(serverQueryResults, {0});
    expect(valueOf(queryToken), 4);
    // Drop the second update. We're back to the start
    optimisticQuerySet.ingestQueryResultsFromServer(serverQueryResults, {1});
    expect(valueOf(queryToken), 2);
  });

  test('optimistic updates can set query results to undefined', () {
    // Important: devs can set queries to "loading".
    final queryToken = serializePathAndArgs('query', {});
    final QueryResultsMap serverQueryResults = {
      queryToken: Query(
        result: _success('query value'),
        udfPath: 'query',
        args: {},
      ),
    };
    final changedQueries = optimisticQuerySet.ingestQueryResultsFromServer(
      serverQueryResults,
      {},
    );
    expect(changedQueries, [queryToken]);
    expect(valueOf(queryToken), 'query value');

    // make it undefined
    optimisticQuerySet.applyOptimisticUpdate((localStore) {
      localStore.setQuery(anyQuery('query'), noArgs, null);
    }, 0);
    expect(optimisticQuerySet.queryResult(queryToken), isNull);
  });

  test('a null result is a value, not loading', () {
    final queryToken = serializePathAndArgs('query', {});
    optimisticQuerySet.ingestQueryResultsFromServer({
      queryToken: Query(result: _success(null), udfPath: 'query', args: {}),
    }, {});
    expect(optimisticQuerySet.queryResult(queryToken), (value: null));
  });
}
