## 0.1.0

- Initial release: a port of the `convex` 1.46.0 client (`convex/browser`,
  `convex/react` and `convex/values`) to Flutter.
  - `ConvexReactClient`, `ConvexClient` and `ConvexHttpClient`, speaking the
    sync protocol over package:web_socket and HTTP over Dio.
  - Queries, subscriptions, mutations with optimistic updates, actions,
    pagination, and token auth with refetching.
  - The React hooks on flutter_hooks (`useQuery`, `usePaginatedQuery`,
    `useMutation`, ...), `ConvexProvider`, `ConvexProviderWithAuth` and the
    auth helper widgets.
  - `subscribeToConnectivity()` to reconnect when the network returns.
