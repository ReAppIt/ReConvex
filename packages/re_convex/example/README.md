# re_convex example

A chat client for a Convex backend described by
[`convex/function_spec.json`](convex/function_spec.json):

- [`lib/convex/api.dart`](lib/convex/api.dart) generates the typed `api`
  into the committed `api.g.dart`.
- [`lib/data/message_repository.dart`](lib/data/message_repository.dart) wraps
  the client in a repository: a `Stream` over a query, a one-off query, and a
  mutation with an optimistic update.
- [`lib/main.dart`](lib/main.dart) shows the stream in a page.

It needs a deployment with these functions. Add the platform folders with
`flutter create .` and point `convex` in `lib/main.dart` at the deployment.
After changing the functions, regenerate the API:

```bash
npx convex function-spec > convex/function_spec.json
dart run build_runner build
```
