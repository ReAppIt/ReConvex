import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/values.dart';

void main() {
  group('getConvexSize', () {
    test('long strings use TextEncoder path (>500 chars)', () {
      final longAscii = 'a' * 1000;
      expect(getConvexSize(longAscii), 1002); // 1000 + 2 overhead

      final longUtf8 = 'héllo' * 200; // 6 bytes each
      expect(getConvexSize(longUtf8), 1202); // 1200 + 2 overhead
    });

    test('counts every value type', () {
      expect(getConvexSize(null), 1);
      expect(getConvexSize(true), 1);
      expect(getConvexSize(1), 9);
      expect(getConvexSize(1.5), 9);
      expect(getConvexSize('😀'), 6);
      expect(getConvexSize(Uint8List(3)), 5);
      expect(getConvexSize(<Object?>[1.0, null]), 12);
    });
  });

  group('getDocumentSize', () {
    test('adds system fields overhead when not present', () {
      final doc = {'name': 'Alice'};
      final baseSize = getConvexSize(doc);
      expect(
        getDocumentSize(doc),
        baseSize + systemFieldIdEstimate + systemFieldCreationTimeSize,
      );
    });

    test('empty document with system fields', () {
      expect(getConvexSize(<String, Object?>{}), 2);
      expect(
        getDocumentSize({}),
        2 + systemFieldIdEstimate + systemFieldCreationTimeSize,
      );
    });

    test('does not double-count existing system fields', () {
      final doc = {
        '_id': 'abc123def456ghi789jkl012mno345pq',
        '_creationTime': 1234567890123.0,
        'name': 'Alice',
      };
      final baseSize = getConvexSize(doc);
      expect(getDocumentSize(doc), baseSize);
    });

    test('handles partial system fields', () {
      // Only _id present
      final docWithId = {
        '_id': 'abc123def456ghi789jkl012mno345pq',
        'name': 'Alice',
      };
      final sizeWithId = getConvexSize(docWithId);
      expect(
        getDocumentSize(docWithId),
        sizeWithId + systemFieldCreationTimeSize,
      ); // adds _creationTime

      // Only _creationTime present
      final docWithTime = {'_creationTime': 1234567890123.0, 'name': 'Alice'};
      final sizeWithTime = getConvexSize(docWithTime);
      expect(getDocumentSize(docWithTime), sizeWithTime + 38); // adds _id
    });

    test('customIdLength option', () {
      final doc = {'name': 'Alice', '_creationTime': 1234567890123.0};
      const customIdLength = 40;

      // With custom ID length: 4 (field) + 2 (string overhead) + 40 = 46 bytes
      final withCustomId = getDocumentSize(doc, customIdLength: customIdLength);

      // Verify by computing with actual _id of that length
      final withActualId = getConvexSize({...doc, '_id': 'a' * customIdLength});
      expect(withCustomId, withActualId);
    });
  });
}
