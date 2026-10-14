// Ported from convex/src/browser/sync/request_manager.ts (Apache-2.0); modified for Dart.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/long.dart';

enum _Status { requested, notSent, completed }

final class _RequestStatus {
  _RequestStatus.pending({
    required this.status,
    required this.onResult,
    required this.requestedAt,
  }) : result = null,
       onResolve = null,
       ts = null;

  _RequestStatus.completed({
    required FunctionResult this.result,
    required void Function() this.onResolve,
    required Long this.ts,
  }) : status = _Status.completed,
       onResult = null,
       requestedAt = null;

  _Status status;
  final void Function(FunctionResult result)? onResult;
  final DateTime? requestedAt;
  final FunctionResult? result;
  final void Function()? onResolve;
  final Long? ts;
}

final class _RequestInfo {
  _RequestInfo(this.message, this.status);

  final ClientMessage message;
  _RequestStatus status;

  bool get isMutation => message.type == 'Mutation';

  String get udfPath => message.json['udfPath']! as String;
}

/// Tracks mutations and actions from request to result.
///
/// Successful mutations complete only once a transition reaches their
/// commit timestamp, so callers read their own writes.
class RequestManager {
  /// Creates a manager; `markConnectionStateDirty` runs when counts change.
  RequestManager(this._logger, this._markConnectionStateDirty);

  final ConvexLogger _logger;
  final void Function() _markConnectionStateDirty;
  final Map<RequestId, _RequestInfo> _inflightRequests = {};
  Set<RequestId> _requestsOlderThanRestart = {};
  int _inflightMutationsCount = 0;
  int _inflightActionsCount = 0;

  /// Tracks [message]; the future completes with its result.
  ///
  /// [sent] is false while the socket is paused.
  Future<FunctionResult> request(ClientMessage message, {required bool sent}) {
    final completer = Completer<FunctionResult>();
    final requestId = message.json['requestId']! as int;
    _inflightRequests[requestId] = _RequestInfo(
      message,
      _RequestStatus.pending(
        status: sent ? _Status.requested : _Status.notSent,
        requestedAt: clock.now(),
        onResult: completer.complete,
      ),
    );

    if (message.type == 'Mutation') {
      _inflightMutationsCount++;
    } else if (message.type == 'Action') {
      _inflightActionsCount++;
    }

    _markConnectionStateDirty();
    return completer.future;
  }

  /// Updates the state after a response.
  ///
  /// Returns the request id and result when the request finished and its
  /// optimistic update can be dropped.
  ({RequestId requestId, FunctionResult result})? onResponse(
    ServerMessage response,
  ) {
    final requestId = response.json['requestId']! as int;
    final requestInfo = _inflightRequests[requestId];
    if (requestInfo == null) {
      // A re-sent mutation can get a second response after we dropped it.
      return null;
    }

    // Requests re-sent by `restart()` may answer twice; skip completed ones.
    final status = requestInfo.status;
    if (status.status == _Status.completed) {
      return null;
    }

    final udfType = requestInfo.isMutation ? UdfType.mutation : UdfType.action;
    final udfPath = requestInfo.udfPath;
    final success = response.json['success'] == true;
    final logLines = (response.json['logLines'] as List<Object?>? ?? const [])
        .cast<String>();

    for (final line in logLines) {
      logForFunction(_logger, LogLevel.info, udfType, udfPath, line);
    }

    FunctionResult result;
    if (success) {
      result = FunctionSuccess(
        logLines: logLines,
        value: jsonToConvex(response.json['result']),
      );
    } else {
      final errorMessage = response.json['result']! as String;
      logForFunction(_logger, LogLevel.error, udfType, udfPath, errorMessage);
      result = FunctionFailure(
        errorMessage: errorMessage,
        errorData: response.json.containsKey('errorData')
            ? (value: jsonToConvex(response.json['errorData']))
            : null,
        logLines: logLines,
      );
    }
    void onResolve() => status.onResult!(result);

    // Failures and actions have no side effects to wait for: resolve now.
    if (response.type == 'ActionResponse' || !success) {
      onResolve();
      _inflightRequests.remove(requestId);
      _requestsOlderThanRestart.remove(requestId);

      if (requestInfo.isMutation) {
        _inflightMutationsCount--;
      } else {
        _inflightActionsCount--;
      }

      _markConnectionStateDirty();
      return (requestId: requestId, result: result);
    }

    // Resolve after the transition past this timestamp: read your writes.
    requestInfo.status = _RequestStatus.completed(
      result: result,
      ts: MutationResponse(response.json).ts,
      onResolve: onResolve,
    );

    return null;
  }

