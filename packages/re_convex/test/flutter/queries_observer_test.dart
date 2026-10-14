import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/protocol.dart' show QueryJournal;
import 'package:re_convex/src/flutter/queries_observer.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/value.dart';

import '../support/fake_watch.dart';
import '../support/fakes.dart';

typedef _Call = ({
  AnyFunctionReference query,
  Map<String, Value> args,
  QueryJournal journal,
});

class _CreateWatch {
  final List<_Call> calls = [];
  final List<FakeWatch<Object?>> results = [];
  FakeWatch<Object?> Function() make = FakeWatch<Object?>.new;

  Object call(
    AnyFunctionReference query,
    Map<String, Value> args, {
    QueryJournal journal,
    SubscribeToPaginatedQueryOptions? paginationOptions,
  }) {
    calls.add((query: query, args: args, journal: journal));
    final watch = make();
    results.add(watch);
    return watch;
  }
}

QueryRequest _request(String name, [Map<String, Value> args = noArgs]) =>
    QueryRequest(query: anyQuery(name), args: args);

void main() {
  late QueriesObserver queriesObserver;
  late _CreateWatch createWatch;
  late int listenerCalls;

  setUp(() {
    createWatch = _CreateWatch();
    queriesObserver = QueriesObserver(createWatch.call);
    listenerCalls = 0;
    queriesObserver.subscribe(() => listenerCalls++);
  });

  tearDown(() {
    queriesObserver.destroy();
  });

  test('`getLocalResults`', () {
    final queries = {'query': _request('myQuery')};
    queriesObserver.setQueries(queries);
    expect(queriesObserver.getLocalResults(queries), {'query': null});
    // The listener isn't notified for our own changes.
    expect(listenerCalls, 0);

    // An updated value notifies the listener and shows in local results.
    createWatch.results[0].setValue((value: 'query value'));
    expect(listenerCalls, 1);
    createWatch.make = () =>
        FakeWatch<Object?>()..value = (value: 'query value');
    expect(queriesObserver.getLocalResults(queries), {
      'query': (value: 'query value'),
    });
  });

  test('If the query changes, only stay subscribed to the second query', () {
    queriesObserver
      ..setQueries({'query': _request('myQuery')})
      ..setQueries({'query': _request('myQuery2')});

    // The listener isn't notified for our own changes.
    expect(listenerCalls, 0);

    // There were 2 watches created. We should be subscribed to only the second.
    expect(createWatch.calls, hasLength(2));
    expect(createWatch.results[0].numCallbacks(), 0);
    expect(createWatch.results[1].numCallbacks(), 1);
  });

  test('If the query args change, only stay subscribed to the second args', () {
    queriesObserver
      ..setQueries({
        'query': _request('myQuery', {'arg': 'first arg'}),
      })
      ..setQueries({
        'query': _request('myQuery', {'arg': 'new arg'}),
      });

    // The listener isn't notified for our own changes.
    expect(listenerCalls, 0);

    // There were 2 watches created. We should be subscribed to only the second.
    expect(createWatch.calls, hasLength(2));
    expect(createWatch.results[0].numCallbacks(), 0);
    expect(createWatch.results[1].numCallbacks(), 1);
  });

  test("If the query doesn't change, we only have one subscription", () {
    queriesObserver.setQueries({
      'query': _request('myQuery', {
        'arg1': 'arg1',
        'arg2': 1.0,
        'arg3': <String, Object?>{},
      }),
    });
    expect(createWatch.calls, hasLength(1));
    expect(createWatch.results[0].numCallbacks(), 1);

    // Re-adding the same query doesn't create a new watch.
    queriesObserver.setQueries({
      'query': _request('myQuery', {
        'arg1': 'arg1',
        'arg2': 1.0,
        'arg3': <String, Object?>{},
      }),
    });
    expect(createWatch.calls, hasLength(1));
    expect(createWatch.results[0].numCallbacks(), 1);
  });

  test('destroy unsubscribes from all queries', () {
    queriesObserver
      ..setQueries({'query': _request('myQuery')})
      ..destroy();

    // No subscriptions to the watch now.
    expect(createWatch.calls, hasLength(1));
    expect(createWatch.results[0].numCallbacks(), 0);
  });

  test('swapping createWatch recreates subscriptions', () {
    queriesObserver.setQueries({'query': _request('myQuery')});
    // We should have a listen for the query.
    expect(createWatch.calls, hasLength(1));
    expect(createWatch.results[0].numCallbacks(), 1);
    // Pretend that the server sent us a query journal
    createWatch.results[0].setJournal('query journal');

    // Swap out the `createWatch` function.
    final createWatch2 = _CreateWatch();
    queriesObserver.setCreateWatch(createWatch2.call);

    // No subscriptions left for the original watch.
    expect(createWatch.calls, hasLength(1));
    expect(createWatch.results[0].numCallbacks(), 0);

    // A sub uses the new createWatch, with the journal passed through!
    expect(createWatch2.calls, hasLength(1));
    expect(createWatch2.results[0].numCallbacks(), 1);
    expect(createWatch2.calls[0].query, anyQuery('myQuery'));
    expect(createWatch2.calls[0].args, isEmpty);
    expect(createWatch2.calls[0].journal, 'query journal');
  });
}
