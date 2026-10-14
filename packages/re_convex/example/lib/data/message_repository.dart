import 'dart:async';

import 'package:clock/clock.dart';
import 'package:re_convex/re_convex.dart';
import 'package:re_convex_example/convex/api.dart';

/// Messages of a channel, read and written through Convex.
class MessageRepository {
  /// Creates the repository over [_convex].
  MessageRepository(this._convex);

  final ConvexReactClient _convex;

  /// The latest page of [channel], updated as it changes.
  Stream<List<MessagesDoc>> watchLatest(ChannelsId channel) {
    final args = MessagesListArgs(
      channel: channel,
      paginationOpts: PaginationOptions(numItems: 20, cursor: null),
    );
    final watch = _convex.watchQuery(api.messages.list, args);
    late final void Function() unsubscribe;
    late final StreamController<List<MessagesDoc>> controller;
    void emit() {
      try {
        if (watch.localQueryResult() case (:final value)?) {
          controller.add(value.page);
        }
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    }

    controller = StreamController(
      onListen: () {
        unsubscribe = watch.onUpdate(emit);
        emit();
      },
      onCancel: () {
        unsubscribe();
        return controller.close();
      },
    );
    return controller.stream;
  }

  /// The message [id], or `null` when it doesn't exist.
  Future<MessagesDoc?> get(MessagesId id) =>
      _convex.query(api.messages.get, MessagesGetArgs(id: id));

  /// Sends [body] to [channel], showing it in the latest page right away.
  Future<MessagesId> send(ChannelsId channel, String body) => _convex.mutation(
    api.messages.send,
    MessagesSendArgs(channel: channel, body: body),
    optimisticUpdate: (store, args) => insertAtTop(
      paginatedQuery: api.messages.list,
      localQueryStore: store,
      argsToMatch: {'channel': args.channel},
      item: MessagesDoc(
        id: const MessagesId('optimistic'),
        creationTime: clock.now().millisecondsSinceEpoch.toDouble(),
        author: const UsersId('me'),
        body: args.body,
        channel: args.channel,
        content: MessagesDocContentText(text: args.body),
        tags: const [],
      ),
    ),
  );

  /// The number of messages, an int64.
  Future<int> count() =>
      _convex.query(api.messages.count, const MessagesCountArgs());
}
