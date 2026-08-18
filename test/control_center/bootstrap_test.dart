import 'package:phoenix_backend/src/control_center/bootstrap.dart';
import 'package:test/test.dart';

void main() {
  group('shouldBootstrap', () {
    test('runs when the employee table is empty and bootstrap config is present', () {
      expect(
        shouldBootstrap(employeeTableIsEmpty: true, hasBootstrapConfig: true),
        isTrue,
      );
    });

    test('never runs when the employee table already has rows, even with full config', () {
      expect(
        shouldBootstrap(employeeTableIsEmpty: false, hasBootstrapConfig: true),
        isFalse,
      );
    });

    test('does not run when the table is empty but bootstrap env vars are missing', () {
      expect(
        shouldBootstrap(employeeTableIsEmpty: true, hasBootstrapConfig: false),
        isFalse,
      );
    });

    test('does not run when neither condition holds', () {
      expect(
        shouldBootstrap(employeeTableIsEmpty: false, hasBootstrapConfig: false),
        isFalse,
      );
    });
  });
}
