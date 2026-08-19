import 'package:phoenix_backend/src/control_center/permissions.dart';
import 'package:test/test.dart';

void main() {
  group('kRoleDefaultPermissions consistency', () {
    test('every configured permission key is a known permission', () {
      for (final entry in kRoleDefaultPermissions.entries) {
        for (final permission in entry.value) {
          expect(
            kAllPermissions.contains(permission),
            isTrue,
            reason: '${entry.key} references unknown permission $permission',
          );
        }
      }
    });

    test('OWNER never appears as a key (handled as an always-true special case)', () {
      expect(kRoleDefaultPermissions.containsKey('OWNER'), isFalse);
    });
  });

  group('hasPermissionForRole - OWNER', () {
    test('OWNER has every known permission by default', () {
      for (final permission in kAllPermissions) {
        expect(
          hasPermissionForRole(role: 'OWNER', permission: permission),
          isTrue,
        );
      }
    });

    test('OWNER cannot be restricted by permission_overrides, even an explicit deny', () {
      expect(
        hasPermissionForRole(
          role: 'OWNER',
          permission: 'employees.manage',
          overrides: const {'employees.manage': false},
        ),
        isTrue,
      );
    });
  });

  group('hasPermissionForRole - ADMIN', () {
    test(
      'ADMIN has all defined permissions by default, except employees.passwordResetApprove '
      '(Account-System Abschnitt 21: explizit "NEIN" fuer ADMIN, nur OWNER/VICE_OWNER)',
      () {
        for (final permission in kAllPermissions) {
          final expected = permission != 'employees.passwordResetApprove';
          expect(
            hasPermissionForRole(role: 'ADMIN', permission: permission),
            expected,
            reason: 'ADMIN / $permission',
          );
        }
      },
    );
  });

  group('hasPermissionForRole - VICE_OWNER', () {
    test(
      'VICE_OWNER has all defined permissions by default, including employees.passwordResetApprove',
      () {
        for (final permission in kAllPermissions) {
          expect(
            hasPermissionForRole(role: 'VICE_OWNER', permission: permission),
            isTrue,
            reason: 'VICE_OWNER / $permission',
          );
        }
      },
    );
  });

  group('hasPermissionForRole - SECURITY', () {
    test('SECURITY can suspend/unsuspend users and view security reports by default', () {
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'users.suspend'), isTrue);
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'users.unsuspend'), isTrue);
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'users.viewSecurityReport'), isTrue);
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'ipBlocks.manage'), isTrue);
    });

    test('SECURITY cannot manage employees or premium by default', () {
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'employees.manage'), isFalse);
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'premium.manualGrant'), isFalse);
      expect(hasPermissionForRole(role: 'SECURITY', permission: 'refunds.decide'), isFalse);
    });
  });

  group('hasPermissionForRole - SUPPORT and user data (Abschnitt 77)', () {
    test('SUPPORT can view users but not suspend them or see sensitive data by default', () {
      expect(hasPermissionForRole(role: 'SUPPORT', permission: 'users.view'), isTrue);
      expect(hasPermissionForRole(role: 'SUPPORT', permission: 'users.suspend'), isFalse);
      expect(hasPermissionForRole(role: 'SUPPORT', permission: 'users.unsuspend'), isFalse);
      expect(hasPermissionForRole(role: 'SUPPORT', permission: 'users.viewSecurityReport'), isFalse);
      expect(hasPermissionForRole(role: 'SUPPORT', permission: 'users.viewBettingHistory'), isFalse);
    });
  });

  group('hasPermissionForRole - view-only roles', () {
    for (final role in ['TECHNICAL', 'SUPPORT', 'CONTENT', 'MARKETING']) {
      test('$role has overview.view and search.view but not employees.* or audit.view by default', () {
        expect(hasPermissionForRole(role: role, permission: 'overview.view'), isTrue);
        expect(hasPermissionForRole(role: role, permission: 'search.view'), isTrue);
        expect(hasPermissionForRole(role: role, permission: 'employees.view'), isFalse);
        expect(hasPermissionForRole(role: role, permission: 'employees.manage'), isFalse);
        expect(hasPermissionForRole(role: role, permission: 'audit.view'), isFalse);
      });
    }
  });

  group('hasPermissionForRole - permission_overrides', () {
    test('an explicit true override grants a permission the role would not have by default', () {
      expect(
        hasPermissionForRole(
          role: 'SUPPORT',
          permission: 'employees.view',
          overrides: const {'employees.view': true},
        ),
        isTrue,
      );
    });

    test('an explicit false override revokes a permission the role would have by default', () {
      expect(
        hasPermissionForRole(
          role: 'ADMIN',
          permission: 'audit.view',
          overrides: const {'audit.view': false},
        ),
        isFalse,
      );
    });

    test('a missing override key falls back to the role default', () {
      expect(
        hasPermissionForRole(
          role: 'MARKETING',
          permission: 'overview.view',
          overrides: const {'search.view': false},
        ),
        isTrue,
      );
    });

    test('a non-bool override value is ignored and falls back to the role default', () {
      expect(
        hasPermissionForRole(
          role: 'MARKETING',
          permission: 'overview.view',
          overrides: const {'overview.view': 'yes'},
        ),
        isTrue,
      );
    });
  });
}
