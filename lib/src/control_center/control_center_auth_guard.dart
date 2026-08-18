import 'package:shelf/shelf.dart';

import '../database/database.dart';
import 'employee.dart';
import 'session_policy.dart';

/// Ergebnis von [ControlCenterAuthGuard.authenticate]: entweder ein
/// authentifizierter Mitarbeiter (inkl. der um den Employee-Kontext
/// erweiterten Request, `request.change(context: ...)`) oder eine fertige
/// 401-Antwort.
class ControlCenterAuthOutcome {
  ControlCenterAuthOutcome._({this.employee, this.request, this.unauthorizedResponse});

  factory ControlCenterAuthOutcome.ok(Employee employee, Request request) =>
      ControlCenterAuthOutcome._(employee: employee, request: request);

  factory ControlCenterAuthOutcome.unauthorized() =>
      ControlCenterAuthOutcome._(
        unauthorizedResponse: Response(
          401,
          body: '{"error":"Nicht angemeldet oder Session abgelaufen."}',
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

  final Employee? employee;
  final Request? request;
  final Response? unauthorizedResponse;

  bool get isAuthenticated => employee != null;
}

/// PHÖNIX CONTROL CENTER Auth-Guard: prüft `Authorization: Bearer
/// <session-token>` gegen `admin_sessions`, lädt den zugehörigen
/// `admin_employees`-Datensatz und verlangt `status = 'active'`. Komplett
/// separat vom bestehenden statischen `PHOENIX_ADMIN_TOKEN`-Mechanismus.
class ControlCenterAuthGuard {
  ControlCenterAuthGuard({required this.database});

  final PhoenixDatabase database;

  static const String contextKey = 'ccEmployee';

  Future<ControlCenterAuthOutcome> authenticate(Request request) async {
    final header = request.headers['authorization'] ?? '';
    if (!header.startsWith('Bearer ')) {
      return ControlCenterAuthOutcome.unauthorized();
    }
    final token = header.substring('Bearer '.length).trim();
    if (token.isEmpty) return ControlCenterAuthOutcome.unauthorized();

    final row = await database.adminSessionWithEmployee(token);
    if (row == null) return ControlCenterAuthOutcome.unauthorized();

    final expiresAt = _asDateTime(row['session_expires_at']);
    if (expiresAt == null) return ControlCenterAuthOutcome.unauthorized();
    final revokedAt = _asDateTime(row['session_revoked_at']);

    if (!isSessionActive(
      expiresAt: expiresAt,
      revokedAt: revokedAt,
      now: DateTime.now().toUtc(),
    )) {
      return ControlCenterAuthOutcome.unauthorized();
    }

    final employee = Employee.fromRow(row);
    if (!employee.isActive) return ControlCenterAuthOutcome.unauthorized();

    final changedRequest = request.change(
      context: {contextKey: employee},
    );
    return ControlCenterAuthOutcome.ok(employee, changedRequest);
  }

  DateTime? _asDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}
