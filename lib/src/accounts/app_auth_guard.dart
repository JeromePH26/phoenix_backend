import 'package:shelf/shelf.dart';

import '../control_center/session_policy.dart';
import '../database/database.dart';

/// Ergebnis von [AppAuthGuard.authenticate]: entweder ein authentifizierter
/// Nutzer (inkl. der um den User-Kontext erweiterten Request) oder eine
/// fertige 401-Antwort. Struktur bewusst identisch zu
/// `ControlCenterAuthOutcome` - zwei komplett getrennte Auth-Systeme
/// (Abschnitt 93: bestehende Control-Center-Auth bleibt unangetastet), aber
/// mit demselben Muster.
class AppAuthOutcome {
  AppAuthOutcome._({this.userRow, this.request, this.unauthorizedResponse});

  factory AppAuthOutcome.ok(Map<String, Object?> userRow, Request request) =>
      AppAuthOutcome._(userRow: userRow, request: request);

  factory AppAuthOutcome.unauthorized([String reason = 'Nicht angemeldet oder Session abgelaufen.']) =>
      AppAuthOutcome._(
        unauthorizedResponse: Response(
          401,
          body: '{"error":"$reason"}',
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

  final Map<String, Object?>? userRow;
  final Request? request;
  final Response? unauthorizedResponse;

  bool get isAuthenticated => userRow != null;
}

/// PHÖNIX App-Auth-Guard: prüft `Authorization: Bearer <phoenix-session-token>`
/// gegen `user_sessions` (NICHT den Firebase-ID-Token direkt - der wird nur
/// einmalig bei `/auth/register` bzw. `/auth/session` verifiziert, um eine
/// PHÖNIX-Session auszustellen; siehe `firebase_id_token_verifier.dart` für
/// die Begründung). Zusätzlich werden gesperrte/gelöschte Accounts hier
/// zentral abgewiesen (Abschnitt 94: "Ein gesperrter User darf nicht durch
/// Staff/Premiumlogik versehentlich Zugriff bekommen" - gilt sinngemäß auch
/// für normale API-Zugriffe).
class AppAuthGuard {
  AppAuthGuard({required this.database});

  final PhoenixDatabase database;

  static const String contextKey = 'appUser';

  Future<AppAuthOutcome> authenticate(Request request) async {
    final header = request.headers['authorization'] ?? '';
    if (!header.startsWith('Bearer ')) {
      return AppAuthOutcome.unauthorized();
    }
    final token = header.substring('Bearer '.length).trim();
    if (token.isEmpty) return AppAuthOutcome.unauthorized();

    final row = await database.userSessionWithProfile(token);
    if (row == null) return AppAuthOutcome.unauthorized();

    final expiresAt = _asDateTime(row['session_expires_at']);
    if (expiresAt == null) return AppAuthOutcome.unauthorized();
    final revokedAt = _asDateTime(row['session_revoked_at']);

    if (!isSessionActive(
      expiresAt: expiresAt,
      revokedAt: revokedAt,
      now: DateTime.now().toUtc(),
    )) {
      return AppAuthOutcome.unauthorized();
    }

    final changedRequest = request.change(context: {contextKey: row});
    return AppAuthOutcome.ok(row, changedRequest);
  }

  DateTime? _asDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}

/// Standard-Sitzungsdauer für App-Sessions. Deutlich länger als
/// Control-Center-Sessions (12h) - normale Nutzer sollen nicht täglich neu
/// einloggen müssen; die zugrunde liegende Firebase-Anmeldung bleibt ohnehin
/// bestehen, diese Session ist nur unsere eigene, widerrufbare
/// Geräte-/Zugriffsschicht darüber (Abschnitt 78).
const Duration kAppSessionTtl = Duration(days: 30);
