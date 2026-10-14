// Ported from convex/src/browser/sync/session.ts (Apache-2.0); modified for Dart.
import 'dart:math';

final Random _random = Random();

/// A random v4 UUID identifying a client session.
String newSessionId() => _uuidv4();

String _uuidv4() => 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
  RegExp('[xy]'),
  (match) {
    final r = _random.nextInt(16);
    final v = match[0] == 'x' ? r : (r & 0x3) | 0x8;
    return v.toRadixString(16);
  },
);
