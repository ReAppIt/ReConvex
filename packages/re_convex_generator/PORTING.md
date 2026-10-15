# Porting notes

`re_convex_generator` is the Dart counterpart of `npx convex codegen`. It reads
the JSON that `npx convex function-spec` prints instead of the TypeScript
modules, so it ports the parts of the codegen that work from validators.

## Upstream pins

| Project | Version | Source |
|---|---|---|
| `convex` | 1.46.0 | [`src`](https://github.com/get-convex/convex-js/tree/npm/1.46.0/src) |

## File map

| Dart | Upstream |
|---|---|
| `lib/src/function_spec.dart` | `cli/lib/functionSpec.ts`: reading the spec |
| `lib/src/validator_json.dart` | `values/validators.ts`: `ValidatorJSON` |
| `lib/src/validator_helpers.dart` | `cli/codegen_templates/validator_helpers.ts`: validators to types |
| `lib/src/api.dart` | `cli/codegen_templates/api.ts`: the `api` object |
| `lib/src/common.dart` | `cli/codegen_templates/common.ts` |
| `lib/src/generator.dart` | new: the source_gen `Generator` |
| `lib/src/emit.dart` | new: the generated part |
| `lib/src/dart_type.dart` | new: Dart types and how to read them |
| `lib/src/naming.dart` | new: Dart identifiers |
| `lib/re_convex_generator.dart` | new: the build_runner builder |

Tests are new: `generator_test.dart` runs the builder on
`test/fixtures/function_spec.json`, and the others cover their file.
Upstream's `cli/codegen_templates/api.test.ts` tests TypeScript import paths,
which have no Dart counterpart.

## Deviations

- **Input.** The spec holds validators, not TypeScript types, so functions
  without an args validator take `Map<String, Object?>` and functions without
  a returns validator return `Object?`.
- **One part file** replaces `api.d.ts`, `api.js` and the module imports, so
  `importPath` and `moduleIdentifier` are not ported.
- **Types** are Dart extension types over the raw maps instead of structural
  types. Documents are recognised by `_id` and `_creationTime` and shared as
  `<Table>Doc`. A shape a document holds is named after the shallowest
  document field holding it, whichever function declares it first.
- **String-literal unions** accept unknown values, so an app keeps working
  when a newer backend adds one.
- **Unions** other than `T | null`, string literals and objects tagged by one
  literal field become their common type, or `Object`.
- **Optional nullable fields** are `({T? value})?`, the Dart form of
  `T | null | undefined`.
- **`paginationOpts`** is optional in argument constructors, as
  `usePaginatedQuery` fills it in.
- **Names** follow Dart: modules and functions are lowerCamelCase getters,
  reserved words take a `_` suffix (`default_`, `new_`), and `_id` and
  `_creationTime` are `id` and `creationTime`.

## Updating to a new upstream release

1. Diff `cli/lib/functionSpec.ts`, `cli/codegen_templates/` and
   `ValidatorJSON` in `values/validators.ts` between `npm/1.46.0` and the new
   tag.
2. Apply the same change to the matching Dart file and test, then regenerate
   the example with `dart run build_runner build`.
3. Update the pin above and the README disclosure link.
