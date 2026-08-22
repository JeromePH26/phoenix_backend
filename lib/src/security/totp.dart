/// Section 32 (AN2, "Priorität hoch"): TOTP-2FA (RFC 6238) für
/// Control-Center-Mitarbeiter. Reine Standard-Implementierung auf Basis von
/// HMAC-SHA1 (package:crypto, bereits eine bestehende Abhängigkeit) - keine
/// neue externe Abhängigkeit nötig. Kompatibel mit Google
/// Authenticator/Authy/1Password etc. (30s-Schritt, 6 Stellen, SHA1 -
/// derselbe Standard, den praktisch jede Authenticator-App unterstützt).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Erzeugt ein neues, kryptografisch zufälliges 160-Bit-Secret (20 Byte,
/// die von RFC 4226/6238 empfohlene Länge für HMAC-SHA1), Base32-kodiert
/// (das Format, das Authenticator-Apps für die manuelle Eingabe erwarten).
String generateTotpSecret() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(List<int>.generate(20, (_) => random.nextInt(256)));
  return base32Encode(bytes);
}

String base32Encode(Uint8List bytes) {
  final buffer = StringBuffer();
  var bitBuffer = 0;
  var bitCount = 0;
  for (final byte in bytes) {
    bitBuffer = (bitBuffer << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      buffer.write(_base32Alphabet[(bitBuffer >> bitCount) & 0x1F]);
    }
  }
  if (bitCount > 0) {
    buffer.write(_base32Alphabet[(bitBuffer << (5 - bitCount)) & 0x1F]);
  }
  return buffer.toString();
}

Uint8List base32Decode(String input) {
  final cleaned = input.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
  final output = <int>[];
  var bitBuffer = 0;
  var bitCount = 0;
  for (final char in cleaned.split('')) {
    final value = _base32Alphabet.indexOf(char);
    if (value < 0) continue;
    bitBuffer = (bitBuffer << 5) | value;
    bitCount += 5;
    if (bitCount >= 8) {
      bitCount -= 8;
      output.add((bitBuffer >> bitCount) & 0xFF);
    }
  }
  return Uint8List.fromList(output);
}

/// otpauth://-URL für die manuelle Secret-Eingabe (kein QR-Code nötig -
/// jede gängige Authenticator-App bietet "Schlüssel manuell eingeben" an).
String totpAuthUrl({required String secret, required String accountLogin, String issuer = 'PHOENIX Control Center'}) {
  final label = Uri.encodeComponent('$issuer:$accountLogin');
  final encodedIssuer = Uri.encodeComponent(issuer);
  return 'otpauth://totp/$label?secret=$secret&issuer=$encodedIssuer&algorithm=SHA1&digits=6&period=30';
}

int _hotp(Uint8List key, int counter) {
  final counterBytes = ByteData(8)..setUint64(0, counter, Endian.big);
  final hmac = Hmac(sha1, key);
  final digest = hmac.convert(counterBytes.buffer.asUint8List()).bytes;
  final offset = digest[digest.length - 1] & 0x0F;
  final binary = ((digest[offset] & 0x7F) << 24) |
      ((digest[offset + 1] & 0xFF) << 16) |
      ((digest[offset + 2] & 0xFF) << 8) |
      (digest[offset + 3] & 0xFF);
  return binary % 1000000;
}

String _formatCode(int code) => code.toString().padLeft(6, '0');

/// Der aktuell gültige 6-stellige Code für ein Base32-Secret.
String currentTotpCode(String base32Secret, {DateTime? at}) {
  final now = at ?? DateTime.now().toUtc();
  final counter = now.millisecondsSinceEpoch ~/ 1000 ~/ 30;
  return _formatCode(_hotp(base32Decode(base32Secret), counter));
}

/// Prüft einen vom Nutzer eingegebenen Code gegen das Secret. `window`
/// erlaubt eine kleine Zeitabweichung (Uhr des Telefons vs. Server) - ±1
/// Schritt (±30s) ist der übliche Toleranzbereich.
bool verifyTotpCode(String base32Secret, String code, {int window = 1, DateTime? at}) {
  final cleanCode = code.trim();
  if (cleanCode.length != 6 || int.tryParse(cleanCode) == null) return false;
  final now = at ?? DateTime.now().toUtc();
  final counter = now.millisecondsSinceEpoch ~/ 1000 ~/ 30;
  final key = base32Decode(base32Secret);
  for (var offset = -window; offset <= window; offset++) {
    if (_formatCode(_hotp(key, counter + offset)) == cleanCode) return true;
  }
  return false;
}
