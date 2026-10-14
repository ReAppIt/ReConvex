// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api.dart';

// **************************************************************************
// ConvexApiGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
// generated_from: convex/function_spec.json

/// The functions of the Convex deployment, like `api` from
/// `convex/_generated/api`.
const api = _$Api();

final class _$Api {
  const _$Api();

  /// The `admin` functions.
  _$ApiAdmin get admin => const _$ApiAdmin();

  /// The `channels` functions.
  _$ApiChannels get channels => const _$ApiChannels();

  /// The `matrix` functions.
  _$ApiMatrix get matrix => const _$ApiMatrix();

  /// The `messages` functions.
  _$ApiMessages get messages => const _$ApiMessages();

  /// The `misc` functions.
  _$ApiMisc get misc => const _$ApiMisc();

  /// The `users` functions.
  _$ApiUsers get users => const _$ApiUsers();
}

final class _$ApiAdmin {
  const _$ApiAdmin();

  /// The `admin/users` functions.
  _$ApiAdminUsers get users => const _$ApiAdminUsers();
}

final class _$ApiAdminUsers {
  const _$ApiAdminUsers();

  /// `admin/users:sync` (action).
  FunctionReference<ActionType, Map<String, Object?>, Object?> get sync =>
      const FunctionReference<ActionType, Map<String, Object?>, Object?>(
        'admin/users:sync',
      );
}

final class _$ApiChannels {
  const _$ApiChannels();

  /// `channels` (query).
  FunctionReference<QueryType, ChannelsDefaultArgs, List<ChannelsDoc>>
  get default_ =>
      const FunctionReference<
        QueryType,
        ChannelsDefaultArgs,
        List<ChannelsDoc>
      >('channels', decode: _$decodeChannelsDefaultResult);
}

final class _$ApiMatrix {
  const _$ApiMatrix();

  /// `matrix:get` (query).
  FunctionReference<QueryType, MatrixGetArgs, List<List<double>>> get get =>
      const FunctionReference<QueryType, MatrixGetArgs, List<List<double>>>(
        'matrix:get',
        decode: _$decodeMatrixGetResult,
      );
}

final class _$ApiMessages {
  const _$ApiMessages();

  /// `messages:count` (query).
  FunctionReference<QueryType, MessagesCountArgs, int> get count =>
      const FunctionReference<QueryType, MessagesCountArgs, int>(
        'messages:count',
      );

  /// `messages:get` (query).
  FunctionReference<QueryType, MessagesGetArgs, MessagesDoc?> get get =>
      const FunctionReference<QueryType, MessagesGetArgs, MessagesDoc?>(
        'messages:get',
      );

  /// `messages:list` (query).
  FunctionReference<QueryType, MessagesListArgs, PaginationResult<MessagesDoc>>
  get list =>
      const FunctionReference<
        QueryType,
        MessagesListArgs,
        PaginationResult<MessagesDoc>
      >('messages:list');

  /// `messages:send` (mutation).
  FunctionReference<MutationType, MessagesSendArgs, MessagesId> get send =>
      const FunctionReference<MutationType, MessagesSendArgs, MessagesId>(
        'messages:send',
      );
}

final class _$ApiMisc {
  const _$ApiMisc();

  /// `misc:new` (mutation).
  FunctionReference<MutationType, MiscNewArgs, String> get new_ =>
      const FunctionReference<MutationType, MiscNewArgs, String>('misc:new');
}

final class _$ApiUsers {
  const _$ApiUsers();

  /// `users:me` (query).
  FunctionReference<QueryType, UsersMeArgs, UsersDoc?> get me =>
      const FunctionReference<QueryType, UsersMeArgs, UsersDoc?>('users:me');

  /// `users:updateProfile` (mutation).
  FunctionReference<MutationType, UsersUpdateProfileArgs, Null>
  get updateProfile =>
      const FunctionReference<MutationType, UsersUpdateProfileArgs, Null>(
        'users:updateProfile',
      );
}

List<ChannelsDoc> _$decodeChannelsDefaultResult(Object? value) =>
    (value as List<Object?>).cast<ChannelsDoc>();

