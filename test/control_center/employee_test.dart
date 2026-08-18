import 'package:phoenix_backend/src/control_center/employee.dart';
import 'package:test/test.dart';

Map<String, Object?> _row({
  int id = 1,
  String name = 'Ada Lovelace',
  String login = 'ada',
  String email = 'ada@phoenix.example',
  String role = 'ADMIN',
  Object? permissionOverrides = const <String, Object?>{},
  String? department = 'Engineering',
  String status = 'active',
  Object? createdAt,
  Object? lastLoginAt,
  String? passwordHash = 'a-bcrypt-hash',
}) {
  return {
    'id': id,
    'name': name,
    'login': login,
    'email': email,
    'role': role,
    'permission_overrides': permissionOverrides,
    'department': department,
    'status': status,
    'created_at': createdAt ?? DateTime.utc(2026, 1, 1),
    'last_login_at': lastLoginAt,
    'password_hash': passwordHash,
  };
}

void main() {
  group('Employee.fromRow', () {
    test('parses a typical database row', () {
      final employee = Employee.fromRow(_row());
      expect(employee.id, 1);
      expect(employee.name, 'Ada Lovelace');
      expect(employee.login, 'ada');
      expect(employee.email, 'ada@phoenix.example');
      expect(employee.role, 'ADMIN');
      expect(employee.department, 'Engineering');
      expect(employee.status, 'active');
      expect(employee.isActive, isTrue);
      expect(employee.isOwner, isFalse);
    });

    test('decodes permission_overrides when postgres returns it as a JSON string', () {
      final employee = Employee.fromRow(
        _row(permissionOverrides: '{"employees.view":true}'),
      );
      expect(employee.permissionOverrides, {'employees.view': true});
    });

    test('decodes permission_overrides when postgres returns it already as a Map', () {
      final employee = Employee.fromRow(
        _row(permissionOverrides: {'audit.view': false}),
      );
      expect(employee.permissionOverrides, {'audit.view': false});
    });

    test('a disabled OWNER row is recognized correctly', () {
      final employee = Employee.fromRow(_row(role: 'OWNER', status: 'disabled'));
      expect(employee.isOwner, isTrue);
      expect(employee.isActive, isFalse);
    });
  });

  group('Employee.hasPermission', () {
    test('delegates to the role/override matrix', () {
      final owner = Employee.fromRow(_row(role: 'OWNER'));
      final support = Employee.fromRow(_row(role: 'SUPPORT'));
      final supportWithOverride = Employee.fromRow(
        _row(role: 'SUPPORT', permissionOverrides: {'employees.view': true}),
      );

      expect(owner.hasPermission('employees.manage'), isTrue);
      expect(support.hasPermission('employees.view'), isFalse);
      expect(supportWithOverride.hasPermission('employees.view'), isTrue);
    });
  });

  group('Employee.toPublicJson', () {
    test('never includes password_hash', () {
      final json = Employee.fromRow(_row()).toPublicJson();
      expect(json.containsKey('password_hash'), isFalse);
      expect(json.containsKey('passwordHash'), isFalse);
      expect(json.values.map((v) => v.toString()), isNot(contains('a-bcrypt-hash')));
    });

    test('serializes dates as ISO-8601 strings', () {
      final json = Employee.fromRow(
        _row(createdAt: DateTime.utc(2026, 3, 4, 5, 6), lastLoginAt: DateTime.utc(2026, 3, 5)),
      ).toPublicJson();
      expect(json['createdAt'], '2026-03-04T05:06:00.000Z');
      expect(json['lastLoginAt'], '2026-03-05T00:00:00.000Z');
    });
  });
}
