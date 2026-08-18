import 'package:phoenix_backend/src/control_center/control_center_auth_guard.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Deckt die Header-Validierung des Auth-Guards ab, die VOR jedem
/// Datenbankzugriff greift - ohne laufende Postgres-Instanz testbar (siehe
/// `PhoenixDatabase.isConfigured`/`connection()`, das ohne DATABASE_URL
/// einen StateError werfen würde). Der volle Token->Employee-Lookup selbst
/// braucht eine echte DB und ist hier bewusst nicht abgedeckt - siehe
/// Abschlussbericht.
void main() {
  final guard = ControlCenterAuthGuard(database: PhoenixDatabase(''));

  Request _requestWithAuthHeader(String? header) {
    return Request(
      'GET',
      Uri.parse('http://localhost/api/admin/control-center/auth/me'),
      headers: header == null ? const {} : {'authorization': header},
    );
  }

  group('ControlCenterAuthGuard.authenticate - 401 without touching the database', () {
    test('rejects a request with no Authorization header', () async {
      final outcome = await guard.authenticate(_requestWithAuthHeader(null));
      expect(outcome.isAuthenticated, isFalse);
      expect(outcome.unauthorizedResponse!.statusCode, 401);
    });

    test('rejects a header that is not a Bearer token', () async {
      final outcome = await guard.authenticate(_requestWithAuthHeader('Basic abc123'));
      expect(outcome.isAuthenticated, isFalse);
      expect(outcome.unauthorizedResponse!.statusCode, 401);
    });

    test('rejects an empty Bearer token', () async {
      final outcome = await guard.authenticate(_requestWithAuthHeader('Bearer '));
      expect(outcome.isAuthenticated, isFalse);
      expect(outcome.unauthorizedResponse!.statusCode, 401);
    });

    test('rejects a Bearer token that is only whitespace', () async {
      final outcome = await guard.authenticate(_requestWithAuthHeader('Bearer    '));
      expect(outcome.isAuthenticated, isFalse);
      expect(outcome.unauthorizedResponse!.statusCode, 401);
    });
  });
}
