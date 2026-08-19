import 'package:phoenix_backend/src/accounts/premium_entitlements.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 8, 19);

  group('effectivePremium (Abschnitt 29)', () {
    test('no entitlements at all -> false', () {
      expect(effectivePremium(const [], now: now), isFalse);
    });

    test('Google Play false, Manual true -> effective premium true (Abschnitt 29 Beispiel)', () {
      final entitlements = [
        const PremiumEntitlement(source: PremiumSource.googlePlay, active: false),
        const PremiumEntitlement(source: PremiumSource.manual, active: true),
      ];
      expect(effectivePremium(entitlements, now: now), isTrue);
    });

    test('an expired entitlement does not count', () {
      final entitlements = [
        PremiumEntitlement(
          source: PremiumSource.googlePlay,
          active: true,
          expiresAt: now.subtract(const Duration(days: 1)),
        ),
      ];
      expect(effectivePremium(entitlements, now: now), isFalse);
    });

    test('an entitlement without expiresAt (permanent) counts', () {
      const entitlements = [
        PremiumEntitlement(source: PremiumSource.manual, active: true),
      ];
      expect(effectivePremium(entitlements, now: now), isTrue);
    });

    test('a not-yet-expired entitlement counts', () {
      final entitlements = [
        PremiumEntitlement(
          source: PremiumSource.website,
          active: true,
          expiresAt: now.add(const Duration(days: 1)),
        ),
      ];
      expect(effectivePremium(entitlements, now: now), isTrue);
    });

    test(
      'STAFF source never counts as effective (paying) premium, even if active (Abschnitt 29)',
      () {
        const entitlements = [
          PremiumEntitlement(source: PremiumSource.staff, active: true),
        ];
        expect(effectivePremium(entitlements, now: now), isFalse);
      },
    );
  });

  group('hasFullAppAccess (Abschnitt 17/29)', () {
    test('staffAppAccess=true grants full access with zero entitlements', () {
      expect(
        hasFullAppAccess(const [], staffAppAccess: true, now: now),
        isTrue,
      );
    });

    test('staffAppAccess=false with an active paid entitlement grants access', () {
      const entitlements = [
        PremiumEntitlement(source: PremiumSource.manual, active: true),
      ];
      expect(
        hasFullAppAccess(entitlements, staffAppAccess: false, now: now),
        isTrue,
      );
    });

    test('staffAppAccess=false with no entitlements denies access', () {
      expect(
        hasFullAppAccess(const [], staffAppAccess: false, now: now),
        isFalse,
      );
    });
  });

  group('PremiumSource.fromKey', () {
    test('resolves every known key', () {
      for (final source in PremiumSource.values) {
        expect(PremiumSource.fromKey(source.key), source);
      }
    });

    test('unknown key returns null', () {
      expect(PremiumSource.fromKey('UNKNOWN'), isNull);
    });
  });
}
