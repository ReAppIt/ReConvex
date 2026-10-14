// Ported from convex/src/browser/sync/remote_query_set.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/long.dart';

/// The query results received on the current WebSocket connection.
///
/// It lacks queries still waiting for their first transition, queries that
/// only optimistic updates populate, and queries the server removed.
class RemoteQuerySet {
  /// Creates an empty set; `queryPath` names a query for its log lines.
  RemoteQuerySet(this._queryPath, this._logger);

  StateVersion _version = StateVersion(
    querySet: 0,
    ts: Long.fromNumber(0),
    identity: 0,
  );
  final Map<QueryId, FunctionResult> _remoteQuerySet = {};
  final String? Function(QueryId queryId) _queryPath;
  final ConvexLogger _logger;

  /// Applies [transition]; throws when it doesn't start at the current
  /// version.
  void transition(Transition transition) {
    final start = transition.startVersion;
    if (_version.querySet != start.querySet ||
        _version.ts.notEquals(start.ts) ||
        _version.identity != start.identity) {
      throw StateError(
        'Invalid start version: ${start.ts}:${start.querySet}:'
        '${start.identity}, transitioning from ${_version.ts}:'
        '${_version.querySet}:${_version.identity}',
      );
    }
    for (final modification in transition.modifications) {
      switch (modification.type) {
        case 'QueryUpdated':
          final queryPath = _queryPath(modification.queryId);
          if (queryPath != null) {
            for (final line in modification.logLines) {
              logForFunction(
                _logger,
                LogLevel.info,
                UdfType.query,
                queryPath,
                line,
              );
            }
          }
          final value = jsonToConvex(modification.value);
          _remoteQuerySet[modification.queryId] = FunctionSuccess(
            value: value,
            logLines: modification.logLines,
          );
        case 'QueryFailed':
          final queryPath = _queryPath(modification.queryId);
          if (queryPath != null) {
            for (final line in modification.logLines) {
              logForFunction(
                _logger,
                LogLevel.info,
                UdfType.query,
                queryPath,
                line,
              );
            }
          }
          _remoteQuerySet[modification.queryId] = FunctionFailure(
            errorMessage: modification.errorMessage,
            errorData: modification.hasErrorData
                ? (value: jsonToConvex(modification.errorData))
                : null,
            logLines: modification.logLines,
          );
        case 'QueryRemoved':
          _remoteQuerySet.remove(modification.queryId);
        default:
          throw StateError('Invalid modification ${modification.type}');
      }
    }
    _version = transition.endVersion;
  }

  /// The results by query id.
  Map<QueryId, FunctionResult> remoteQueryResults() => _remoteQuerySet;

  /// The server timestamp of the current version.
  Long timestamp() => _version.ts;
}
