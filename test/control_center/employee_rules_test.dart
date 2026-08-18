import 'package:phoenix_backend/src/control_center/employee_rules.dart';
import 'package:test/test.dart';

void main() {
  group('canAssignRole', () {
    test('only OWNER can assign the OWNER role', () {
      expect(canAssignRole(actorRole: 'OWNER', targetRole: 'OWNER'), isTrue);
      expect(canAssignRole(actorRole: 'ADMIN', targetRole: 'OWNER'), isFalse);
      expect(canAssignRole(actorRole: 'TECHNICAL', targetRole: 'OWNER'), isFalse);
    });

    test('any actor with employees.manage can assign a non-OWNER role', () {
      expect(canAssignRole(actorRole: 'ADMIN', targetRole: 'SUPPORT'), isTrue);
      expect(canAssignRole(actorRole: 'ADMIN', targetRole: 'TECHNICAL'), isTrue);
    });
  });

  group('canModifyEmployeeRow', () {
    test('non-OWNER cannot modify an OWNER row', () {
      expect(
        canModifyEmployeeRow(actorRole: 'ADMIN', targetCurrentRole: 'OWNER'),
        isFalse,
      );
    });

    test('OWNER can modify another OWNER row', () {
      expect(
        canModifyEmployeeRow(actorRole: 'OWNER', targetCurrentRole: 'OWNER'),
        isTrue,
      );
    });

    test('any actor can modify a non-OWNER row', () {
      expect(
        canModifyEmployeeRow(actorRole: 'ADMIN', targetCurrentRole: 'SUPPORT'),
        isTrue,
      );
    });
  });

  group('wouldRemoveLastActiveOwner', () {
    test('blocks disabling the sole active owner', () {
      expect(
        wouldRemoveLastActiveOwner(
          targetIsOwner: true,
          targetCurrentlyActive: true,
          activeOwnerCount: 1,
        ),
        isTrue,
      );
    });

    test('allows disabling an owner when other active owners remain', () {
      expect(
        wouldRemoveLastActiveOwner(
          targetIsOwner: true,
          targetCurrentlyActive: true,
          activeOwnerCount: 2,
        ),
        isFalse,
      );
    });

    test('does not block disabling a non-owner regardless of owner count', () {
      expect(
        wouldRemoveLastActiveOwner(
          targetIsOwner: false,
          targetCurrentlyActive: true,
          activeOwnerCount: 1,
        ),
        isFalse,
      );
    });

    test('does not block an already-disabled owner (no-op disable)', () {
      expect(
        wouldRemoveLastActiveOwner(
          targetIsOwner: true,
          targetCurrentlyActive: false,
          activeOwnerCount: 1,
        ),
        isFalse,
      );
    });
  });
}
