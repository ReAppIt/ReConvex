import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/src/browser/sync/protocol.dart';
import 'package:re_convex/src/vendor/long.dart';

void main() {
  test('Long serialization', () {
    expect(
      Long.fromNumber(89234097497),
      u64ToLong(longToU64(Long.fromNumber(89234097497))),
    );
  });

  test('parseServerMessage rejects unknown types', () {
    expect(() => parseServerMessage({'type': 'Nope'}), throwsFormatException);
    expect(parseServerMessage({'type': 'Ping'}).type, 'Ping');
  });

  test('Connect leaves out a missing maxObservedTimestamp', () {
    final connect = Connect(
      sessionId: 's',
      connectionCount: 0,
      lastCloseReason: 'InitialConnect',
      clientTs: 1,
    );
    expect(connect.json.containsKey('maxObservedTimestamp'), isFalse);
    expect(
      Connect(
        sessionId: 's',
        connectionCount: 1,
        lastCloseReason: null,
        clientTs: 1,
        maxObservedTimestamp: Long.fromNumber(5),
      ).maxObservedTimestamp,
      Long.fromNumber(5),
    );
  });
}
