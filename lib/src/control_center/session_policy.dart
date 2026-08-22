/// PHÖNIX CONTROL CENTER: Session-Regeln (Token-Erzeugung, Lebensdauer,
/// Gültigkeitsprüfung). Token-Erzeugung nutzt `Random.secure()` (kryptografisch
/// sicherer Zufallsgenerator), niemals eine Hash-Funktion über etwas
/// Erratbares.
library;

import 'dart:convert';
import 'dart:math';

/// Standard-Sitzungsdauer für Control-Center-Sessions.
const Duration kControlCenterSessionTtl = Duration(hours: 12);

/// Section 32 (AN2): "Rate Limits" für den Login - nach so vielen
/// fehlgeschlagenen Versuchen innerhalb des Zeitfensters wird ein Login für
/// denselben Login-Namen vorübergehend abgelehnt, unabhängig vom Passwort.
const Duration kLoginRateLimitWindow = Duration(minutes: 15);
const int kLoginRateLimitMaxAttempts = 10;

/// Erzeugt ein kryptografisch zufälliges Session-Token (32 Byte / 256 Bit
/// Entropie, hex-kodiert -> 64 Zeichen).
String generateSessionToken({int bytes = 32}) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64Url.encode(values).replaceAll('=', '');
}

/// Reine Gültigkeitsprüfung einer Session: nicht widerrufen und noch nicht
/// abgelaufen. Wird sowohl serverseitig per SQL (`WHERE expires_at > now()
/// AND revoked_at IS NULL`) als auch hier als zusätzliche, unabhängig
/// testbare Absicherung geprüft (defense in depth).
bool isSessionActive({
  required DateTime expiresAt,
  DateTime? revokedAt,
  required DateTime now,
}) {
  if (revokedAt != null) return false;
  return now.isBefore(expiresAt);
}
