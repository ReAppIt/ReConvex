import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_convex/re_convex.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final version = pubspec
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')
        .last
        .trim();
    expect(packageVersion, version);
  });

  test('version is the ported convex release', () {
    expect(version, '1.46.0');
  });
}
