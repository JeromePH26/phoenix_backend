// PHÖNIX CONTROL CENTER PHASE 2: `PATCH /api/admin/football/matches/<id>`
// baut den `admin_audit_log`-Eintrag aus zwei reinen Bausteinen zusammen:
// `parseMatchFlagsPatch()` (dieses Feature) und `diffEmployeeFields()`
// (wiederverwendet aus Phase 1, `lib/src/control_center/audit.dart`). Es gibt
// in dieser Sandbox kein Postgres, daher kann `insertAdminAuditLog()` selbst
// nicht end-to-end getestet werden (siehe Testkonventionen in
// `test/control_center/`) - dieser Test deckt stattdessen exakt die Logik ab,
// die die Route vor dem DB-Aufruf ausführt: aus dem vorherigen Zustand plus
// dem validierten Patch wird ein previousValue/newValue-Diff, der nur die
// tatsächlich geänderten Flags enthält.
import 'package:phoenix_backend/src/control_center/audit.dart';
import 'package:phoenix_backend/src/football_admin/football_admin_logic.dart';
import 'package:test/test.dart';

void main() {
  group('match flags PATCH -> audit log diff', () {
    test('a partial update only records the changed flag(s)', () {
      final patch = parseMatchFlagsPatch({
        'visible': false,
        'reason': 'Kurzfristig abgesagt',
      });
      expect(patch.isValid, isTrue);

      // Simuliert das, was updateFootballMatchFlags() als "vorher" aus der
      // DB liest, bevor die Spalten überschrieben werden.
      final previousFromDb = <String, Object?>{'visible': true};

      final diff = diffEmployeeFields(
        before: previousFromDb,
        after: patch.flags,
      );

      expect(diff.previousValue, {'visible': true});
      expect(diff.newValue, {'visible': false});
      expect(patch.reason, 'Kurzfristig abgesagt');
    });

    test('a multi-flag update records only the flags that actually changed',
        () {
      final patch = parseMatchFlagsPatch({
        'analysisEnabled': false,
        'tipEnabled': false,
        'liveEnabled': true, // unchanged vs. previous state below
      });
      expect(patch.isValid, isTrue);

      final previousFromDb = <String, Object?>{
        'analysis_enabled': true,
        'tip_enabled': true,
        'live_enabled': true,
      };

      final diff = diffEmployeeFields(
        before: previousFromDb,
        after: patch.flags,
      );

      // live_enabled did not actually change -> must not appear in the diff.
      expect(diff.previousValue.containsKey('live_enabled'), isFalse);
      expect(diff.newValue.containsKey('live_enabled'), isFalse);

      expect(diff.previousValue, {
        'analysis_enabled': true,
        'tip_enabled': true,
      });
      expect(diff.newValue, {
        'analysis_enabled': false,
        'tip_enabled': false,
      });
    });

    test('a no-op update (new value equals old value) yields an empty diff',
        () {
      final patch = parseMatchFlagsPatch({'learningEnabled': true});
      final previousFromDb = <String, Object?>{'learning_enabled': true};

      final diff = diffEmployeeFields(
        before: previousFromDb,
        after: patch.flags,
      );

      expect(diff.previousValue, isEmpty);
      expect(diff.newValue, isEmpty);
    });

    test('an invalid patch never reaches the diff/audit stage', () {
      final patch = parseMatchFlagsPatch({'visible': 'not-a-bool'});
      expect(patch.isValid, isFalse);
      expect(patch.flags, isEmpty);
    });
  });
}
