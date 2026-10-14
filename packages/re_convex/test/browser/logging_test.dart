import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:re_convex/src/browser/logging.dart';
import 'package:re_convex/src/browser/sync/function_result.dart';
import 'package:re_convex/src/values/errors.dart';
import 'package:re_convex/src/values/value.dart';

void main() {
  group('logForFunction', () {
    late List<(LogLevel, String)> lines;
    late DefaultLogger logger;

    setUp(() {
      lines = [];
      logger = DefaultLogger(verbose: false)
        ..addLogLineListener((level, message) => lines.add((level, message)));
    });

    test('prefixes function log lines with the function', () {
      logForFunction(
        logger,
        LogLevel.info,
        UdfType.query,
        'messages:list',
        '[LOG] hello',
      );
      expect(lines, [(LogLevel.info, '[CONVEX Q(messages:list)] [LOG] hello')]);
    });

    test('reports unparseable lines', () {
      logForFunction(logger, LogLevel.info, UdfType.action, 'a:b', 'oops');
      expect(lines, [
        (LogLevel.error, '[CONVEX A(a:b)] Could not parse console.log'),
      ]);
    });

    test('logs errors as is', () {
      logForFunction(logger, LogLevel.error, UdfType.mutation, 'a:b', 'bad');
      expect(lines, [(LogLevel.error, '[CONVEX M(a:b)] bad')]);
    });
  });

  test('verbose lines only reach listeners when verbose', () {
    final lines = <String>[];
    DefaultLogger(verbose: false)
      ..addLogLineListener((_, message) => lines.add(message))
      ..logVerbose('hidden');
    DefaultLogger(verbose: true)
      ..addLogLineListener((_, message) => lines.add(message))
      ..logVerbose('shown');
    expect(lines, [endsWith(' shown')]);
  });

  test('the default logger writes to package:logging', () {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    instantiateDefaultLogger(verbose: false).warn('careful');
    expect(records.single.loggerName, 're_convex');
    expect(records.single.level, Level.WARNING);
    expect(records.single.message, 'careful');
  });

  test('forwardData moves the error data into the ConvexError', () {
    const failure = FunctionFailure(
      errorMessage: 'boom',
      logLines: [],
      errorData: (value: {'code': 1.0}),
    );
    final error = forwardData(
      failure,
      ConvexError<Value>(
        createHybridErrorStacktrace(UdfType.mutation, 'a:b', failure),
      ),
    );
    expect(error.message, '[CONVEX M(a:b)] boom\n  Called by client');
    expect(error.data, {'code': 1.0});
  });
}
