## 0.2.0

- A shape a document holds is named after the shallowest document field
  holding it, like `TasksDocStatus`, instead of after the first function that
  uses it. Generated names change, so regenerate and update references.

## 0.1.0

- Initial release: generates a typed `api` for re_convex from
  `npx convex function-spec`, with Dart types for arguments, documents and
  unions, following the `convex` 1.46.0 codegen.
