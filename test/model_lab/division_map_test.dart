import 'package:phoenix_backend/src/model_lab/division_map.dart';
import 'package:test/test.dart';

void main() {
  group('kDivisionHints', () {
    test('every hint has a non-empty division code, country and keyword', () {
      for (final h in kDivisionHints) {
        expect(h.division, isNotEmpty);
        expect(h.country, isNotEmpty);
        expect(h.nameKeyword, isNotEmpty);
      }
    });

    test('division codes are unique', () {
      final codes = kDivisionHints.map((h) => h.division).toList();
      expect(codes.toSet().length, codes.length);
    });

    test('tiers, when present, are between 1 and 5', () {
      for (final h in kDivisionHints) {
        if (h.tier != null) {
          expect(h.tier, inInclusiveRange(1, 5));
        }
      }
    });

    test('covers the big-5 European first divisions', () {
      final codes = kDivisionHints.map((h) => h.division).toSet();
      expect(codes.containsAll({'E0', 'D1', 'SP1', 'I1', 'F1'}), isTrue);
    });
  });
}
