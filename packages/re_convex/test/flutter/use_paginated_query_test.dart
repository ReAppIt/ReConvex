import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/optimistic_updates.dart';
import 'package:re_convex/src/common/index.dart';
import 'package:re_convex/src/flutter/use_paginated_query.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/server/pagination.dart';
import 'package:re_convex/src/values/compare.dart';
import 'package:re_convex/src/values/value.dart';

typedef _Item = Map<String, Object?>;

final _paginatedQuery =
    makeFunctionReference<
      QueryType,
      Map<String, Object?>,
      PaginationResult<_Item>
    >('messages:list');

class _LocalQueryStoreFake implements OptimisticLocalStore {
  final Map<
    String,
    Map<String, ({Map<String, Value> args, ({Value value})? value})>
  >
  queries = {};

  @override
  void setQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
    ({R value})? value,
  ) {
    final queriesByName = queries[getFunctionName(query)] ??= {};
    final rawArgs = parseArgs(args);
    final serializedArgs = jsonEncode(convexToJson(rawArgs));
    queriesByName[serializedArgs] = (
      args: rawArgs,
      value: value == null ? null : (value: value.value),
    );
  }

  @override
  List<({A args, ({R value})? value})> getAllQueries<A, R>(
    FunctionReference<QueryType, A, R> query,
  ) => [
    for (final q in (queries[getFunctionName(query)] ?? const {}).values)
      (
        args: q.args as A,
        value: q.value == null
            ? null
            : (value: query.decodeResult(q.value!.value)),
      ),
  ];

  @override
  ({R value})? getQuery<A, R>(
    FunctionReference<QueryType, A, R> query,
    A args,
  ) {
    final serializedArgs = jsonEncode(convexToJson(parseArgs(args)));
    final q = queries[getFunctionName(query)]?[serializedArgs]?.value;
    return q == null ? null : (value: query.decodeResult(q.value));
  }
}

Object? _opt(Map<String, Object?> args, String key) =>
    (args['paginationOpts']! as Map<String, Object?>)[key];

List<_Item> _getPaginatedQueryResults({
  required _LocalQueryStoreFake localQueryStore,
  Map<String, Value>? argsToMatch,
}) {
  final allQueries = localQueryStore.getAllQueries(_paginatedQuery);
  final loadedQueries = [
    for (final q in allQueries)
      if (argsToMatch == null ||
          argsToMatch.keys.every(
            (key) => compareValues(q.args[key], argsToMatch[key]) == 0,
          ))
        (args: q.args, value: q.value!.value),
  ];
  final firstPage = loadedQueries
      .where((q) => _opt(q.args, 'cursor') == null)
      .firstOrNull;
  if (firstPage == null) {
    return [];
  }
  final sortedResults = [...firstPage.value.page];
  String? currentCursor = firstPage.value.continueCursor;
  while (currentCursor != null) {
    final cursor = currentCursor;
    final nextPage = loadedQueries
        .where((r) => _opt(r.args, 'cursor') == cursor)
        .firstOrNull;
    if (nextPage == null) {
      break;
    }
    sortedResults.addAll(nextPage.value.page);
    if (nextPage.value.isDone) {
      break;
    }
    currentCursor = nextPage.value.continueCursor;
  }
  return sortedResults;
}

void _setupPages({
  required _LocalQueryStoreFake localQueryStore,
  required Map<String, Value> args,
  required List<List<_Item>> pages,
  required bool isDone,
}) {
  String? currentCursor;
  for (var i = 0; i < pages.length; i++) {
    final nextCursor = 'cursor$i';
    localQueryStore.setQuery(
      _paginatedQuery,
      {
        ...args,
        'paginationOpts': {
          'cursor': currentCursor,
          'id': jsonEncode(args),
          'numItems': 10.0,
        },
      },
      (
        value: PaginationResult<_Item>(
          page: pages[i],
          continueCursor: nextCursor,
          isDone: i == pages.length - 1 && isDone,
        ),
      ),
    );
    currentCursor = nextCursor;
  }
}

