# ReConvex

> [!NOTE]
> **AI-written, human-reviewed.** Every line of these packages was written by
> AI (Claude, by Anthropic) as a port of the official
> [`convex`](https://github.com/get-convex/convex-js/tree/npm/1.46.0) client,
> and the port has been fully reviewed by a human. It is not affiliated with
> Convex.

[Convex](https://convex.dev) for Flutter, in pure Dart: no Rust bridge and no
native code.

| Package | What it is |
|---|---|
| [`re_convex`](packages/re_convex) | A file-by-file port of the client that React Native apps use: realtime queries over a WebSocket, mutations with optimistic updates, actions, pagination, auth and the React hooks on flutter_hooks. |
| [`re_convex_generator`](packages/re_convex_generator) | A build_runner generator that turns `npx convex function-spec` into a typed `api`, the counterpart of `convex/_generated/api.d.ts`. |

Start with the [re_convex README](packages/re_convex/README.md). Each package's
`PORTING.md` maps its files to their upstream sources.

## Development

This is a pub workspace with the Flutter version pinned in `.fvmrc`:

```bash
flutter pub get
dart format .
flutter analyze
(cd packages/re_convex && flutter test)
(cd packages/re_convex_generator && dart test)
(cd packages/re_convex/example && dart run build_runner build && flutter test)
```

## License

MIT, with the notices of the ported code; see [LICENSE](LICENSE).
