// Ported from convex/src/browser/sync/protocol.ts (Apache-2.0); modified for Dart.
import 'dart:typed_data';

import 'package:re_convex/src/server/authentication.dart';
import 'package:re_convex/src/values/base64.dart';
import 'package:re_convex/src/values/value.dart';
import 'package:re_convex/src/vendor/long.dart';

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// Decodes a u64 sent as 8 little-endian bytes in base64.
Long u64ToLong(String encoded) => Long.fromBytesLE(Base64.toByteArray(encoded));

/// Encodes a u64 as 8 little-endian bytes in base64.
String longToU64(Long raw) =>
    Base64.fromByteArray(Uint8List.fromList(raw.toBytesLE()));

/// Views [encoded] as a server message; throws on an unknown `type`.
WireServerMessage parseServerMessage(JsonMap encoded) {
  switch (encoded['type']) {
    case 'FatalError':
    case 'AuthError':
    case 'ActionResponse':
    case 'TransitionChunk':
    case 'Ping':
    case 'MutationResponse':
    case 'Transition':
      return WireServerMessage(encoded);
    default:
      throw FormatException('Unknown server message type ${encoded['type']}');
  }
}

/// The JSON object to send for [message].
JsonMap encodeClientMessage(ClientMessage message) => message.json;

/// Unique nonnegative integer identifying a single query.
typedef QueryId = int;

/// The version of the query set the server has applied.
typedef QuerySetVersion = int;

/// Unique nonnegative integer identifying a mutation or action request.
typedef RequestId = int;

/// The version of the identity the server has applied.
typedef IdentityVersion = int;

/// A serialized record of decisions made while a query executed, reused
/// when it re-executes; `null` is the empty journal.
///
/// Pagination stores its end cursors here, which makes pages gapless.
typedef QueryJournal = String?;

/// A server timestamp.
typedef TS = Long;

/// Log lines a function printed.
typedef LogLines = List<String>;

// Client message schema

/// A message from the client to the server.
extension type ClientMessage(JsonMap json) {
  /// The message type, like `Connect` or `ModifyQuerySet`.
  String get type => json['type']! as String;
}

/// The first message on every WebSocket connection.
extension type Connect._(JsonMap json) implements ClientMessage {
  /// Creates the message.
  Connect({
    required String sessionId,
    required int connectionCount,
    required String? lastCloseReason,
    required int clientTs,
    TS? maxObservedTimestamp,
  }) : json = {
         'type': 'Connect',
         'sessionId': sessionId,
         'connectionCount': connectionCount,
         'lastCloseReason': lastCloseReason,
         if (maxObservedTimestamp != null)
           'maxObservedTimestamp': longToU64(maxObservedTimestamp),
         'clientTs': clientTs,
       };

  /// The client session this connection belongs to.
  String get sessionId => json['sessionId']! as String;

  /// How many connections this session opened before.
  int get connectionCount => json['connectionCount']! as int;

  /// Why the previous connection closed.
  String? get lastCloseReason => json['lastCloseReason'] as String?;

  /// The newest timestamp the client has observed.
  TS? get maxObservedTimestamp => switch (json['maxObservedTimestamp']) {
    final String encoded => u64ToLong(encoded),
    _ => null,
  };

  /// The client clock, in milliseconds since the epoch.
  int get clientTs => json['clientTs']! as int;
}

/// Adds a query to the query set.
extension type AddQuery._(JsonMap json) implements ClientMessage {
  /// Creates the modification; a `null` [journal] record leaves it out.
  AddQuery({
    required QueryId queryId,
    required String udfPath,
    required List<JSONValue> args,
    ({QueryJournal value})? journal,
    String? componentPath,
  }) : json = {
         'type': 'Add',
         'queryId': queryId,
         'udfPath': udfPath,
         'args': args,
         if (journal != null) 'journal': journal.value,
         'componentPath': ?componentPath,
       };

  /// The query's id.
  QueryId get queryId => json['queryId']! as int;

  /// The canonical function path.
  String get udfPath => json['udfPath']! as String;

  /// The arguments, as a one-element list of JSON.
  List<JSONValue> get args => json['args']! as List<Object?>;

  /// The journal from a previous run, if any.
  QueryJournal get journal => json['journal'] as String?;
}

/// Removes a query from the query set.
extension type RemoveQuery._(JsonMap json) implements ClientMessage {
  /// Creates the modification.
  RemoveQuery({required QueryId queryId})
    : json = {'type': 'Remove', 'queryId': queryId};

  /// The query's id.
  QueryId get queryId => json['queryId']! as int;
}

