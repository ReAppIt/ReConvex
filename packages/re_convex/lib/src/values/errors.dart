// Ported from convex/src/values/errors.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// An error a Convex function threw with `new ConvexError(data)`.
///
/// [data] carries the thrown value; [message] is it, or its JSON form.
class ConvexError<TData extends Value> implements Exception {
  /// Creates an error with [data], used as the message when it is a string.
  ConvexError(this.data)
    : message = data is String ? data : stringifyValueForError(data);

  /// Always `ConvexError`.
  String get name => 'ConvexError';

  /// The error message.
  final String message;

  /// The data thrown by the function.
  TData data;

  @override
  String toString() => '$name: $message';
}