List<List<double>> _$decodeMatrixGetResult(Object? value) => <List<double>>[
  for (final e0 in value as List<Object?>) (e0 as List<Object?>).cast<double>(),
];

extension type ChannelsDefaultArgs.fromValue(Map<String, Object?> json) {
  const ChannelsDefaultArgs() : json = const <String, Object?>{};

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

/// An id in the `channels` table.
extension type const ChannelsId(String id) implements GenericId {}

extension type ChannelsDoc.fromValue(Map<String, Object?> json) {
  ChannelsDoc({
    required double creationTime,
    required ChannelsId id,
    required String name,
  }) : json = <String, Object?>{
         '_creationTime': creationTime,
         '_id': id,
         'name': name,
       };

  double get creationTime => json['_creationTime'] as double;

  ChannelsId get id => json['_id'] as ChannelsId;

  String get name => json['name'] as String;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MatrixGetArgs.fromValue(Map<String, Object?> json) {
  MatrixGetArgs({required int size}) : json = <String, Object?>{'size': size};

  int get size => json['size'] as int;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MessagesCountArgs.fromValue(Map<String, Object?> json) {
  const MessagesCountArgs() : json = const <String, Object?>{};

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

/// An id in the `messages` table.
extension type const MessagesId(String id) implements GenericId {}

extension type MessagesGetArgs.fromValue(Map<String, Object?> json) {
  MessagesGetArgs({required MessagesId id})
    : json = <String, Object?>{'id': id};

  MessagesId get id => json['id'] as MessagesId;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

/// An id in the `users` table.
extension type const UsersId(String id) implements GenericId {}

extension type MessagesDocContent.fromValue(Map<String, Object?> json) {
  /// The `kind` that tells the variants apart.
  String get kind => json['kind'] as String;

  /// This value as a `text` variant, or `null`.
  MessagesDocContentText? get asText =>
      json['kind'] == 'text' ? MessagesDocContentText.fromValue(json) : null;

  /// This value as a `image` variant, or `null`.
  MessagesDocContentImage? get asImage =>
      json['kind'] == 'image' ? MessagesDocContentImage.fromValue(json) : null;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MessagesDocContentText.fromValue(Map<String, Object?> json)
    implements MessagesDocContent {
  MessagesDocContentText({required String text})
    : json = <String, Object?>{'kind': 'text', 'text': text};

  String get kind => json['kind'] as String;

  String get text => json['text'] as String;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MessagesDocContentImage.fromValue(Map<String, Object?> json)
    implements MessagesDocContent {
  MessagesDocContentImage({required String url, double? width})
    : json = <String, Object?>{
        'kind': 'image',
        'url': url,
        if (width != null) 'width': width,
      };

  String get kind => json['kind'] as String;

  String get url => json['url'] as String;

  double? get width => json['width'] as double?;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type const MessagesDocStatus._(String value) implements String {
  static const sent = MessagesDocStatus._('sent');
  static const read = MessagesDocStatus._('read');

  /// The values this version of the API knows.
  static const values = <MessagesDocStatus>[sent, read];
}

extension type MessagesDoc.fromValue(Map<String, Object?> json) {
  MessagesDoc({
    required double creationTime,
    required MessagesId id,
    required UsersId author,
    required String body,
    required ChannelsId channel,
    required MessagesDocContent content,
    Map<String, int>? reactions,
    MessagesDocStatus? status,
    required List<String> tags,
  }) : json = <String, Object?>{
         '_creationTime': creationTime,
         '_id': id,
         'author': author,
         'body': body,
         'channel': channel,
         'content': content,
         if (reactions != null) 'reactions': reactions,
         if (status != null) 'status': status,
         'tags': tags,
       };

  double get creationTime => json['_creationTime'] as double;

  MessagesId get id => json['_id'] as MessagesId;

  UsersId get author => json['author'] as UsersId;

  String get body => json['body'] as String;

  ChannelsId get channel => json['channel'] as ChannelsId;

  MessagesDocContent get content => json['content'] as MessagesDocContent;

  Map<String, int>? get reactions => (json['reactions'] == null
      ? null
      : (json['reactions'] as Map<String, Object?>).cast<String, int>());

  MessagesDocStatus? get status => json['status'] as MessagesDocStatus?;

  List<String> get tags => (json['tags'] as List<Object?>).cast<String>();

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MessagesListArgs.fromValue(Map<String, Object?> json) {
  MessagesListArgs({
    required ChannelsId channel,
    PaginationOptions? paginationOpts,
  }) : json = <String, Object?>{
         'channel': channel,
         if (paginationOpts != null) 'paginationOpts': paginationOpts,
       };

  ChannelsId get channel => json['channel'] as ChannelsId;

  PaginationOptions? get paginationOpts =>
      json['paginationOpts'] as PaginationOptions?;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MessagesSendArgs.fromValue(Map<String, Object?> json) {
  MessagesSendArgs({
    required String body,
    required ChannelsId channel,
    MessagesDocContent? content,
    MessagesDocStatus? status,
  }) : json = <String, Object?>{
         'body': body,
         'channel': channel,
         if (content != null) 'content': content,
         if (status != null) 'status': status,
       };

  String get body => json['body'] as String;

  ChannelsId get channel => json['channel'] as ChannelsId;

  MessagesDocContent? get content => json['content'] as MessagesDocContent?;

  MessagesDocStatus? get status => json['status'] as MessagesDocStatus?;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type MiscNewArgs.fromValue(Map<String, Object?> json) {
  MiscNewArgs({required double priority})
    : json = <String, Object?>{'priority': priority};

  double get priority => json['priority'] as double;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type UsersMeArgs.fromValue(Map<String, Object?> json) {
  const UsersMeArgs() : json = const <String, Object?>{};

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type const UsersDocRole._(String value) implements String {
  static const admin = UsersDocRole._('admin');
  static const member = UsersDocRole._('member');

  /// The values this version of the API knows.
  static const values = <UsersDocRole>[admin, member];
}

extension type UsersDocStats.fromValue(Map<String, Object?> json) {
  UsersDocStats({required int likes, required double posts})
    : json = <String, Object?>{'likes': likes, 'posts': posts};

  int get likes => json['likes'] as int;

  double get posts => json['posts'] as double;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type UsersDoc.fromValue(Map<String, Object?> json) {
  UsersDoc({
    required double creationTime,
    required UsersId id,
    Uint8List? avatar,
    String? email,
    required String name,
    ({String? value})? nickname,
    required UsersDocRole role,
    required UsersDocStats stats,
  }) : json = <String, Object?>{
         '_creationTime': creationTime,
         '_id': id,
         if (avatar != null) 'avatar': avatar,
         if (email != null) 'email': email,
         'name': name,
         if (nickname != null) 'nickname': nickname.value,
         'role': role,
         'stats': stats,
       };

  double get creationTime => json['_creationTime'] as double;

  UsersId get id => json['_id'] as UsersId;

  Uint8List? get avatar => json['avatar'] as Uint8List?;

  String? get email => json['email'] as String?;

  String get name => json['name'] as String;

  ({String? value})? get nickname => json.containsKey('nickname')
      ? (value: json['nickname'] as String?)
      : null;

  UsersDocRole get role => json['role'] as UsersDocRole;

  UsersDocStats get stats => json['stats'] as UsersDocStats;

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}

extension type UsersUpdateProfileArgs.fromValue(Map<String, Object?> json) {
  UsersUpdateProfileArgs({
    String? name,
    ({String? value})? nickname,
    Map<String, Object?>? settings,
  }) : json = <String, Object?>{
         if (name != null) 'name': name,
         if (nickname != null) 'nickname': nickname.value,
         if (settings != null) 'settings': settings,
       };

  String? get name => json['name'] as String?;

  ({String? value})? get nickname => json.containsKey('nickname')
      ? (value: json['nickname'] as String?)
      : null;

  Map<String, Object?>? get settings => (json['settings'] == null
      ? null
      : (json['settings'] as Map<String, Object?>).cast<String, Object?>());

  /// Any field of the raw object.
  Object? operator [](String key) => json[key];
}
