// Ported from convex/src/cli/codegen_templates/common.ts (Apache-2.0); modified for Dart.

/// The comment lines the generated part starts with.
String header(String functionSpecPath) =>
    '// coverage:ignore-file\n'
    '// ignore_for_file: type=lint\n'
    '// generated_from: $functionSpecPath\n';

/// Orders module paths the same way on every platform.
int compareModulePaths(String a, String b) =>
    a.replaceAll(r'\', '/').compareTo(b.replaceAll(r'\', '/'));