/// Changes the set of queries the client subscribes to.
extension type QuerySetModification._(JsonMap json) implements ClientMessage {
  /// Creates the message.
  QuerySetModification({
    required QuerySetVersion baseVersion,
    required QuerySetVersion newVersion,
    required List<ClientMessage> modifications,
  }) : json = {
         'type': 'ModifyQuerySet',
         'baseVersion': baseVersion,
         'newVersion': newVersion,
         'modifications': modifications,
       };

  /// The version this modification applies to.
  QuerySetVersion get baseVersion => json['baseVersion']! as int;

  /// The version after this modification.
  QuerySetVersion get newVersion => json['newVersion']! as int;

  /// The [AddQuery] and [RemoveQuery] modifications.
  List<ClientMessage> get modifications =>
      (json['modifications']! as List<Object?>).cast<ClientMessage>();
}

/// Runs a mutation.
extension type MutationRequest._(JsonMap json) implements ClientMessage {
  /// Creates the message.
  MutationRequest({
    required RequestId requestId,
    required String udfPath,
    required List<JSONValue> args,
    String? componentPath,
  }) : json = {
         'type': 'Mutation',
         'requestId': requestId,
         'udfPath': udfPath,
         'args': args,
         'componentPath': ?componentPath,
       };

  /// The request's id.
  RequestId get requestId => json['requestId']! as int;

  /// The function path.
  String get udfPath => json['udfPath']! as String;

  /// The arguments, as a one-element list of JSON.
  List<JSONValue> get args => json['args']! as List<Object?>;
}

/// Runs an action.
extension type ActionRequest._(JsonMap json) implements ClientMessage {
  /// Creates the message.
  ActionRequest({
    required RequestId requestId,
    required String udfPath,
    required List<JSONValue> args,
    String? componentPath,
  }) : json = {
         'type': 'Action',
         'requestId': requestId,
         'udfPath': udfPath,
         'args': args,
         'componentPath': ?componentPath,
       };

  /// The request's id.
  RequestId get requestId => json['requestId']! as int;

  /// The function path.
  String get udfPath => json['udfPath']! as String;

  /// The arguments, as a one-element list of JSON.
  List<JSONValue> get args => json['args']! as List<Object?>;
}

/// Sets or clears the identity of the connection.
extension type Authenticate._(JsonMap json) implements ClientMessage {
  /// Authenticates as a user with the JWT [value].
  Authenticate.user({
    required String value,
    required IdentityVersion baseVersion,
  }) : json = {
         'type': 'Authenticate',
         'tokenType': 'User',
         'value': value,
         'baseVersion': baseVersion,
       };

  /// Authenticates with an admin key, optionally [impersonating] a user.
  Authenticate.admin({
    required String value,
    required IdentityVersion baseVersion,
    UserIdentityAttributes? impersonating,
  }) : json = {
         'type': 'Authenticate',
         'tokenType': 'Admin',
         'value': value,
         'baseVersion': baseVersion,
         'impersonating': ?impersonating,
       };

  /// Clears the identity.
  Authenticate.none({required IdentityVersion baseVersion})
    : json = {
        'type': 'Authenticate',
        'tokenType': 'None',
        'baseVersion': baseVersion,
      };

  /// `User`, `Admin` or `None`.
  String get tokenType => json['tokenType']! as String;

  /// The token, unless [tokenType] is `None`.
  String? get value => json['value'] as String?;

  /// The identity version this message applies to.
  IdentityVersion get baseVersion => json['baseVersion']! as int;
}

/// A client analytics event.
extension type Event._(JsonMap json) implements ClientMessage {
  /// Creates the message.
  Event({required String eventType, required Object? event})
    : json = {'type': 'Event', 'eventType': eventType, 'event': event};

  /// The kind of event.
  String get eventType => json['eventType']! as String;

  /// The event payload.
  Object? get event => json['event'];
}

// Server message schema

/// The state a transition starts or ends at.
extension type StateVersion._(JsonMap json) {
  /// Creates a version.
  StateVersion({
    required QuerySetVersion querySet,
    required TS ts,
    required IdentityVersion identity,
  }) : json = {'querySet': querySet, 'ts': longToU64(ts), 'identity': identity};

  /// Views a decoded version.
  StateVersion.fromJson(this.json);

  /// The query set version.
  QuerySetVersion get querySet => json['querySet']! as int;

  /// The server timestamp.
  TS get ts => u64ToLong(json['ts']! as String);

  /// The identity version.
  IdentityVersion get identity => json['identity']! as int;
}

