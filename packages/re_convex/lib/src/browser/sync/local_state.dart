// Ported from convex/src/browser/sync/local_state.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/browser/sync/udf_path_utils.dart';
import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/values/value.dart';

final class _LocalQuery {
  _LocalQuery({
    required this.id,
    required this.canonicalizedUdfPath,
    required this.args,
    required this.numSubscribers,
    this.journal,
    this.componentPath,
  });

  final QueryId id;
  final String canonicalizedUdfPath;
  final Map<String, Value> args;
  int numSubscribers;
  // `null` means no journal yet; the record may hold a `null` journal.
  ({QueryJournal value})? journal;
  final String? componentPath;
}

/// The token a client authenticates with.
final class AuthState {
  /// A user's JWT.
  const AuthState.user(this.value) : tokenType = 'User', impersonating = null;

  /// An admin key, optionally [impersonating] a user.
  const AuthState.admin(this.value, {this.impersonating}) : tokenType = 'Admin';

  /// `User` or `Admin`.
  final String tokenType;

  /// The token.
  final String value;

  /// The user an admin acts as.
  final UserIdentityAttributes? impersonating;

  Authenticate _authenticate(IdentityVersion baseVersion) =>
      tokenType == 'Admin'
      ? Authenticate.admin(
          value: value,
          baseVersion: baseVersion,
          impersonating: impersonating,
        )
      : Authenticate.user(value: value, baseVersion: baseVersion);
}

/// The local state of the client: the subscribed queries, the query set
/// version, and the auth token with its identity version.
///
/// Query results live in `RemoteQuerySet` and `OptimisticQueryResults`.
class LocalSyncState {
  QueryId _nextQueryId = 0;
  QuerySetVersion _querySetVersion = 0;
  final Map<QueryToken, _LocalQuery> _querySet = {};
  final Map<QueryId, QueryToken> _queryIdToToken = {};
  IdentityVersion _identityVersion = 0;
  AuthState? _auth;
  final Set<QueryId> _outstandingQueriesOlderThanRestart = {};
  bool _outstandingAuthOlderThanRestart = false;
  bool _paused = false;
  final Map<QueryId, ClientMessage> _pendingQuerySetModifications = {};

  /// Whether every query and the auth sent before the last restart has been
  /// confirmed by the server.
  bool hasSyncedPastLastReconnect() =>
      _outstandingQueriesOlderThanRestart.isEmpty &&
      !_outstandingAuthOlderThanRestart;

  /// Marks the auth sent before the last restart as confirmed.
  void markAuthCompletion() {
    _outstandingAuthOlderThanRestart = false;
  }

  /// Subscribes to [udfPath] with [args]; the modification is `null` when
  /// the query was already subscribed.
  ({
    QueryToken queryToken,
    QuerySetModification? modification,
    QuerySetModification? Function() unsubscribe,
  })
  subscribe(
    String udfPath,
    Map<String, Value> args, {
    QueryJournal journal,
    String? componentPath,
  }) {
    final canonicalizedUdfPath = canonicalizeUdfPath(udfPath);
    final queryToken = serializePathAndArgs(canonicalizedUdfPath, args);

    final existingEntry = _querySet[queryToken];

    if (existingEntry != null) {
      existingEntry.numSubscribers += 1;
      return (
        queryToken: queryToken,
        modification: null,
        unsubscribe: () => _removeSubscriber(queryToken),
      );
    }
    final queryId = _nextQueryId++;
    final query = _LocalQuery(
      id: queryId,
      canonicalizedUdfPath: canonicalizedUdfPath,
      args: args,
      numSubscribers: 1,
      journal: journal == null ? null : (value: journal),
      componentPath: componentPath,
    );
    _querySet[queryToken] = query;
    _queryIdToToken[queryId] = queryToken;

    final baseVersion = _querySetVersion;
    final newVersion = _querySetVersion + 1;

    final add = AddQuery(
      queryId: queryId,
      udfPath: canonicalizedUdfPath,
      args: [convexToJson(args)],
      journal: query.journal,
      componentPath: componentPath,
    );

    if (_paused) {
      _pendingQuerySetModifications[queryId] = add;
    } else {
      _querySetVersion = newVersion;
    }

    final modification = QuerySetModification(
      baseVersion: baseVersion,
      newVersion: newVersion,
      modifications: [add],
    );
    return (
      queryToken: queryToken,
      modification: modification,
      unsubscribe: () => _removeSubscriber(queryToken),
    );
  }

  /// Applies the journals and confirmations in [transition].
  void transition(Transition transition) {
    for (final modification in transition.modifications) {
      switch (modification.type) {
        case 'QueryUpdated':
        case 'QueryFailed':
          _outstandingQueriesOlderThanRestart.remove(modification.queryId);
          if (modification.hasJournal) {
            final queryToken = _queryIdToToken[modification.queryId];
            // We may have unsubscribed before the journal came; ignore it.
            if (queryToken != null) {
              _querySet[queryToken]!.journal = (value: modification.journal);
            }
          }
        case 'QueryRemoved':
          _outstandingQueriesOlderThanRestart.remove(modification.queryId);
        default:
          throw StateError('Invalid modification ${modification.type}');
      }
    }
  }

  /// The id of the subscribed query [udfPath] with [args], if any.
  QueryId? queryId(String udfPath, Map<String, Value> args) {
    final canonicalizedUdfPath = canonicalizeUdfPath(udfPath);
    final queryToken = serializePathAndArgs(canonicalizedUdfPath, args);
    return _querySet[queryToken]?.id;
  }