_Item _message(String author) => {'author': author, 'content': 'Hello, world!'};

_Item _ranked(String author, double rank) => {'author': author, 'rank': rank};

void main() {
  group('insertAtTop', () {
    test('does not insert if the query is not loaded', () {
      final localQueryStore = _LocalQueryStoreFake();
      insertAtTop(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        item: _message('Sarah'),
      );
      expect(localQueryStore.getAllQueries(_paginatedQuery), isEmpty);
    });

    test('inserts at top', () {
      final localQueryStore = _LocalQueryStoreFake();
      _setupPages(
        localQueryStore: localQueryStore,
        args: {},
        pages: [
          [_message('Alice'), _message('Bob')],
        ],
        isDone: false,
      );

      insertAtTop(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        item: _message('Sarah'),
      );
      expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
        _message('Sarah'),
        _message('Alice'),
        _message('Bob'),
      ]);
    });

    test('inserts at top multiple pages', () {
      final localQueryStore = _LocalQueryStoreFake();
      _setupPages(
        localQueryStore: localQueryStore,
        args: {},
        pages: [
          [_message('Alice'), _message('Bob')],
          [_message('Charlie'), _message('Dave')],
        ],
        isDone: false,
      );
      insertAtTop(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        item: _message('Sarah'),
      );
      expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
        _message('Sarah'),
        _message('Alice'),
        _message('Bob'),
        _message('Charlie'),
        _message('Dave'),
      ]);
    });

    test('respects filters', () {
      final localQueryStore = _LocalQueryStoreFake();
      _setupPages(
        localQueryStore: localQueryStore,
        args: {'channel': 'general'},
        pages: [
          [_message('Alice'), _message('Bob')],
        ],
        isDone: false,
      );
      _setupPages(
        localQueryStore: localQueryStore,
        args: {'channel': 'marketing'},
        pages: [
          [_message('Charlie'), _message('Dave')],
        ],
        isDone: false,
      );

      insertAtTop(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        argsToMatch: {'channel': 'general'},
        item: _message('Sarah'),
      );

      expect(
        _getPaginatedQueryResults(
          localQueryStore: localQueryStore,
          argsToMatch: {'channel': 'general'},
        ),
        [_message('Sarah'), _message('Alice'), _message('Bob')],
      );
    });
  });

  group('insertAtBottomIfLoaded', () {
    test('inserts at the bottom of a finished list only', () {
      final localQueryStore = _LocalQueryStoreFake();
      _setupPages(
        localQueryStore: localQueryStore,
        args: {},
        pages: [
          [_message('Alice')],
        ],
        isDone: false,
      );
      insertAtBottomIfLoaded(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        item: _message('Sarah'),
      );
      expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
        _message('Alice'),
      ]);

      _setupPages(
        localQueryStore: localQueryStore,
        args: {},
        pages: [
          [_message('Alice')],
        ],
        isDone: true,
      );
      insertAtBottomIfLoaded(
        paginatedQuery: _paginatedQuery,
        localQueryStore: localQueryStore,
        item: _message('Sarah'),
      );
      expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
        _message('Alice'),
        _message('Sarah'),
      ]);
    });
  });

  group('insertAtPosition', () {
    void insert(
      _LocalQueryStoreFake localQueryStore,
      _Item item,
      SortOrder sortOrder,
    ) => insertAtPosition(
      paginatedQuery: _paginatedQuery,
      localQueryStore: localQueryStore,
      item: item,
      sortOrder: sortOrder,
      sortKeyFromItem: (item) => item['rank'],
    );

    group('descending', () {
      final defaultPages = [
        [_ranked('Dave', 40), _ranked('Charlie', 30)],
        [_ranked('Bob', 20), _ranked('Alice', 10)],
      ];

      _LocalQueryStoreFake setup({required bool isDone}) {
        final localQueryStore = _LocalQueryStoreFake();
        _setupPages(
          localQueryStore: localQueryStore,
          args: {},
          pages: defaultPages,
          isDone: isDone,
        );
        return localQueryStore;
      }

      test('inserts in middle', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 15), SortOrder.desc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Dave', 40),
          _ranked('Charlie', 30),
          _ranked('Bob', 20),
          _ranked('Sarah', 15),
          _ranked('Alice', 10),
        ]);
      });

      test('inserts at top', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 55), SortOrder.desc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Sarah', 55),
          _ranked('Dave', 40),
          _ranked('Charlie', 30),
          _ranked('Bob', 20),
          _ranked('Alice', 10),
        ]);
      });

      test('inserts at bottom if list is done', () {
        final localQueryStore = setup(isDone: true);
        insert(localQueryStore, _ranked('Sarah', 5), SortOrder.desc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Dave', 40),
          _ranked('Charlie', 30),
          _ranked('Bob', 20),
          _ranked('Alice', 10),
          _ranked('Sarah', 5),
        ]);
      });

      test('does not insert at bottom if list is still loading', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 5), SortOrder.desc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Dave', 40),
          _ranked('Charlie', 30),
          _ranked('Bob', 20),
          _ranked('Alice', 10),
        ]);
      });

      test('inserts on page boundary', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 29), SortOrder.desc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Dave', 40),
          _ranked('Charlie', 30),
          _ranked('Sarah', 29),
          _ranked('Bob', 20),
          _ranked('Alice', 10),
        ]);
      });
    });

    group('ascending', () {
      final defaultPages = [
        [_ranked('Alice', 10), _ranked('Bob', 20)],
        [_ranked('Charlie', 30), _ranked('Dave', 40)],
      ];

      _LocalQueryStoreFake setup({required bool isDone}) {
        final localQueryStore = _LocalQueryStoreFake();
        _setupPages(
          localQueryStore: localQueryStore,
          args: {},
          pages: defaultPages,
          isDone: isDone,
        );
        return localQueryStore;
      }

      test('inserts in middle', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 15), SortOrder.asc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Alice', 10),
          _ranked('Sarah', 15),
          _ranked('Bob', 20),
          _ranked('Charlie', 30),
          _ranked('Dave', 40),
        ]);
      });

      test('inserts at top', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 5), SortOrder.asc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Sarah', 5),
          _ranked('Alice', 10),
          _ranked('Bob', 20),
          _ranked('Charlie', 30),
          _ranked('Dave', 40),
        ]);
      });

      test('inserts at bottom if list is done', () {
        final localQueryStore = setup(isDone: true);
        insert(localQueryStore, _ranked('Sarah', 50), SortOrder.asc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Alice', 10),
          _ranked('Bob', 20),
          _ranked('Charlie', 30),
          _ranked('Dave', 40),
          _ranked('Sarah', 50),
        ]);
      });

      test('does not insert at bottom if list is still loading', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 50), SortOrder.asc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Alice', 10),
          _ranked('Bob', 20),
          _ranked('Charlie', 30),
          _ranked('Dave', 40),
        ]);
      });

      test('inserts on page boundary', () {
        final localQueryStore = setup(isDone: false);
        insert(localQueryStore, _ranked('Sarah', 21), SortOrder.asc);
        expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
          _ranked('Alice', 10),
          _ranked('Bob', 20),
          _ranked('Sarah', 21),
          _ranked('Charlie', 30),
          _ranked('Dave', 40),
        ]);
      });
    });
  });

  group('optimisticallyUpdateValueInPaginatedQuery', () {
    test('updates matching items in every loaded page', () {
      final localQueryStore = _LocalQueryStoreFake();
      _setupPages(
        localQueryStore: localQueryStore,
        args: {'channel': 'general'},
        pages: [
          [_ranked('Alice', 10)],
          [_ranked('Bob', 20)],
        ],
        isDone: true,
      );
      optimisticallyUpdateValueInPaginatedQuery(
        localQueryStore,
        _paginatedQuery,
        {'channel': 'general'},
        (item) => {...item, 'rank': (item['rank']! as double) + 1},
      );
      expect(_getPaginatedQueryResults(localQueryStore: localQueryStore), [
        _ranked('Alice', 11),
        _ranked('Bob', 21),
      ]);
    });
  });
}
