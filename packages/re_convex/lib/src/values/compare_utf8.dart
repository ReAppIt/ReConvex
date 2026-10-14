// Replaces convex/src/values/compare_utf8.ts (vendored compare-utf8) with a rune comparison.

/// Compares two strings as if they were UTF-8 encoded byte arrays.
///
/// UTF-8 byte order equals code point order, so this compares runes.
int compareUTF8(String a, String b) {
  final aRunes = a.runes.iterator;
  final bRunes = b.runes.iterator;
  while (true) {
    final aHasNext = aRunes.moveNext();
    final bHasNext = bRunes.moveNext();
    if (!aHasNext || !bHasNext) {
      return aHasNext == bHasNext ? 0 : (aHasNext ? 1 : -1);
    }
    if (aRunes.current != bRunes.current) {
      return aRunes.current - bRunes.current;
    }
  }
}

/// Whether [a] sorts after [b] in UTF-8 order.
bool greaterThan(String a, String b) => compareUTF8(a, b) > 0;

/// Whether [a] sorts after or equal to [b] in UTF-8 order.
bool greaterThanEq(String a, String b) => compareUTF8(a, b) >= 0;

/// Whether [a] sorts before [b] in UTF-8 order.
bool lessThan(String a, String b) => compareUTF8(a, b) < 0;

/// Whether [a] sorts before or equal to [b] in UTF-8 order.
bool lessThanEq(String a, String b) => compareUTF8(a, b) <= 0;
