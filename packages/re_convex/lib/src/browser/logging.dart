// Ported from convex/src/browser/logging.ts (Apache-2.0); modified for Dart.
import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

/// The kind of function a log line comes from.
enum UdfType {
  /// A query.
  query,

  /// A mutation.
  mutation,

  /// An action.
  action,

  /// Any function.
  any,
}

String _prefixForSource(UdfType source) => switch (source) {
  UdfType.query => 'Q',
  UdfType.mutation => 'M',
  UdfType.action => 'A',
  UdfType.any => '?',
};

/// The level of a log line.
enum LogLevel {
  /// Verbose output.
  debug,

  /// Function logs and connection events.
  info,

  /// Warnings.
  warn,

  /// Errors.
  error,
}

/// Where the client writes its logs (`Logger` upstream).
///
/// [instantiateDefaultLogger] writes to package:logging;
/// [instantiateNoopLogger] drops everything.
abstract interface class ConvexLogger {
  /// Logs a verbose line; only shown when verbose logging is on.
  void logVerbose(String message);

  /// Logs an info line.
  void log(String message);

  /// Logs a warning.
  void warn(String message);

  /// Logs an error.
  void error(String message);
}

/// A [ConvexLogger] that forwards each line to its listeners.
class DefaultLogger implements ConvexLogger {
  /// Creates a logger that also forwards verbose lines when [verbose].
  DefaultLogger({required bool verbose}) : _verbose = verbose;

  final bool _verbose;
  final Map<int, void Function(LogLevel level, String message)>
  _onLogLineFuncs = {};
  int _nextId = 0;

  /// Adds a listener; returns a function that removes it.
  void Function() addLogLineListener(
    void Function(LogLevel level, String message) func,
  ) {
    final id = _nextId++;
    _onLogLineFuncs[id] = func;
    return () {
      _onLogLineFuncs.remove(id);
    };
  }

  void _emit(LogLevel level, String message) {
    for (final func in _onLogLineFuncs.values.toList()) {
      func(level, message);
    }
  }

  @override
  void logVerbose(String message) {
    if (_verbose) {
      _emit(
        LogLevel.debug,
        '${clock.now().toUtc().toIso8601String()} $message',
      );
    }
  }

  @override
  void log(String message) => _emit(LogLevel.info, message);

  @override
  void warn(String message) => _emit(LogLevel.warn, message);

  @override
  void error(String message) => _emit(LogLevel.error, message);
}

final Logger _logger = Logger('re_convex');

/// A logger that writes to package:logging's `Logger('re_convex')`.
ConvexLogger instantiateDefaultLogger({required bool verbose}) {
  final logger = DefaultLogger(verbose: verbose);
  logger.addLogLineListener((level, message) {
    switch (level) {
      case LogLevel.debug:
        _logger.fine(message);
      case LogLevel.info:
        _logger.info(message);
      case LogLevel.warn:
        _logger.warning(message);
      case LogLevel.error:
        _logger.severe(message);
    }
  });
  return logger;
}

/// A logger without listeners, which drops every line.
ConvexLogger instantiateNoopLogger({bool verbose = false}) =>
    DefaultLogger(verbose: verbose);

/// Logs a line a function printed ([type] `info`) or its error.
void logForFunction(
  ConvexLogger logger,
  LogLevel type,
  UdfType source,
  String udfPath,
  String message,
) {
  final prefix = _prefixForSource(source);
  if (type == LogLevel.info) {
    final match = RegExp(r'^\[.*?\] ').firstMatch(message);
    if (match == null) {
      logger.error('[CONVEX $prefix($udfPath)] Could not parse console.log');
      return;
    }
    final level = message.substring(1, match.end - 2);
    final args = message.substring(match.end);
    logger.log('[CONVEX $prefix($udfPath)] [$level] $args');
  } else {
    logger.error('[CONVEX $prefix($udfPath)] $message');
  }
}

/// Logs a fatal error and returns it to throw.
Exception logFatalError(ConvexLogger logger, String message) {
  final errorMessage = '[CONVEX FATAL ERROR] $message';
  logger.error(errorMessage);
  return Exception(errorMessage);
}

/// The message of a failed function call, naming the function.
String createHybridErrorStacktrace(
  UdfType source,
  String udfPath,
  FunctionFailure result,
) {
  final prefix = _prefixForSource(source);
  return '[CONVEX $prefix($udfPath)] ${result.errorMessage}\n  Called by client';
}

/// Moves the `ConvexError` data of [result] into [error].
ConvexError<Value> forwardData(
  FunctionFailure result,
  ConvexError<Value> error,
) {
  error.data = result.errorData?.value;
  return error;
}
