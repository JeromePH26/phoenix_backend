import 'package:phoenix_backend/src/control_center/audit.dart';
import 'package:test/test.dart';

void main() {
  group('diffEmployeeFields', () {
    test('only includes keys whose value actually changed', () {
      final diff = diffEmployeeFields(
        before: {'role': 'SUPPORT', 'department': 'Sales', 'status': 'active'},
        after: {'role': 'ADMIN', 'department': 'Sales', 'status': 'active'},
      );
      expect(diff.previousValue, {'role': 'SUPPORT'});
      expect(diff.newValue, {'role': 'ADMIN'});
    });

    test('reports an empty diff when nothing changed', () {
      final diff = diffEmployeeFields(
        before: {'role': 'SUPPORT'},
        after: {'role': 'SUPPORT'},
      );
      expect(diff.previousValue, isEmpty);
      expect(diff.newValue, isEmpty);
    });

    test('treats structurally-equal nested maps as unchanged', () {
      final diff = diffEmployeeFields(
        before: {
          'permissionOverrides': {'employees.view': true, 'audit.view': false},
        },
        after: {
          'permissionOverrides': {'audit.view': false, 'employees.view': true},
        },
      );
      expect(diff.previousValue, isEmpty);
      expect(diff.newValue, isEmpty);
    });

    test('detects a changed nested map', () {
      final diff = diffEmployeeFields(
        before: {
          'permissionOverrides': {'employees.view': true},
        },
        after: {
          'permissionOverrides': {'employees.view': false},
        },
      );
      expect(diff.previousValue.containsKey('permissionOverrides'), isTrue);
      expect(diff.newValue.containsKey('permissionOverrides'), isTrue);
    });
  });
}
