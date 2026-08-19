import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../accounts/age_gate.dart';
import '../accounts/app_auth_guard.dart';
import '../accounts/firebase_id_token_verifier.dart';
import '../config/app_config.dart';
import '../control_center/session_policy.dart';
import '../database/database.dart';
import '../http/json_response.dart';

/// PHÖNIX ACCOUNT SYSTEM (Abschnitt 91 "USER"-API-Liste, additiv). Öffentlich
/// erreichbar wie `/api/support/*`/`/api/push/*` (kein PHOENIX_ADMIN_TOKEN
/// nötig) - Authentifizierung läuft stattdessen entweder über ein frisches
/// Firebase-ID-Token (nur `/auth/register`) oder eine bereits ausgestellte
/// PHÖNIX-App-Session (`Authorization: Bearer <user_sessions.token>`, siehe
/// [AppAuthGuard]).
class AppAccountRoutes {
  AppAccountRoutes({required this.config, required this.database, FirebaseIdTokenVerifier? verifier})
      : _verifier = verifier ??
            (config.firebaseProjectId.isEmpty
                ? null
                : FirebaseIdTokenVerifier(projectId: config.firebaseProjectId));

  final AppConfig config;
  final PhoenixDatabase database;
  final FirebaseIdTokenVerifier? _verifier;

  Router get router {
    final router = Router();
    final guard = AppAuthGuard(database: database);

    // Abschnitt 5-8/84: Registrierung ODER Account-Linking in einem
    // Endpunkt - der Client hat sich bereits bei Firebase angemeldet
    // (Google oder E-Mail+Passwort) und schickt dessen ID-Token mit.
    router.post('/auth/register', (Request request) async {
      final verifier = _verifier;
      if (verifier == null) {
        return jsonResponse({
          'error': 'Anmeldung ist noch nicht eingerichtet (FIREBASE_PROJECT_ID fehlt).',
        }, statusCode: 503);
      }

      final authHeader = request.headers['authorization'] ?? '';
      if (!authHeader.startsWith('Bearer ')) {
        return jsonResponse({'error': 'Firebase-ID-Token fehlt.'}, statusCode: 401);
      }
      final idToken = authHeader.substring('Bearer '.length).trim();

      final VerifiedFirebaseIdentity identity;
      try {
        identity = await verifier.verify(idToken);
      } on FirebaseTokenException catch (error) {
        return jsonResponse({'error': error.message}, statusCode: 401);
      }

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        body = decoded is Map<String, dynamic> ? decoded : {};
      } catch (_) {
        body = {};
      }

      // Bereits verknüpft (z.B. erneuter /register-Aufruf durch einen Retry,
      // Abschnitt 84) -> einfach anmelden statt Fehler.
      final existingByProvider = await database.userByAuthProvider(
        provider: _providerKey(identity.signInProvider),
        providerUid: identity.uid,
      );
      if (existingByProvider != null) {
        return _issueSession(request, existingByProvider);
      }

      final email = identity.email;
      if (email == null || email.isEmpty) {
        return jsonResponse({
          'error': 'Der Auth-Provider hat keine E-Mail-Adresse geliefert.',
        }, statusCode: 400);
      }

      // Abschnitt 6: E-Mail bereits bekannt -> Account Linking statt
      // Doppel-Account. Keine erneute Altersprüfung (Account existiert
      // bereits, war schon 18+ bei der ursprünglichen Registrierung).
      final existingByEmail = await database.userByEmail(email);
      if (existingByEmail != null) {
        await database.linkAuthProvider(
          userId: existingByEmail['id'] as int,
          provider: _providerKey(identity.signInProvider),
          providerUid: identity.uid,
          emailAtLink: email,
        );
        return _issueSession(request, existingByEmail);
      }

      // Ab hier: wirklich neue Registrierung. Abschnitt 3: Altersprüfung
      // VOR jeder Account-Erstellung, serverseitig berechnet.
      final dobRaw = body['dateOfBirth']?.toString();
      final dateOfBirth = dobRaw == null ? null : DateTime.tryParse(dobRaw);
      if (dateOfBirth == null) {
        return jsonResponse({
          'error': 'dateOfBirth (YYYY-MM-DD) ist erforderlich.',
        }, statusCode: 400);
      }
      if (!passesAgeGate(dateOfBirth)) {
        return jsonResponse({
          'error': 'PHÖNIX ist ausschließlich für Personen ab 18 Jahren verfügbar.',
          'code': 'AGE_GATE_FAILED',
        }, statusCode: 403);
      }

      final created = await database.createUserAccount(
        email: email,
        emailVerified: identity.emailVerified,
        dateOfBirth: dateOfBirth,
        provider: _providerKey(identity.signInProvider),
        providerUid: identity.uid,
        termsVersion: body['termsVersion']?.toString(),
        privacyVersion: body['privacyVersion']?.toString(),
      );
      return _issueSession(request, created, statusCode: 201);
    });

