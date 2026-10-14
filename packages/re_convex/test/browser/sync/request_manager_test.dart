import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/browser/sync/request_manager.dart';
import 'package:re_convex/src/vendor/long.dart';

import '../../support/fakes.dart';

Matcher _success(Object? value) => isA<FunctionSuccess>()
    .having((r) => r.value, 'value', value)
    .having((r) => r.logLines, 'logLines', isEmpty);

Matcher _failure(String errorMessage) => isA<FunctionFailure>()
    .having((r) => r.errorMessage, 'errorMessage', errorMessage)
    .having((r) => r.errorData, 'errorData', isNull)
    .having((r) => r.logLines, 'logLines', isEmpty);

void main() {
  late RequestManager requestManager;
  late int markConnectionStateDirtyCalls;

  setUp(() {
    markConnectionStateDirtyCalls = 0;
    requestManager = RequestManager(
      instantiateDefaultLogger(verbose: false),
      () => markConnectionStateDirtyCalls++,
    );
  });

  MutationRequest mutation(int requestId, [String udfPath = 'myMutation']) =>
      MutationRequest(requestId: requestId, udfPath: udfPath, args: []);

  ActionRequest action(int requestId, String udfPath) =>
      ActionRequest(requestId: requestId, udfPath: udfPath, args: []);

  test('hasIncompleteRequests', () {
    // Starts false.
    expect(requestManager.hasIncompleteRequests(), isFalse);

    // When we request a mutation it becomes true.
    requestManager.request(mutation(0), sent: true).ignore();
    expect(requestManager.hasIncompleteRequests(), isTrue);

    // A second mutation and the first response: one is still outstanding.
    requestManager.request(mutation(1), sent: true).ignore();
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));
    expect(requestManager.hasIncompleteRequests(), isTrue);

    // When the second response comes back we no longer have any outstanding mutations.
    requestManager.onResponse(ServerMessage(mutationSuccess(1)));
    expect(requestManager.hasIncompleteRequests(), isFalse);
  });

  // Simulates a WebSocket disconnection half-way through the mutation flow.
  test('mutation retries', () async {
    // Request a mutation.
    final message = mutation(0);
    final mutationRequest = requestManager.request(message, sent: true);

    // Receive the response.
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));
    expect(requestManager.hasSyncedPastLastReconnect(), isTrue);

    // Reconnecting re-requests it: no transition past its commit timestamp.
    expect(requestManager.restart(), [message]);
    expect(requestManager.hasSyncedPastLastReconnect(), isFalse);

    // Receive another response (because we restarted and requested it again)
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));

    // Transition to ts=1
    requestManager.removeCompleted(Long.fromNumber(1));
    expect(requestManager.hasSyncedPastLastReconnect(), isTrue);

    // Resolved now that we've transitioned past the mutation timestamp.
    expect(await mutationRequest, _success(null));

    // The if we restart now, the mutation should no longer be re-requested.
    expect(requestManager.restart(), isEmpty);
  });

  // This time the reconnect transitions past the mutation right away.
  test('mutation retries with transition', () async {
    // Request a mutation.
    final message = mutation(0);
    final mutationRequest = requestManager.request(message, sent: true);

    // Receive the response.
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));
    expect(requestManager.hasSyncedPastLastReconnect(), isTrue);

    // Pretend that we become disconnected and reconnect.
    expect(requestManager.restart(), [message]);
    expect(requestManager.hasSyncedPastLastReconnect(), isFalse);

    // Transition to ts=1
    requestManager.removeCompleted(Long.fromNumber(1));
    expect(requestManager.hasSyncedPastLastReconnect(), isTrue);

    expect(await mutationRequest, _success(null));

    // Restarting no longer re-requests it: we've observed it.
    expect(requestManager.restart(), isEmpty);
    expect(requestManager.hasSyncedPastLastReconnect(), isTrue);

    // The extra response to the re-request must not crash the client.
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));
  });

  // Makes sure an action in flight during a disconnection is not retried.
  test('actions are retried only if unsent', () async {
    final message1 = action(0, 'myAction1');
    final actionRequest1 = requestManager.request(message1, sent: true);
    final message2 = action(1, 'myAction2');
    final actionRequest2 = requestManager.request(message2, sent: false);

    // Reconnecting resends only message2.
    expect(requestManager.restart(), [message2]);

    // The sent action promise should resolve with an error.
    expect(
      await actionRequest1,
      _failure('Connection lost while action was in flight'),
    );

    // Reconnecting again retries nothing, and the second request fails.
    expect(requestManager.restart(), isEmpty);
    expect(
      await actionRequest2,
      _failure('Connection lost while action was in flight'),
    );
  });

  test('markConnectionStateDirty is called on state changes', () {
    expect(markConnectionStateDirtyCalls, 0);

    // Adding a request should trigger the callback
    requestManager.request(mutation(0), sent: true).ignore();
    expect(markConnectionStateDirtyCalls, 1);

    // Response for actions triggers callback immediately, but mutations need to complete
    requestManager.request(action(1, 'myAction'), sent: true).ignore();
    expect(markConnectionStateDirtyCalls, 2);

    // Action response should trigger callback
    requestManager.onResponse(
      ServerMessage({
        'type': 'ActionResponse',
        'requestId': 1,
        'success': true,
        'result': null,
        'logLines': <String>[],
      }),
    );
    expect(markConnectionStateDirtyCalls, 3);

    // First make a mutation response that gets completed
    requestManager.onResponse(ServerMessage(mutationSuccess(0)));

    // removeCompleted should trigger the callback when mutations complete
    markConnectionStateDirtyCalls = 0;
    final completedRequests = requestManager.removeCompleted(
      Long.fromNumber(1),
    );
    expect(completedRequests, hasLength(1));
    expect(markConnectionStateDirtyCalls, 1);

    // restart should trigger the callback
    markConnectionStateDirtyCalls = 0;
    requestManager.restart();
    expect(markConnectionStateDirtyCalls, 1);
  });
}
