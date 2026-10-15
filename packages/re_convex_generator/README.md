# re_convex_generator

> [!NOTE]
> **AI-written, human-reviewed.** Every line of this package was written by AI
> (Claude, by Anthropic), porting the code generation of the official
> [`convex`](https://github.com/get-convex/convex-js/tree/npm/1.46.0) CLI to
> Dart, and has been fully reviewed by a human. It is not affiliated with
> Convex.

Generates a typed `api` for [re_convex](https://pub.dev/packages/re_convex)
from the JSON that `npx convex function-spec` prints. It is the Dart
counterpart of `convex/_generated/api.d.ts`, built with
[source_gen](https://pub.dev/packages/source_gen) and build_runner.

## Setup

```bash
flutter pub add re_convex dev:re_convex_generator dev:build_runner
```

In your Convex project, save the function spec inside your Flutter package:

```bash
npx convex function-spec > ../my_app/convex/function_spec.json
```

List it under `sources`, so that build_runner reads it and rebuilds when it
changes:

```yaml
# build.yaml
targets:
  $default:
    sources:
      - $package$
      - lib/**
      - convex/function_spec.json
```

Annotate a library with the spec's path, relative to the package root:

```dart
// lib/convex/api.dart
@ConvexApi('convex/function_spec.json')
library;

import 'package:re_convex/re_convex.dart';

part 'api.g.dart';
```

Generate `api.g.dart`, and again whenever your functions change:

```bash
dart run build_runner build
```

## What it generates

For every public query, mutation and action, a getter on `api` that returns a
`FunctionReference` typed by the function's validators. `messages:list` is
`api.messages.list`, `admin/users:sync` is `api.admin.users.sync`, and a
`default` export is `default_`:

```dart
// lib/data/message_repository.dart
final page = await convex.query(
  api.messages.list,
  MessagesListArgs(
    channel: channel,
    paginationOpts: PaginationOptions(numItems: 20, cursor: null),
  ),
);
```

Objects become extension types over the raw map, so reading a result copies
nothing. Each has a constructor with named parameters, a getter per field and
`operator []` for fields the spec doesn't know.

| Validator | Dart |
|---|---|
| `v.number()` | `double` |
| `v.int64()` | `int` |
| `v.boolean()`, `v.string()`, `v.bytes()` | `bool`, `String`, `Uint8List` |
| `v.null()`, `v.any()` | `Null`, `Object?` |
| `v.id("users")` | `UsersId`, an extension type over `String` |
| `v.array(T)`, `v.record(K, V)` | `List<T>`, `Map<K, V>` |
| `v.object({...})` | an extension type over `Map<String, Object?>` |
| a document (`_id` and `_creationTime`) | `<Table>Doc`, shared by every function |
| `v.union(T, v.null())` | `T?` |
| a union of string literals | an extension type over `String` with a constant per value |
| a union of objects tagged by a literal field | a base type with an `as<Variant>` getter per variant |
| any other union | the common type, or `Object` |
| `v.optional(T)` | `T?`, left out of the object when `null` |
| `v.optional(v.union(T, v.null()))` | `({T? value})?`, to tell a missing field from `null` |
| `paginationOpts` arguments, pagination results | `PaginationOptions`, `PaginationResult<T>` |

Literal unions accept values they don't list, so an app keeps working when a
newer backend adds one; `values` lists the known ones. Types are named after
the function and field, like `MessagesListArgs`; a shape a document holds is
named after the shallowest document field holding it, like `MessagesDocStatus`,
whichever function uses it first. A function without an args validator takes
`Map<String, Object?>`; one without a returns validator returns `Object?`.

## Limitations

- Internal functions and HTTP actions are skipped, since clients can't call
  them.
- Only what the spec describes is typed. Functions missing from it need
  `makeFunctionReference`.
- `v.map()` and `v.set()` are `Object?`.

## License

MIT. The ported code keeps the Apache-2.0 notice of the Convex CLI; see
[LICENSE](LICENSE).