/// A change to one query's result inside a [Transition].
extension type StateModification(JsonMap json) {
  /// `QueryUpdated`, `QueryFailed` or `QueryRemoved`.
  String get type => json['type']! as String;

  /// The query that changed.
  QueryId get queryId => json['queryId']! as int;

  /// The new result of a `QueryUpdated`.
  JSONValue get value => json['value'];

  /// Log lines of the query run.
  LogLines get logLines =>
      (json['logLines'] as List<Object?>? ?? const []).cast<String>();

  /// Whether the server sent a journal.
  bool get hasJournal => json.containsKey('journal');

  /// The journal of the run.
  QueryJournal get journal => json['journal'] as String?;

  /// The error of a `QueryFailed`.
  String get errorMessage => json['errorMessage']! as String;

  /// Whether a `QueryFailed` carries `ConvexError` data.
  bool get hasErrorData => json.containsKey('errorData');

  /// The `ConvexError` data of a `QueryFailed`.
  JSONValue get errorData => json['errorData'];
}

/// A message from the server to the client, including protocol-only ones.
extension type WireServerMessage(JsonMap json) {
  /// The message type, like `Transition` or `Ping`.
  String get type => json['type']! as String;
}

/// A server message the client acts on.
extension type ServerMessage(JsonMap json) implements WireServerMessage {}

/// Moves the client's query results from one [StateVersion] to the next.
extension type Transition(JsonMap json) implements ServerMessage {
  /// The version this transition starts from.
  StateVersion get startVersion =>
      StateVersion.fromJson(json['startVersion']! as JsonMap);

  /// The version this transition ends at.
  StateVersion get endVersion =>
      StateVersion.fromJson(json['endVersion']! as JsonMap);

  /// The query results that changed.
  List<StateModification> get modifications =>
      (json['modifications']! as List<Object?>).cast<StateModification>();

  /// The difference between the client and server clocks, in milliseconds.
  num? get clientClockSkew => json['clientClockSkew'] as num?;

  /// When the server sent this, in nanoseconds since the epoch.
  num? get serverTs => json['serverTs'] as num?;
}

/// One part of a [Transition] too large for a single message.
extension type TransitionChunk(JsonMap json) implements WireServerMessage {
  /// This part's JSON text.
  String get chunk => json['chunk']! as String;

  /// The index of this part.
  int get partNumber => json['partNumber']! as int;

  /// How many parts the transition has.
  int get totalParts => json['totalParts']! as int;

  /// The id shared by every part of one transition.
  String get transitionId => json['transitionId']! as String;
}

/// The result of a [MutationRequest].
extension type MutationResponse(JsonMap json) implements ServerMessage {
  /// The request this answers.
  RequestId get requestId => json['requestId']! as int;

  /// Whether the mutation succeeded.
  bool get success => json['success']! as bool;

  /// The returned value, or the error message on failure.
  JSONValue get result => json['result'];

  /// When the mutation committed; only on success.
  TS get ts => u64ToLong(json['ts']! as String);

  /// Log lines of the mutation.
  LogLines get logLines =>
      (json['logLines'] as List<Object?>? ?? const []).cast<String>();

  /// Whether a failure carries `ConvexError` data.
  bool get hasErrorData => json.containsKey('errorData');

  /// The `ConvexError` data of a failure.
  JSONValue get errorData => json['errorData'];
}

/// The result of an [ActionRequest].
extension type ActionResponse(JsonMap json) implements ServerMessage {
  /// The request this answers.
  RequestId get requestId => json['requestId']! as int;

  /// Whether the action succeeded.
  bool get success => json['success']! as bool;

  /// The returned value, or the error message on failure.
  JSONValue get result => json['result'];

  /// Log lines of the action.
  LogLines get logLines =>
      (json['logLines'] as List<Object?>? ?? const []).cast<String>();

  /// Whether a failure carries `ConvexError` data.
  bool get hasErrorData => json.containsKey('errorData');

  /// The `ConvexError` data of a failure.
  JSONValue get errorData => json['errorData'];
}

/// The server rejected the client's identity.
extension type AuthError(JsonMap json) implements ServerMessage {
  /// Why the identity was rejected.
  String get error => json['error']! as String;

  /// The identity version that failed.
  IdentityVersion get baseVersion => json['baseVersion']! as int;

  /// Whether this answers a new `Authenticate` rather than an expired token.
  bool get authUpdateAttempted => json['authUpdateAttempted'] == true;
}

/// An error that ends the connection.
extension type FatalError(JsonMap json) implements ServerMessage {
  /// The error.
  String get error => json['error']! as String;
}

/// A keepalive from the server.
extension type Ping(JsonMap json) implements WireServerMessage {}
