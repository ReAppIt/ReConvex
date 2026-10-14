import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/server/api.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/long.dart';
import 'package:web_socket/web_socket.dart';

/// A query reference by name, like `anyApi.module.fn` upstream.
FunctionReference<QueryType, Map<String, Value>, Value> anyQuery(String name) =>
    makeFunctionReference(name);

/// A mutation reference by name.
FunctionReference<MutationType, Map<String, Value>, Value> anyMutation(
  String name,
) => makeFunctionReference(name);

/// An action reference by name.
FunctionReference<ActionType, Map<String, Value>, Value> anyAction(
  String name,
) => makeFunctionReference(name);

/// The JSON of a state version at the timestamp [ts].
JsonMap stateVersion({int querySet = 0, required int ts, int identity = 0}) =>
    StateVersion(
      querySet: querySet,
      ts: Long.fromNumber(ts),
      identity: identity,
    ).json;

/// A `Transition` server message.
Transition transition({
  required JsonMap startVersion,
  required JsonMap endVersion,
  List<JsonMap> modifications = const [],
}) => Transition({
  'type': 'Transition',
  'startVersion': startVersion,
  'endVersion': endVersion,
  'modifications': modifications,
});

/// A successful `MutationResponse` committed at [ts].
JsonMap mutationSuccess(int requestId, {Object? result, int ts = 0}) => {
  'type': 'MutationResponse',
  'requestId': requestId,
  'success': true,
  'result': result,
  'ts': longToU64(Long.fromNumber(ts)),
  'logLines': <String>[],
};

/// The arguments of a function that takes none.
const Map<String, Value> noArgs = {};

/// The JSON of an empty transition from timestamp 0 to 1.
JsonMap transitionJson() => transition(
  startVersion: stateVersion(ts: 0),
  endVersion: stateVersion(ts: 1),
).json;

/// A WebSocket that can never connect, for clients that must stay offline.
Future<WebSocket> offlineWebSocketConstructor(Uri uri) =>
    Future.error(WebSocketException('offline'));
