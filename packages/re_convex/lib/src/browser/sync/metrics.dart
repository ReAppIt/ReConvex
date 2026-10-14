// Ported from convex/src/browser/sync/metrics.ts (Apache-2.0); modified for Dart.
import 'package:clock/clock.dart';

/// The client milestones the client marks.
enum MarkName {
  /// A client was constructed.
  convexClientConstructed,

  /// Its WebSocket opened.
  convexWebSocketOpen,

  /// Its first server message arrived.
  convexFirstMessageReceived,
}

final Stopwatch _timeOrigin = clock.stopwatch()..start();

final List<({MarkName name, String sessionId, double startTime})> _marks = [];

/// Records [name] for [sessionId]; marks are kept in memory, like the
/// browser's performance timeline.
void mark(MarkName name, String sessionId) {
  _marks.add((
    name: name,
    sessionId: sessionId,
    startTime: _timeOrigin.elapsedMicroseconds / 1000,
  ));
}

/// The marks of [sessionId] as JSON: `name` without its `convex` prefix and
/// `startTime` in milliseconds since the time origin.
List<Map<String, Object?>> getMarksReport(String sessionId) => [
  for (final mark in _marks)
    if (mark.sessionId == sessionId)
      {
        'name':
            mark.name.name[6].toLowerCase() +
            mark.name.name.substring('convex'.length + 1),
        'startTime': mark.startTime,
      },
];
