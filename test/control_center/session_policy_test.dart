import 'package:phoenix_backend/src/control_center/session_policy.dart';
import 'package:test/test.dart';

void main() {
  group('generateSessionToken', () {
    test('produces a non-empty, sufficiently long token', () {
      final token = generateSessionToken();
      expect(token, isNotEmpty);
      expect(token.length, greaterThanOrEqualTo(32));
    });

    test('produces different tokens on each call (cryptographically random)', () {
      final tokens = List.generate(50, (_) => generateSessionToken());
      expect(tokens.toSet().length, tokens.length);
    });
  });

  group('isSessionActive', () {
    final now = DateTime.utc(2026, 8, 18, 12);

    test('a session with a future expiry and no revocation is active', () {
      expect(
        isSessionActive(
          expiresAt: now.add(const Duration(hours: 1)),
          revokedAt: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('an expired session is rejected', () {
      expect(
        isSessionActive(
          expiresAt: now.subtract(const Duration(seconds: 1)),
          revokedAt: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('a session expiring exactly now is rejected (not before is required)', () {
      expect(
        isSessionActive(expiresAt: now, revokedAt: null, now: now),
        isFalse,
      );
    });

    test('a revoked session is rejected even if not yet expired', () {
      expect(
        isSessionActive(
          expiresAt: now.add(const Duration(hours: 1)),
          revokedAt: now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });
  });

  test('kControlCenterSessionTtl defaults to 12 hours', () {
    expect(kControlCenterSessionTtl, const Duration(hours: 12));
  });
}