    // Abschnitt 91 "me": eigenes Profil.
    router.get('/me', (Request request) async {
      final outcome = await guard.authenticate(request);
      if (!outcome.isAuthenticated) return outcome.unauthorizedResponse!;
      return jsonResponse({'user': _publicProfile(outcome.userRow!)});
    });

    // Abschnitt 91 "update allowed profile fields".
    router.patch('/me', (Request request) async {
      final outcome = await guard.authenticate(request);
      if (!outcome.isAuthenticated) return outcome.unauthorizedResponse!;
      final userId = outcome.userRow!['id'] as int;

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
        }
        body = decoded;
      } catch (_) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }

      final username = body['username']?.toString().trim();
      if (username != null && username.isNotEmpty) {
        if (!_isValidUsername(username)) {
          return jsonResponse({
            'error':
                'Ungültiger Benutzername (3-20 Zeichen, Buchstaben/Zahlen/Unterstrich, muss mit einem Buchstaben beginnen).',
          }, statusCode: 400);
        }
        if (_isReservedUsername(username)) {
          return jsonResponse({
            'error': 'Dieser Benutzername ist reserviert.',
          }, statusCode: 409);
        }
        // Abschnitt 10: konfigurierbare Änderungssperre.
        final lastChanged = _asDateTime(outcome.userRow!['username_changed_at']);
        if (lastChanged != null &&
            DateTime.now().toUtc().isBefore(lastChanged.toUtc().add(kUsernameChangeCooldown))) {
          return jsonResponse({
            'error': 'Der Benutzername kann erst wieder ab '
                '${lastChanged.toUtc().add(kUsernameChangeCooldown).toIso8601String()} geändert werden.',
          }, statusCode: 409);
        }
        if (await database.isUsernameTaken(username, excludingUserId: userId)) {
          return jsonResponse({'error': 'Benutzername bereits vergeben.'}, statusCode: 409);
        }
      }

      Map<String, Object?>? notificationSettings;
      final rawSettings = body['notificationSettings'];
      if (rawSettings is Map) {
        notificationSettings = Map<String, Object?>.from(rawSettings);
      }

      final updated = await database.updateOwnUserProfile(
        userId: userId,
        username: (username != null && username.isNotEmpty) ? username : null,
        displayName: body['displayName']?.toString().trim(),
        language: body['language']?.toString().trim(),
        country: body['country']?.toString().trim(),
        notificationSettings: notificationSettings,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Nutzer nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse({'user': _publicProfile(updated)});
    });

    router.get('/sessions', (Request request) async {
      final outcome = await guard.authenticate(request);
      if (!outcome.isAuthenticated) return outcome.unauthorizedResponse!;
      final sessions = await database.listUserSessions(outcome.userRow!['id'] as int);
      return jsonResponse({'sessions': sessions.map(_jsonSafe).toList()});
    });

    // Abschnitt 78: "Alle anderen Geräte abmelden".
    router.post('/sessions/revoke-others', (Request request) async {
      final outcome = await guard.authenticate(request);
      if (!outcome.isAuthenticated) return outcome.unauthorizedResponse!;
      final currentToken =
          (request.headers['authorization'] ?? '').substring('Bearer '.length).trim();
      await database.revokeOtherUserSessions(
        userId: outcome.userRow!['id'] as int,
        exceptToken: currentToken,
      );
      return jsonResponse({'status': 'ok'});
    });

    router.post('/auth/logout', (Request request) async {
      final outcome = await guard.authenticate(request);
      if (!outcome.isAuthenticated) return outcome.unauthorizedResponse!;
      final currentToken =
          (request.headers['authorization'] ?? '').substring('Bearer '.length).trim();
      await database.revokeUserSession(currentToken);
      return jsonResponse({'status': 'ok'});
    });

    return router;
  }

  Future<Response> _issueSession(
    Request request,
    Map<String, Object?> userRow, {
    int statusCode = 200,
  }) async {
    final userId = userRow['id'] as int;
    final token = generateSessionToken();
    await database.createUserSession(
      userId: userId,
      token: token,
      expiresAt: DateTime.now().toUtc().add(kAppSessionTtl),
      ip: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      userAgent: request.headers['user-agent'],
      deviceModel: request.headers['x-phoenix-device-model'],
      platform: request.headers['x-phoenix-platform'],
      appVersion: request.headers['x-phoenix-app-version'],
    );
    await database.touchUserLastLogin(userId);
    final fresh = await database.userById(userId) ?? userRow;
    return jsonResponse({
      'sessionToken': token,
      'expiresAt': DateTime.now().toUtc().add(kAppSessionTtl).toIso8601String(),
      'user': _publicProfile(fresh),
    }, statusCode: statusCode);
  }

  /// Firebase liefert den Sign-in-Provider als `google.com`/`password` -
  /// wir speichern es kurz als `google`/`password` (siehe CHECK-Constraint
  /// auf `user_auth_providers.provider`).
  String _providerKey(String? firebaseProvider) {
    if (firebaseProvider == 'google.com') return 'google';
    return 'password';
  }

  static final RegExp _usernamePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]{2,19}$');

  bool _isValidUsername(String username) => _usernamePattern.hasMatch(username);

  static const Set<String> _reservedUsernames = {
    'admin', 'administrator', 'owner', 'phoenix', 'support', 'moderator',
    'mod', 'staff', 'system', 'root', 'security', 'help', 'official',
  };

  bool _isReservedUsername(String username) =>
      _reservedUsernames.contains(username.toLowerCase());

  DateTime? _asDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  /// Abschnitt 80: KEIN Raw-Dump der DB-Zeile an den Client - nur die
  /// tatsächlich für die App relevanten Felder, mit sprechenden JSON-Keys.
  Map<String, Object?> _publicProfile(Map<String, Object?> row) => {
    'phoenixUserId': row['phoenix_user_id'],
    'accountType': row['account_type'],
    'email': row['email'],
    'emailVerified': row['email_verified'],
    'username': row['username'],
    'displayName': row['display_name'],
    'dateOfBirth': _dateOnly(row['date_of_birth']),
    'accountStatus': row['account_status'],
    'language': row['language'],
    'country': row['country'],
    'termsVersion': row['terms_version'],
    'privacyVersion': row['privacy_version'],
    'trialAvailable': row['trial_available'],
    'trialUsed': row['trial_used'],
    'notificationSettings': row['notification_settings'],
    'createdAt': _jsonSafe(row['created_at']),
    'lastLoginAt': _jsonSafe(row['last_login_at']),
  };

  Object? _dateOnly(Object? value) {
    if (value == null) return null;
    return value.toString().substring(0, 10);
  }

  Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _jsonSafe(item)));
    }
    if (value is Iterable) return value.map(_jsonSafe).toList();
    return value.toString();
  }
}

/// Abschnitt 10: konfigurierbare Änderungssperre für Benutzernamen.
const Duration kUsernameChangeCooldown = Duration(days: 30);
