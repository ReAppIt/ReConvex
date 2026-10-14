// The tests call the generated decoders, which clients run internally.
// ignore_for_file: invalid_use_of_internal_member
import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/re_convex.dart';
import 'package:re_convex_example/convex/api.dart';

void main() {
  test('references carry the function names', () {
    expect(getFunctionName(api.messages.list), 'messages:list');
    expect(getFunctionName(api.channels.default_), 'channels');
    expect(getFunctionName(api.admin.users.sync), 'admin/users:sync');
    expect(getFunctionName(api.misc.new_), 'misc:new');
  });

  test('constructors build the raw arguments', () {
    final args = MessagesSendArgs(
      channel: const ChannelsId('c1'),
      body: 'hi',
      status: MessagesDocStatus.sent,
      content: MessagesDocContentImage(url: 'u'),
    );
    expect(convexToJson(args.json), {
      'body': 'hi',
      'channel': 'c1',
      'content': {'kind': 'image', 'url': 'u'},
      'status': 'sent',
    });
    expect(UsersUpdateProfileArgs(nickname: (value: null)).json, {
      'nickname': null,
    });
    expect(UsersUpdateProfileArgs().json, isEmpty);
  });

  test('getters read raw results without copying', () {
    final raw = jsonToConvex({
      '_creationTime': 1,
      '_id': 'm1',
      'author': 'u1',
      'body': 'hi',
      'channel': 'c1',
      'content': {'kind': 'text', 'text': 'hi'},
      'status': 'archived',
      'tags': ['a'],
      'reactions': {
        'like': {r'$integer': 'AgAAAAAAAAA='},
      },
    });
    final doc = api.messages.get.decodeResult(raw)!;
    expect(doc.id, 'm1');
    expect(doc.creationTime, 1.0);
    expect(doc.tags, ['a']);
    expect(doc.reactions, {'like': 2});
    expect(doc.content.asText?.text, 'hi');
    expect(doc.content.asImage, isNull);
    // A literal the app doesn't know yet still reads.
    expect(doc.status, 'archived');
    expect(MessagesDocStatus.values, contains(MessagesDocStatus.sent));
  });

  test('lists and pages decode lazily', () {
    final channels = api.channels.default_.decodeResult(
      jsonToConvex([
        {'_creationTime': 1, '_id': 'c1', 'name': 'general'},
      ]),
    );
    expect(channels.single.name, 'general');
    expect(
      api.matrix.get.decodeResult(
        jsonToConvex([
          [1, 2],
          [3],
        ]),
      ),
      [
        [1.0, 2.0],
        [3.0],
      ],
    );
    final page = api.messages.list.decodeResult(
      jsonToConvex({
        'page': <Object?>[],
        'isDone': true,
        'continueCursor': 'c',
      }),
    );
    expect(page.isDone, isTrue);
  });
}
