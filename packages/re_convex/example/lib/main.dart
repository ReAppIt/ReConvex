import 'package:flutter/material.dart';
import 'package:re_convex/re_convex.dart';
import 'package:re_convex_example/convex/api.dart';
import 'package:re_convex_example/data/message_repository.dart';

/// The app's Convex client; it connects on first use.
final convex = ConvexReactClient(
  'https://happy-animal-123.convex.cloud',
  ConvexReactClientOptions(subscribeToOnline: subscribeToConnectivity()),
);

/// The app's messages, read and written through [convex].
final messages = MessageRepository(convex);

void main() => runApp(const MaterialApp(home: MessagesPage()));

/// The latest messages of the general channel.
class MessagesPage extends StatefulWidget {
  /// Creates the page.
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  static const _channel = ChannelsId('general');

  final _latest = messages.watchLatest(_channel);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: StreamBuilder(
      stream: _latest,
      builder: (context, snapshot) => snapshot.hasError
          ? Center(child: Text('${snapshot.error}'))
          : ListView(
              children: [
                for (final message in snapshot.data ?? const <MessagesDoc>[])
                  ListTile(title: Text(message.body)),
              ],
            ),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => messages.send(_channel, 'Hello'),
      child: const Icon(Icons.send),
    ),
  );
}
