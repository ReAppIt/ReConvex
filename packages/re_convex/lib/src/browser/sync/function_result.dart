// Ported from convex/src/browser/sync/function_result.ts (Apache-2.0); modified for Dart.
import 'package:re_convex/src/values/value.dart';

/// The result of running a function on the server: a [FunctionSuccess] with
/// a value, or a [FunctionFailure] with an error message.
sealed class FunctionResult {
  const FunctionResult({required this.logLines});

  /// Whether the function returned without throwing.
  bool get success;

  /// Log lines the function printed.
  final List<String> logLines;
}

/// A function that returned [value].
final class FunctionSuccess extends FunctionResult {
  /// Creates the result.
  const FunctionSuccess({required this.value, required super.logLines});

  @override
  bool get success => true;

  /// The returned value.
  final Value value;
}

/// A function that threw.
final class FunctionFailure extends FunctionResult {
  /// Creates the result.
  const FunctionFailure({
    required this.errorMessage,
    required super.logLines,
    this.errorData,
  });

  @override
  bool get success => false;

  /// The error message.
  final String errorMessage;

  /// The `ConvexError` data, or `null` when the error wasn't a `ConvexError`.
  final ({Value value})? errorData;
}