  /// Removes and returns the requests completed at or before [ts].
  Map<RequestId, FunctionResult> removeCompleted(Long ts) {
    final completeRequests = <RequestId, FunctionResult>{};
    for (final MapEntry(key: requestId, value: requestInfo)
        in _inflightRequests.entries.toList()) {
      final status = requestInfo.status;
      if (status.status == _Status.completed &&
          status.ts!.lessThanOrEqual(ts)) {
        status.onResolve!();
        completeRequests[requestId] = status.result!;

        if (requestInfo.isMutation) {
          _inflightMutationsCount--;
        } else {
          _inflightActionsCount--;
        }

        _inflightRequests.remove(requestId);
        _requestsOlderThanRestart.remove(requestId);
      }
    }
    if (completeRequests.isNotEmpty) {
      _markConnectionStateDirty();
    }
    return completeRequests;
  }

  /// The requests to re-send on a new connection; fails in-flight actions.
  List<ClientMessage> restart() {
    // On reconnect, re-request every request that is safe to resend.
    _requestsOlderThanRestart = _inflightRequests.keys.toSet();
    final allMessages = <ClientMessage>[];
    for (final MapEntry(key: requestId, value: value)
        in _inflightRequests.entries.toList()) {
      if (value.status.status == _Status.notSent) {
        value.status.status = _Status.requested;
        allMessages.add(value.message);
        continue;
      }

      if (value.isMutation) {
        // Completed ones too, so the server moves the client past them.
        allMessages.add(value.message);
      } else {
        // Actions aren't idempotent: in-flight ones fail instead of resending.
        _inflightRequests.remove(requestId);
        _requestsOlderThanRestart.remove(requestId);
        _inflightActionsCount--;
        if (value.status.status == _Status.completed) {
          throw StateError("Action should never be in 'Completed' state");
        }
        value.status.onResult!(
          const FunctionFailure(
            errorMessage: 'Connection lost while action was in flight',
            logLines: [],
          ),
        );
      }
    }
    _markConnectionStateDirty();
    return allMessages;
  }

  /// The requests held while the socket was paused.
  List<ClientMessage> resume() {
    final allMessages = <ClientMessage>[];
    for (final value in _inflightRequests.values) {
      if (value.status.status == _Status.notSent) {
        value.status.status = _Status.requested;
        allMessages.add(value.message);
      }
    }
    return allMessages;
  }

  /// Whether any request was sent and has no result yet.
  bool hasIncompleteRequests() {
    for (final requestInfo in _inflightRequests.values) {
      if (requestInfo.status.status == _Status.requested) {
        return true;
      }
    }
    return false;
  }

  /// Whether any request is in flight, including completed mutations whose
  /// transition hasn't arrived.
  bool hasInflightRequests() => _inflightRequests.isNotEmpty;

  /// Whether every request from before the last restart has finished.
  bool hasSyncedPastLastReconnect() => _requestsOlderThanRestart.isEmpty;

  /// When the oldest unanswered request was made, if any is in flight.
  DateTime? timeOfOldestInflightRequest() {
    if (_inflightRequests.isEmpty) {
      return null;
    }
    var oldestInflightRequest = clock.now();
    for (final request in _inflightRequests.values) {
      final requestedAt = request.status.requestedAt;
      if (request.status.status != _Status.completed &&
          requestedAt != null &&
          requestedAt.isBefore(oldestInflightRequest)) {
        oldestInflightRequest = requestedAt;
      }
    }
    return oldestInflightRequest;
  }

  /// The number of mutations in flight.
  int inflightMutations() => _inflightMutationsCount;

  /// The number of actions in flight.
  int inflightActions() => _inflightActionsCount;
}