  /// Whether [version] is the current identity version or newer.
  bool isCurrentOrNewerAuthVersion(IdentityVersion version) =>
      version >= _identityVersion;

  /// The current auth, if any.
  AuthState? getAuth() => _auth;

  /// Authenticates with the user JWT [value].
  Authenticate setAuth(String value) {
    _auth = AuthState.user(value);
    final baseVersion = _identityVersion;
    if (!_paused) {
      _identityVersion = baseVersion + 1;
    }
    return _auth!._authenticate(baseVersion);
  }

  /// Authenticates with an admin key, optionally acting as [actingAs].
  Authenticate setAdminAuth(String value, [UserIdentityAttributes? actingAs]) {
    final auth = AuthState.admin(value, impersonating: actingAs);
    _auth = auth;
    final baseVersion = _identityVersion;
    if (!_paused) {
      _identityVersion = baseVersion + 1;
    }
    return auth._authenticate(baseVersion);
  }

  /// Clears the identity.
  Authenticate clearAuth() {
    _auth = null;
    markAuthCompletion();
    final baseVersion = _identityVersion;
    if (!_paused) {
      _identityVersion = baseVersion + 1;
    }
    return Authenticate.none(baseVersion: baseVersion);
  }

  /// Whether a token is set.
  bool hasAuth() => _auth != null;

  /// Whether [value] differs from the current token.
  bool isNewAuth(String value) => _auth?.value != value;

  /// The canonical path of the query [queryId], if subscribed.
  String? queryPath(QueryId queryId) {
    final pathAndArgs = _queryIdToToken[queryId];
    if (pathAndArgs != null) {
      return _querySet[pathAndArgs]!.canonicalizedUdfPath;
    }
    return null;
  }

  /// The arguments of the query [queryId], if subscribed.
  Map<String, Value>? queryArgs(QueryId queryId) {
    final pathAndArgs = _queryIdToToken[queryId];
    if (pathAndArgs != null) {
      return _querySet[pathAndArgs]!.args;
    }
    return null;
  }

  /// The token of the query [queryId], if subscribed.
  QueryToken? queryToken(QueryId queryId) => _queryIdToToken[queryId];

  /// The journal of [queryToken], or `null` when it has none.
  QueryJournal queryJournal(QueryToken queryToken) =>
      _querySet[queryToken]?.journal?.value;

  /// The messages that re-create the query set and auth on a new connection.
  (QuerySetModification, Authenticate?) restart() {
    // Works paused or not: queries are recomputed from the remote results.
    _unpause();

    _outstandingQueriesOlderThanRestart.clear();
    final modifications = <ClientMessage>[];
    for (final localQuery in _querySet.values) {
      modifications.add(
        AddQuery(
          queryId: localQuery.id,
          udfPath: localQuery.canonicalizedUdfPath,
          args: [convexToJson(localQuery.args)],
          journal: localQuery.journal,
          componentPath: localQuery.componentPath,
        ),
      );

      // Outstanding until re-confirmed, so retry backoff doesn't reset early.
      _outstandingQueriesOlderThanRestart.add(localQuery.id);
    }
    _querySetVersion = 1;
    final querySet = QuerySetModification(
      baseVersion: 0,
      newVersion: 1,
      modifications: modifications,
    );
    // If there's no auth, no need to send an update as the server will also start with an unknown identity.
    final auth = _auth;
    if (auth == null) {
      _identityVersion = 0;
      return (querySet, null);
    }
    _outstandingAuthOlderThanRestart = true;
    final authenticate = auth._authenticate(0);
    _identityVersion = 1;
    return (querySet, authenticate);
  }

  /// Holds query set changes until [resume].
  void pause() {
    _paused = true;
  }

  /// The messages held since [pause].
  (QuerySetModification?, Authenticate?) resume() {
    final querySet = _pendingQuerySetModifications.isNotEmpty
        ? QuerySetModification(
            baseVersion: _querySetVersion,
            newVersion: ++_querySetVersion,
            modifications: _pendingQuerySetModifications.values.toList(),
          )
        : null;
    final auth = _auth;
    final authenticate = auth?._authenticate(_identityVersion++);

    _unpause();

    return (querySet, authenticate);
  }

  void _unpause() {
    _paused = false;
    _pendingQuerySetModifications.clear();
  }

  QuerySetModification? _removeSubscriber(QueryToken queryToken) {
    final localQuery = _querySet[queryToken]!;

    if (localQuery.numSubscribers > 1) {
      localQuery.numSubscribers -= 1;
      return null;
    }
    _querySet.remove(queryToken);
    _queryIdToToken.remove(localQuery.id);
    _outstandingQueriesOlderThanRestart.remove(localQuery.id);
    final baseVersion = _querySetVersion;
    final newVersion = _querySetVersion + 1;
    final remove = RemoveQuery(queryId: localQuery.id);
    if (_paused) {
      if (_pendingQuerySetModifications.containsKey(localQuery.id)) {
        _pendingQuerySetModifications.remove(localQuery.id);
      } else {
        _pendingQuerySetModifications[localQuery.id] = remove;
      }
    } else {
      _querySetVersion = newVersion;
    }
    return QuerySetModification(
      baseVersion: baseVersion,
      newVersion: newVersion,
      modifications: [remove],
    );
  }
}
