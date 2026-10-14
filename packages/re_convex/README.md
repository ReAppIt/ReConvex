# re_convex

> [!NOTE]
> **AI-written, human-reviewed.** Every line of this package was written by AI
> (Claude, by Anthropic) as a port of the official
> [`convex`](https://github.com/get-convex/convex-js/tree/npm/1.46.0) client
> that React Native apps use (`convex/react`, `convex/browser` and
> `convex/values`), and the port has been fully reviewed by a human. It is not
> affiliated with Convex.

A Flutter client for [Convex](https://convex.dev): realtime queries over a
WebSocket, mutations with optimistic updates, actions, pagination and auth. It
is a file-by-file port of the TypeScript client in pure Dart, with no Rust
bridge and no native code. It keeps the upstream structure and behaviour and
swaps the JavaScript runtime for Dart libraries:

| React Native | Flutter |
|---|---|
| `WebSocket` | [`web_socket`](https://pub.dev/packages/web_socket) |
| `fetch` | [`dio`](https://pub.dev/packages/dio) |
| the `online` event | [`connectivity_plus`](https://pub.dev/packages/connectivity_plus), opt-in |
| React hooks and context | [`flutter_hooks`](https://pub.dev/packages/flutter_hooks) and an `InheritedWidget` |
| `console` | [`logging`](https://pub.dev/packages/logging) |
| `bigint`, `ArrayBuffer` | `int`, `Uint8List` |
| `npx convex codegen` | [`re_convex_generator`](https://pub.dev/packages/re_convex_generator) |

It speaks the sync protocol of `convex` 1.46.0 and identifies itself as that
client, so any Convex deployment serves it as it serves React Native apps.
Supported platforms: **iOS and Android**.

## Installation

### 1. Set up a Convex backend

Follow the [Convex quickstart](https://docs.convex.dev/quickstart) to create a
deployment. Your functions stay in TypeScript; this package is the client.

### 2. Install the Flutter packages

```bash
flutter pub add re_convex dev:re_convex_generator dev:build_runner
```

### 3. Generate the typed API

TypeScript apps import `convex/_generated/api`. Dart apps generate the same
from the function spec of your deployment. In your Convex project, save it
inside your Flutter package:

```bash
npx convex function-spec > ../my_app/convex/function_spec.json
```

List the file under `sources`, so that build_runner reads it and rebuilds when
it changes:

```yaml
# build.yaml
targets:
  $default:
    sources:
      - $package$
      - lib/**
      - convex/function_spec.json
```

Annotate a library and give it a part:

```dart
// lib/convex/api.dart
@ConvexApi('convex/function_spec.json')
library;

import 'package:re_convex/re_convex.dart';

part 'api.g.dart';
```

Then generate it, and again whenever your functions change:

```bash
dart run build_runner build
```

`api.g.dart` has a typed reference for every public query, mutation and action
(`api.messages.list`) and a Dart type for every argument object, document and
union. The [generator README](https://pub.dev/packages/re_convex_generator)
lists the type mapping.

### 4. Create the client

```dart
// lib/convex/client.dart
import 'package:re_convex/re_convex.dart';

final convex = ConvexReactClient('https://happy-animal-123.convex.cloud');
```

Use your deployment URL, the `CONVEX_URL` that `npx convex dev` prints. The
client connects on first use and reconnects by itself.

## Usage

The examples use the API of the [example app](example), whose
`convex/function_spec.json` describes a small chat backend.

### Queries, mutations and actions

```dart
// lib/data/message_repository.dart
final message = await convex.query(api.messages.get, MessagesGetArgs(id: id));

final id = await convex.mutation(
  api.messages.send,
  MessagesSendArgs(channel: channel, body: 'Hello'),
);

await convex.action(api.admin.users.sync, const <String, Object?>{});
```

`query` returns the result already in memory when there is one, and otherwise
waits for the first one.

A function that throws a `ConvexError` on the server throws a `ConvexError`
here, with the same `data`. Other failures throw an `Exception` whose message
names the function.

### Subscribing to queries

`watchQuery` returns a `Watch`. Register a callback with `onUpdate`, and read
the result with `localQueryResult()`: `null` while the query loads, then a
`(value: ...)` record, because `null` can be a result. It throws the query's
error. All watches of a query with the same arguments share one subscription.

Apps that keep Convex behind a repository can turn a watch into a `Stream`:

```dart
// lib/data/message_repository.dart
Stream<List<MessagesDoc>> watchLatest(ChannelsId channel) {
  final watch = convex.watchQuery(
    api.messages.list,
    MessagesListArgs(
      channel: channel,
      paginationOpts: PaginationOptions(numItems: 20, cursor: null),
    ),
  );
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
```

### Optimistic updates

An optimistic update changes local query results until the mutation's result
reaches them. The store is typed by the same references:

```dart
// lib/data/message_repository.dart
await convex.mutation(
  api.messages.send,
  MessagesSendArgs(channel: channel, body: body),
  optimisticUpdate: (store, args) {
    const countArgs = MessagesCountArgs();
    final count = store.getQuery(api.messages.count, countArgs);
    if (count != null) {
      store.setQuery(api.messages.count, countArgs, (value: count.value + 1));
    }
  },
);
```

`insertAtTop`, `insertAtPosition`, `insertAtBottomIfLoaded` and
`optimisticallyUpdateValueInPaginatedQuery` update paginated queries.

### Pagination

A paginated query takes `paginationOpts` and returns a `PaginationResult`:

```dart
// lib/data/message_repository.dart
Future<List<MessagesDoc>> loadAll(ChannelsId channel) async {
  final messages = <MessagesDoc>[];
  String? cursor;
  while (true) {
    final page = await convex.query(
      api.messages.list,
      MessagesListArgs(
        channel: channel,
        paginationOpts: PaginationOptions(numItems: 100, cursor: cursor),
      ),
    );
    messages.addAll(page.page);
    if (page.isDone) return messages;
    cursor = page.continueCursor;
  }
}
```

`usePaginatedQuery` keeps a growing list up to date in widgets, and
`ConvexClient.onPaginatedUpdate_experimental` does the same with callbacks.

### Authentication

Give the client a function that returns a JWT from your auth provider, or
`null` when there is none (rather than throwing). The client sends the token,
fetches a new one before it expires or when the server rejects it, and reports
whether the server accepted it:

```dart
// lib/data/auth_repository.dart
convex.setAuth(
  ({required forceRefreshToken}) =>
      authProvider.idToken(forceRefresh: forceRefreshToken),
  (isAuthenticated) => log('Convex accepted the token: $isAuthenticated'),
);

// When the user signs out:
convex.clearAuth();
```

`ConvexProviderWithAuth` does this for a widget tree and provides
`useConvexAuth()` and the `Authenticated`, `Unauthenticated`, `AuthLoading` and
`AuthRefreshing` widgets. `ConvexAuthController` is the same state machine
without widgets: it follows a `ValueListenable<ConvexAuthProviderState>` and
publishes a `ValueListenable<ConvexAuthState>`.

### Widgets and hooks

The React hooks are ported to flutter_hooks; add it to your app with
`flutter pub add flutter_hooks` to write `HookWidget`s. Put the client in the
tree with `ConvexProvider`:

```dart
// lib/main.dart
void main() => runApp(ConvexProvider(client: convex, child: const ChatApp()));
```

Then use the hooks in a `HookWidget`:

```dart
// lib/messages_page.dart
class MessagesPage extends HookWidget {
  const MessagesPage({super.key, required this.channel});

  final ChannelsId channel;

  @override
  Widget build(BuildContext context) {
    final messages = usePaginatedQuery(
      api.messages.list,
      MessagesListArgs(channel: channel),
      initialNumItems: 20,
    );
    final send = useMutation(api.messages.send);
    return Scaffold(
      body: ListView(
        children: [
          for (final message in messages.results) Text(message.body),
          if (messages.status == PaginationStatus.canLoadMore)
            TextButton(
              onPressed: () => messages.loadMore(20),
              child: const Text('Load more'),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            send(MessagesSendArgs(channel: channel, body: 'Hello')),
        child: const Icon(Icons.send),
      ),
    );
  }
}
```

`useQuery` returns `null` while loading and a `(value: ...)` record after. The
others are `useQueries`, `useAction`, `useConvex` and
`useConvexConnectionState`.

### Connection state

```dart
// lib/data/connection_repository.dart
final stop = convex.subscribeToConnectionState((state) {
  log('connected: ${state.isWebSocketConnected}');
});
```

### Reconnecting when the network returns

React Native reconnects as soon as the browser reports it is online. Pass
`subscribeToConnectivity()` to do the same through connectivity_plus, instead
of waiting out the reconnect backoff:

```dart
// lib/convex/client.dart
final convex = ConvexReactClient(
  'https://happy-animal-123.convex.cloud',
  ConvexReactClientOptions(subscribeToOnline: subscribeToConnectivity()),
);
```

### Networking on iOS

The default WebSocket is dart:io's. To go through NSURLSession, which follows
the system's VPN and proxy settings, add
[`cupertino_http`](https://pub.dev/packages/cupertino_http) and pass its
constructor (iOS 15 and later):

```dart
// lib/convex/client.dart
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';

final convex = ConvexReactClient(
  'https://happy-animal-123.convex.cloud',
  ConvexReactClientOptions(
    webSocketConstructor: Platform.isIOS ? CupertinoWebSocket.connect : null,
  ),
);
```

### Numbers

Convex has two number types, and Dart keeps them apart:

| Validator | Dart |
|---|---|
| `v.number()` (float64) | `double` |
| `v.int64()` (`bigint`) | `int` |

Every Dart `int` is sent as an int64, and every plain JSON number arrives as a
`double`, `1` included. The generated types take care of this. In an untyped
`Map<String, Object?>`, write `1.0` for a `v.number()`, or the server rejects
the value.

### Other clients

- `ConvexClient` is the WebSocket client without the React layer, from
  `convex/browser`: `onUpdate(query, args, callback)` subscribes with a
  callback.
- `ConvexHttpClient` runs queries, mutations and actions over HTTP, without a
  WebSocket.

### Logging

Logs go to the `re_convex` logger of package:logging, and `verbose: true` adds
debug logs. Pass `logger: instantiateNoopLogger()` to silence them, or your own
`ConvexLogger`.

## Differences from the JavaScript client

The API follows `convex/react` and `convex/browser` with Dart types:
`undefined` and `null` stay apart through `({T value})?` records, times are
`Duration`s, and option objects are named parameters. Web is not supported,
because a web `int` holds only 53 bits. [PORTING.md](PORTING.md) maps every file
to its upstream source and lists every deviation.

## License

MIT. The ported code keeps the Apache-2.0 notice of the Convex client and
Brian Vaughn's MIT notice for `use_subscription`; see [LICENSE](LICENSE).
