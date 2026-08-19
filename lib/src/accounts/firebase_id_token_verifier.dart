import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

/// PHÖNIX ACCOUNT SYSTEM (Abschnitt 7): Auth-Architektur.
///
///   Auth Provider (Firebase: Google / E-Mail+Passwort)
///     -> sicheres Token (Firebase ID Token, RS256-JWT)
///     -> PHÖNIX Railway Backend
///     -> Token validieren (DIESE Datei)
///     -> PHÖNIX User ID
///     -> PostgreSQL
///
/// Firebase Authentication verwaltet Passwörter/Google-Login/Token -
/// niemals ein Passwort oder Firebase-Secret in PostgreSQL. Dieses Modul
/// prüft AUSSCHLIESSLICH die Signatur/Gültigkeit eines vom Client
/// mitgeschickten Firebase-ID-Tokens gegen Googles öffentliche Zertifikate -
/// benötigt dafür keine geheimen Firebase-Credentials (nur die - nicht
/// geheime - `FIREBASE_PROJECT_ID`, die bereits für Push existiert).
class VerifiedFirebaseIdentity {
  const VerifiedFirebaseIdentity({
    required this.uid,
    required this.email,
    required this.emailVerified,
    required this.signInProvider,
  });

  /// Firebase UID - stabile, providerübergreifende Kennung dieses Nutzers
  /// innerhalb des Firebase-Projekts. Wird als `provider_uid` in
  /// `user_auth_providers` gespeichert.
  final String uid;
  final String? email;
  final bool emailVerified;

  /// z.B. 'google.com' oder 'password'.
  final String? signInProvider;
}

class FirebaseTokenException implements Exception {
  const FirebaseTokenException(this.message);
  final String message;

  @override
  String toString() => 'FirebaseTokenException: $message';
}

/// Reine, testbare Verifikationslogik OHNE Netzwerkzugriff - die Zertifikate
/// werden bereits aufgelöst übergeben (Kid -> PEM). Getrennt von
/// [FirebaseIdTokenVerifier], das die Zertifikate tatsächlich von Google
/// lädt/cached.
VerifiedFirebaseIdentity verifyFirebaseIdTokenWithCerts(
  String idToken, {
  required String projectId,
  required Map<String, String> certificatesByKeyId,
  DateTime? now,
}) {
  if (idToken.trim().isEmpty) {
    throw const FirebaseTokenException('Leeres Token.');
  }

  final unverified = JWT.tryDecode(idToken);
  if (unverified == null) {
    throw const FirebaseTokenException('Token konnte nicht dekodiert werden.');
  }

  final keyId = unverified.header?['kid']?.toString();
  if (keyId == null || keyId.isEmpty) {
    throw const FirebaseTokenException('Token hat keinen "kid"-Header.');
  }

  final algorithm = unverified.header?['alg']?.toString();
  if (algorithm != 'RS256') {
    throw FirebaseTokenException('Unerwarteter Algorithmus "$algorithm" (erwartet RS256).');
  }

  final certificate = certificatesByKeyId[keyId];
  if (certificate == null) {
    throw FirebaseTokenException(
      'Kein passendes öffentliches Zertifikat für kid="$keyId" gefunden.',
    );
  }

  final JWT verified;
  try {
    verified = JWT.verify(
      idToken,
      RSAPublicKey.cert(certificate),
      issuer: 'https://securetoken.google.com/$projectId',
      audience: Audience.one(projectId),
      // dart_jsonwebtoken vergleicht `checkExpiresIn` gegen die reale Zeit;
      // ein `now`-Override wird unten zusätzlich defensiv geprüft, damit
      // Tests mit einem festen Zeitpunkt deterministisch bleiben.
    );
  } on JWTExpiredException {
    throw const FirebaseTokenException('Token ist abgelaufen.');
  } on JWTException catch (error) {
    throw FirebaseTokenException('Token ungültig: ${error.message}');
  }

  final payload = verified.payload;
  if (payload is! Map) {
    throw const FirebaseTokenException('Token-Payload hat ein unerwartetes Format.');
  }

  final at = now ?? DateTime.now();
  final authTime = payload['auth_time'];
  if (authTime is num) {
    final authAt = DateTime.fromMillisecondsSinceEpoch(
      (authTime * 1000).round(),
      isUtc: true,
    );
    if (authAt.isAfter(at.toUtc().add(const Duration(minutes: 5)))) {
      throw const FirebaseTokenException('Token liegt in der Zukunft (auth_time).');
    }
  }

  final uid = verified.subject ?? payload['user_id']?.toString();
  if (uid == null || uid.isEmpty) {
    throw const FirebaseTokenException('Token hat kein "sub"/"user_id"-Feld.');
  }

  final firebaseClaims = payload['firebase'];
  final signInProvider = firebaseClaims is Map
      ? firebaseClaims['sign_in_provider']?.toString()
      : null;

  return VerifiedFirebaseIdentity(
    uid: uid,
    email: payload['email']?.toString(),
    emailVerified: payload['email_verified'] == true,
    signInProvider: signInProvider,
  );
}

/// Lädt Googles öffentliche Firebase-Auth-Zertifikate (Kid -> X.509-PEM) mit
/// einfachem In-Memory-Cache. Kein Secret nötig - dieser Endpunkt ist
/// öffentlich (dieselbe Quelle, die Firebase Admin SDKs verwenden).
class FirebaseIdTokenVerifier {
  FirebaseIdTokenVerifier({required this.projectId, http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  static const _certsUrl =
      'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';

  final String projectId;
  final http.Client _client;

  Map<String, String>? _cachedCerts;
  DateTime? _cachedUntil;

  Future<VerifiedFirebaseIdentity> verify(String idToken) async {
    var certs = await _certs();

    final unverified = JWT.tryDecode(idToken);
    final keyId = unverified?.header?['kid']?.toString();
    // Schlüsselrotation: falls der kid unbekannt ist, einmal zwangsweise neu
    // laden statt sofort abzulehnen.
    if (keyId != null && !certs.containsKey(keyId)) {
      certs = await _certs(forceRefresh: true);
    }

    return verifyFirebaseIdTokenWithCerts(
      idToken,
      projectId: projectId,
      certificatesByKeyId: certs,
    );
  }

  Future<Map<String, String>> _certs({bool forceRefresh = false}) async {
    final cached = _cachedCerts;
    final until = _cachedUntil;
    if (!forceRefresh &&
        cached != null &&
        until != null &&
        DateTime.now().isBefore(until)) {
      return cached;
    }

    final response = await _client.get(Uri.parse(_certsUrl));
    if (response.statusCode != 200) {
      throw FirebaseTokenException(
        'Zertifikate konnten nicht geladen werden (HTTP ${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FirebaseTokenException('Unerwartete Zertifikatsantwort.');
    }
    final certs = decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    _cachedCerts = certs;
    _cachedUntil = DateTime.now().add(const Duration(hours: 1));
    return certs;
  }
}
