// Ported from convex/src/server/api.ts (Apache-2.0); modified for Dart.
import 'package:meta/meta.dart';
import 'package:re_convex/src/values/value.dart';

/// The type of a Convex function: [QueryType], [MutationType] or
/// [ActionType].
sealed class FunctionType {}

/// Marks a [FunctionReference] to a query.
abstract final class QueryType extends FunctionType {}

/// Marks a [FunctionReference] to a mutation.
abstract final class MutationType extends FunctionType {}

/// Marks a [FunctionReference] to an action.
abstract final class ActionType extends FunctionType {}

/// A reference to a registered Convex function, usually from the generated
/// `api`; results are cast to `ReturnType`, or decoded by `decode`.
final class FunctionReference<FnType extends FunctionType, Args, ReturnType> {
  /// Creates a reference to the function [name], like `dir/module:function`.
  const FunctionReference(
    String name, {
    ReturnType Function(Value value)? decode,
  }) : _name = name,
       _decode = decode;

  final String _name;
  final ReturnType Function(Value value)? _decode;

  /// Converts a raw Convex value into `ReturnType`.
  @internal
  ReturnType decodeResult(Value value) {
    final decode = _decode;
    return decode == null ? value as ReturnType : decode(value);
  }

  @override
  bool operator ==(Object other) =>
      other is FunctionReference && other._name == _name;

  @override
  int get hashCode => _name.hashCode;

  @override
  String toString() => 'FunctionReference($_name)';
}

/// A [FunctionReference] of any function type, arguments and result.
typedef AnyFunctionReference =
    FunctionReference<FunctionType, Object?, Object?>;

/// The name of a function, like `myDir/myModule:myFunction`.
///
/// A function exported as `default` is named by its module alone.
String getFunctionName(AnyFunctionReference functionReference) =>
    functionReference._name;

/// Builds a [FunctionReference] by name, for code without the generated
/// `api` (where `anyApi.messages.list` would be used in TypeScript).
FunctionReference<FnType, Args, ReturnType>
makeFunctionReference<FnType extends FunctionType, Args, ReturnType>(
  String name, {
  ReturnType Function(Value value)? decode,
}) => FunctionReference<FnType, Args, ReturnType>(name, decode: decode);
