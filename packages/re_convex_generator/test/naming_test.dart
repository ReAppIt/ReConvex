import 'package:re_convex_generator/src/naming.dart';
import 'package:test/test.dart';

void main() {
  group('naming', () {
    test('lowerCamel joins words and escapes reserved words', () {
      expect(lowerCamel('user_settings'), 'userSettings');
      expect(lowerCamel('user-settings'), 'userSettings');
      expect(lowerCamel('getUser'), 'getUser');
      expect(lowerCamel('default'), 'default_');
      expect(lowerCamel('get'), 'get');
      expect(lowerCamel('2fa'), r'$2fa');
      expect(lowerCamel('json'), 'json_');
    });

    test('pascal builds type name parts', () {
      expect(pascal('_storage'), 'Storage');
      expect(pascal('user_profiles'), 'UserProfiles');
      expect(pascal('admin/users'), 'AdminUsers');
    });

    test('fieldName drops leading underscores', () {
      expect(fieldName('_id'), 'id');
      expect(fieldName('_creationTime'), 'creationTime');
      expect(fieldName('first_name'), 'firstName');
    });

    test('stringLiteral escapes Dart string syntax', () {
      expect(stringLiteral(r"it's $x"), r"'it\'s \$x'");
    });
  });
}
