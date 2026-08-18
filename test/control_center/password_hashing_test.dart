import 'package:bcrypt/bcrypt.dart';
import 'package:test/test.dart';

/// Deckt den Passwort-Baustein von `POST /auth/login` ab, ohne eine
/// laufende Postgres-Instanz zu benötigen: `ControlCenterRoutes._login`
/// nutzt exakt `BCrypt.hashpw`/`BCrypt.checkpw` auf dieselbe Weise.
void main() {
  group('bcrypt password hashing (used by POST /auth/login)', () {
    test('the correct password verifies successfully against its hash', () {
      final hash = BCrypt.hashpw('correct horse battery staple', BCrypt.gensalt());
      expect(BCrypt.checkpw('correct horse battery staple', hash), isTrue);
    });

    test('an incorrect password is rejected', () {
      final hash = BCrypt.hashpw('correct horse battery staple', BCrypt.gensalt());
      expect(BCrypt.checkpw('wrong password', hash), isFalse);
    });

    test('hashing the same password twice yields different hashes (random salt)', () {
      final first = BCrypt.hashpw('same password', BCrypt.gensalt());
      final second = BCrypt.hashpw('same password', BCrypt.gensalt());
      expect(first, isNot(equals(second)));
      expect(BCrypt.checkpw('same password', first), isTrue);
      expect(BCrypt.checkpw('same password', second), isTrue);
    });

    test('the stored hash never equals the plaintext password', () {
      final hash = BCrypt.hashpw('hunter2', BCrypt.gensalt());
      expect(hash, isNot(equals('hunter2')));
      expect(hash, contains(r'$2'));
    });
  });
}
