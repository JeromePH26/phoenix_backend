import 'package:phoenix_backend/src/accounts/age_gate.dart';
import 'package:test/test.dart';

void main() {
  final reference = DateTime(2026, 8, 19);

  group('calculateAge', () {
    test('exact 18th birthday counts as 18', () {
      expect(calculateAge(DateTime(2008, 8, 19), asOf: reference), 18);
    });

    test('one day before 18th birthday still counts as 17', () {
      expect(calculateAge(DateTime(2008, 8, 20), asOf: reference), 17);
    });

    test('birthday already passed this year', () {
      expect(calculateAge(DateTime(2000, 1, 1), asOf: reference), 26);
    });

    test('birthday not yet reached this year', () {
      expect(calculateAge(DateTime(2000, 12, 31), asOf: reference), 25);
    });
  });

  group('passesAgeGate (Abschnitt 3: mindestens 18 Jahre, exakt geprueft)', () {
    test('17 years 364 days -> rejected', () {
      expect(
        passesAgeGate(DateTime(2008, 8, 20), asOf: reference),
        isFalse,
      );
    });

    test('exactly 18 -> allowed', () {
      expect(
        passesAgeGate(DateTime(2008, 8, 19), asOf: reference),
        isTrue,
      );
    });

    test('well above 18 -> allowed', () {
      expect(
        passesAgeGate(DateTime(1990, 1, 1), asOf: reference),
        isTrue,
      );
    });

    test('well below 18 -> rejected', () {
      expect(
        passesAgeGate(DateTime(2015, 1, 1), asOf: reference),
        isFalse,
      );
    });
  });
}
