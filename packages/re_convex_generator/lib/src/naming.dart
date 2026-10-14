/// Names a generated member can't take: Dart's reserved words, the members
/// every object has, and the extension types' own members.
const Set<String> _reserved = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'fromValue',
  'hashCode',
  'json',
  'noSuchMethod',
  'runtimeType',
  'toString',
};

List<String> _words(String s) =>
    s.split(RegExp('[^A-Za-z0-9]+')).where((w) => w.isNotEmpty).toList();

String _capitalize(String w) => w[0].toUpperCase() + w.substring(1);

String _escape(String identifier) {
  if (identifier.isEmpty) return r'$';
  if (RegExp('^[0-9]').hasMatch(identifier)) return '\$$identifier';
  return _reserved.contains(identifier) ? '${identifier}_' : identifier;
}

/// [s] as a lowerCamelCase member name, like `user_settings` →
/// `userSettings`; reserved words get a `_` suffix.
String lowerCamel(String s) {
  final words = _words(s);
  if (words.isEmpty) return r'$';
  final first = words.first;
  return _escape(
    first[0].toLowerCase() +
        first.substring(1) +
        words.skip(1).map(_capitalize).join(),
  );
}

/// [s] as an UpperCamelCase type name part, like `user_settings` →
/// `UserSettings`.
String pascal(String s) {
  final words = _words(s);
  if (words.isEmpty) return r'$';
  final name = words.map(_capitalize).join();
  return RegExp('^[0-9]').hasMatch(name) ? '\$$name' : name;
}

/// The getter name of an object field; leading underscores are dropped, so
/// `_id` is `id` and `_creationTime` is `creationTime`.
String fieldName(String key) => lowerCamel(key.replaceFirst(RegExp('^_+'), ''));

/// A string literal for [value] in generated code.
String stringLiteral(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return "'$escaped'";
}
