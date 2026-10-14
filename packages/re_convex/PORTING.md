# Porting notes

`re_convex` is a port, so reviewing it means comparing each Dart file with its
upstream source. This file is the map.

## Upstream pins

| Project | Version | Source |
|---|---|---|
| `convex` | 1.46.0 | [`src`](https://github.com/get-convex/convex-js/tree/npm/1.46.0/src) |
| `convex` tests | `d06849d16e` | the last public commit with the client tests; the 1.46.0 tag has none |

`lib/src/index.dart` keeps upstream's `version`, 1.46.0. The client sends it
in the sync path (`/api/1.46.0/sync`) and the `Convex-Client: npm-1.46.0`
header, and the server checks it. The package's own version is
`packageVersion` in `lib/src/version.dart`.

## File map

Paths are under `lib/src/` and upstream `src/`; `react/` becomes `flutter/`.

| Dart | Upstream |
|---|---|
| `index.dart` | `index.ts` |
| `version.dart` | new: this package's version |
| `convex_api.dart` | new: the `@ConvexApi` annotation that re_convex_generator reads |
| `browser/http_client.dart` | `browser/http_client.ts` |
| `browser/logging.dart` | `browser/logging.ts` |
| `browser/query_options.dart` | `browser/query_options.ts` |
| `browser/simple_client.dart` | `browser/simple_client.ts` |
| `browser/sync/authentication_manager.dart` | `browser/sync/authentication_manager.ts` |
| `browser/sync/client.dart` | `browser/sync/client.ts` |
| `browser/sync/dom_web_socket.dart` | new: the browser `WebSocket` API over package:web_socket |
| `browser/sync/function_result.dart` | `browser/sync/function_result.ts` |
| `browser/sync/local_state.dart` | `browser/sync/local_state.ts` |
| `browser/sync/metrics.dart` | `browser/sync/metrics.ts` |
| `browser/sync/optimistic_updates.dart` | `browser/sync/optimistic_updates.ts` |
| `browser/sync/optimistic_updates_impl.dart` | `browser/sync/optimistic_updates_impl.ts` |
| `browser/sync/paginated_query_client.dart` | `browser/sync/paginated_query_client.ts` |
| `browser/sync/pagination.dart` | `browser/sync/pagination.ts` |
| `browser/sync/protocol.dart` | `browser/sync/protocol.ts` |
| `browser/sync/remote_query_set.dart` | `browser/sync/remote_query_set.ts` |
| `browser/sync/request_manager.dart` | `browser/sync/request_manager.ts` |
| `browser/sync/session.dart` | `browser/sync/session.ts` |
| `browser/sync/udf_path_utils.dart` | `browser/sync/udf_path_utils.ts` |
| `browser/sync/web_socket_manager.dart` | `browser/sync/web_socket_manager.ts` |
| `common/index.dart` | `common/index.ts` |
| `flutter/auth_helpers.dart` | `react/auth_helpers.tsx` |
| `flutter/client.dart` | `react/client.ts` |
| `flutter/connectivity.dart` | new: `subscribeToOnline` over connectivity_plus |
| `flutter/convex_auth_state.dart` | `react/ConvexAuthState.tsx` |
| `flutter/queries_observer.dart` | `react/queries_observer.ts` |
| `flutter/use_paginated_query.dart` | `react/use_paginated_query.ts` |
| `flutter/use_paginated_query2.dart` | `react/use_paginated_query2.ts` |
| `flutter/use_queries.dart` | `react/use_queries.ts` |
| `flutter/use_subscription.dart` | `react/use_subscription.ts` |
| `server/api.dart` | `server/api.ts`: `FunctionReference`, `getFunctionName`, `makeFunctionReference` |
| `server/authentication.dart` | `server/authentication.ts`: `UserIdentityAttributes` |
| `server/pagination.dart` | `server/pagination.ts`: `PaginationResult`, `PaginationOptions`, `Cursor` |
| `server/registration.dart` | `server/registration.ts`: the argument types the client uses |
| `values/base64.dart` | `values/base64.ts`, over dart:convert |
| `values/compare.dart` | `values/compare.ts` |
| `values/compare_utf8.dart` | `values/compare_utf8.ts`, comparing runes |
| `values/errors.dart` | `values/errors.ts` |
| `values/size.dart` | `values/size.ts` |
| `values/value.dart` | `values/value.ts` |
| `vendor/jwt_decode/index.dart` | `vendor/jwt-decode/index.ts`, over dart:convert |
| `vendor/long.dart` | `vendor/long.ts`, over `int` |

The libraries mirror the npm entry points: `browser.dart` is `convex/browser`,
`flutter.dart` is `convex/react`, `values.dart` is `convex/values`,
`server.dart` is the client side of `convex/server`, and `re_convex.dart`
exports them all.

Tests mirror the same layout: `test/<dir>/<name>_test.dart` ports
`src/<dir>/<name>.test.ts`, with `react/` as `test/flutter/`. Tests of hooks
and widgets are in `*_widget_test.dart` files tagged `widget`.
`test/support/client_node_test_helpers.dart` and `fake_watch.dart` port
upstream's test helpers. New tests: `dom_web_socket`, `web_socket_manager`,
`logging`, `server/api`, `values/base64`, `vendor/*`, `connectivity`,
`version`, the `ConvexAuthController` tests and `client_test`'s timer checks.

## Deviations

### Language and runtime gaps

- **Values.** `Value` is `Object?`: int64 is `int`, float64 is `double`, bytes
  are `Uint8List`, arrays are `List<Object?>` and objects are
  `Map<String, Object?>`. Every plain JSON number decodes to a `double`, and
  every Dart `int` encodes as `$integer`. `$float` keeps NaN, ±Infinity and
  -0, and `$commitTs` is `CommitTsPlaceholder`.
- **No web.** A web `int` holds 53 bits, so the clients throw
  `UnsupportedError` there.
- **`undefined` and `null`.** Where `null` is a valid result, "no result" is
  `null` and a result is a `({T value})` record: `localQueryResult`,
  `Watch.localQueryResult`, `Unsubscribe.getCurrentValue`,
  `OptimisticLocalStore.getQuery` and `setQuery`, and `useQuery`. Elsewhere a
  missing map key stands for `undefined`.
- **Function references.** There is no `anyApi` proxy: references come from
  the generated `api` or from `makeFunctionReference`.
  `FunctionReference<FnType, Args, ReturnType>` carries an optional `decode`
  for list and map results. `FunctionReference_future` is not ported.
- **Arguments** are a required positional parameter. Option objects are named
  parameters (`optimisticUpdate:`, `journal:`), and `"skip"` is `skip: true`.
- **Durations.** `authRefreshTokenLeeway`, `extendSubscriptionFor` and the
  reconnect backoff are `Duration`s.
- **Renamed for clashes with Dart and Flutter:** `Logger` is `ConvexLogger`,
  `ConnectionState` is `ConvexConnectionState`.
- **Protocol messages** are extension types over the decoded JSON. `Long` wraps
  an unsigned `int` and is used only for `ts` and `maxObservedTimestamp`.
- **Errors.** `ConvexError` implements `Exception`. Other function failures
  throw an `Exception` with upstream's message, and misuse throws
  `ArgumentError` or `StateError`.
- **Iteration.** Loops that call back into user code iterate over copies:
  unlike JS `Map` and `Set`, Dart collections can't change while iterated.
- **Logging.** `logger: false` is `logger: instantiateNoopLogger()`. The
  default logger writes to package:logging's `re_convex` logger.
- **Vendored code.** base64-js, compare-utf8, jwt-decode and Long.js are
  reimplemented over dart:convert and `int`. `metrics.ts` keeps its marks in
  memory, as there is no `performance` API.

### Transport

- **WebSocket.** `webSocketConstructor` is a
  `Future<WebSocket> Function(Uri)` from package:web_socket: dart:io by
  default, `CupertinoWebSocket.connect` on request. `DomWebSocket` recreates
  the browser API (`onopen`, `onmessage`, `onerror`, `onclose`), so
  `web_socket_manager.dart` stays line by line. A local close reports code
  1005, a dropped connection 1006, and a close the server doesn't answer
  within 5 seconds is forced.
- **No client header on the WebSocket**, as in browsers, so the server sends
  large transitions as `TransitionChunk`s, which are reassembled as upstream
  does.
- **`subscribeToOnline`** replaces the browser `online` event, and
  `subscribeToConnectivity()` provides one over connectivity_plus. It is
  opt-in, as on React Native, which has no `online` event.
- **`unsavedChangesWarning`** (a browser `beforeunload` prompt) is dropped.
- **HTTP** goes through Dio, and `ConvexHttpClient` takes an optional `dio`.

### React layer

- **Hooks** are flutter_hooks hooks, and `useSubscription` is a custom `Hook`.
  They subscribe during build, where React subscribes in effects, so the first
  build already shows results in memory.
- **`ConvexProvider`** is an `InheritedWidget`. `useConvex()` throws without
  one, where React returns `undefined`.
- **State changes during build** (page splits, cursor resets) apply at once
  and rebuild after the build, as Flutter can't rebuild a widget during its
  own build.
- **`useQuery_experimental`** returns a sealed `UseQueryResult`:
  `UseQueryPending`, `UseQuerySuccess` or `UseQueryError`.
- **`usePaginatedQuery_experimental`** has only the positional form. The
  object form (`UsePaginatedQueryOptions`) and `usePaginatedQueryInternal`
  (`includePage`, non-throwing errors) are not ported. Its test-only
  `resetPaginationId` is `resetPaginationId2`.
- **`ConvexProviderWithAuth`** takes `useAuth` as a hook that returns a
  `ConvexAuthProviderState`, and a client as `IConvexReactClient`; a
  `ConvexReactClient` is also provided to the subtree. Its effects run after
  the frame, so `Authenticated` subtrees unsubscribe before Convex auth is
  cleared, the order React's effects guarantee. `ConvexAuthController` is its
  state machine without widgets.
- **The auth helpers** take a `child` and render an empty `SizedBox` instead
  of `null`.

### Not ported

- `browser/simple_client-node.ts` (Node only), `react/hydration.tsx` (server
  rendering) and `values/validator.ts`/`validators.ts` (the server's `v`
  builder; re_convex_generator reads validator JSON itself).
- Tests of TypeScript types (`values/validator.test.ts`, `server/api.test.ts`,
  `react/use_query*.test.ts`) and of JavaScript misuse (a React event as
  mutation arguments, the old `clientConfig` object).

## Updating to a new upstream release

1. Diff the upstream files in the map between `npm/1.46.0` and the new tag,
   starting with `index.ts` and `browser/sync/protocol.ts`: the server retires
   old client versions.
2. Apply the same change to the matching Dart file and test.
3. Update `version` in `lib/src/index.dart`, the pins above and the README
   disclosure link.
