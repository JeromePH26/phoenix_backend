import 'package:phoenix_backend/src/accounts/firebase_id_token_verifier.dart';
import 'package:test/test.dart';

// Throwaway RSA keypair + self-signed X.509 cert generated locally with
// `openssl` purely for this test (kid "test-kid-1"). NOT a real Firebase
// key - only used to exercise verifyFirebaseIdTokenWithCerts()'s signature/
// claim checks without any network access.
const _testCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDETCCAfmgAwIBAgIUDDu8eXUPswMrzeXzCYo4qNVzckUwDQYJKoZIhvcNAQEL
BQAwFzEVMBMGA1UEAwwMcGhvZW5peC10ZXN0MCAXDTI2MDgxOTIwMTE1NFoYDzIx
MjYwNzI2MjAxMTU0WjAXMRUwEwYDVQQDDAxwaG9lbml4LXRlc3QwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDtkvk5BT/hEfpg9K8tkYLoyt27M6OTGLSd
nSPgT9GvMU5RxOPiegztSuJTY003co+4a97pDyUjzLke+60nwy5SybQgCRYliAzC
lNLHvdKamhWDG4yuJM4ttRZunh4WyyrAFIXlJImuDW436PLU7l9yFqpqDTQlJp7e
HYtbcpT3Tw1dbaLY+3LqPG2s8utabLFpMoJeQ4h/enWscv0mG8191UXunkrvV4QO
epSh9nzia4PkSMHyMn9BVpmFSmyd/mO82sYlgpq+NLmZSjlgTIFlvk9qoLIbjhxS
UhfZ/h4SGerWfnuuYkJTFQWTR1LNf8SZ2e2iSIHxAK3lu5Q/IzHBAgMBAAGjUzBR
MB0GA1UdDgQWBBTtrRPIW6mC7Up1ac6J/1Zergk9bjAfBgNVHSMEGDAWgBTtrRPI
W6mC7Up1ac6J/1Zergk9bjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUA
A4IBAQBcmPnQUCJ/67Xf6DYAQrNRNkCQlL+FsocosbQdogSJ+fhy2ZDewr+zXafK
9Vloed3a/0+CCP/6Xqa8Xo+EOcbVehJlwWiOHOWnB40XyP+fBkknLnnnMEbauqdK
at8Dvp/HDwLRGNsaf6ep90wU8+ky4o1yidE5Y031gCxS9dUM6HNeefoiSWdQvYxs
Vztk8v2vqAHLV7crHcFlsiwlzHr2ig/ouKon9kOBel9lNjaOqCGGn7pr4Ldbxv0V
M03IdnFsgQzOFi/LLbmFYbsiWOgWFBFDQIBPF3C39Vn4ZcpIsKEI3J3p5xwXjQQr
ds7JWh1nkIuoakFxA3Q95AMBYVHX
-----END CERTIFICATE-----
''';

const _certsByKeyId = {'test-kid-1': _testCertPem};
const _projectId = 'phoenix-test-project';

// exp far in the future (2030), so this stays valid regardless of when the
// test suite runs.
const _tokenValid =
    'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLTEifQ.eyJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vcGhvZW5peC10ZXN0LXByb2plY3QiLCJhdWQiOiJwaG9lbml4LXRlc3QtcHJvamVjdCIsInN1YiI6InRlc3QtdWlkLTEyMyIsImlhdCI6MTc1NTAwMDAwMCwiZXhwIjoxODkzNDU2MDAwLCJhdXRoX3RpbWUiOjE3NTUwMDAwMDAsImVtYWlsIjoidGVzdEBleGFtcGxlLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJmaXJlYmFzZSI6eyJzaWduX2luX3Byb3ZpZGVyIjoicGFzc3dvcmQifX0.KFFCi4sO4-EmikwjKGeFQXpVjw94eWnYtR_zwR4Qt2Jy9pGqE0l66Vc3qzpd-iFC970hQuPFxj2EZtEOWTAWdGk3otxUIJ6OrB65v2qomCm2MUjM2pc7zTU0gUKbsMukoFV6z7OMRgctjPZWMfnmvPCQQmHFE-MOn_-1mGvWQ7OyLw4t1kbr2uT7vwr5ZBCcnvQONXJsdc6T3qZx5-h77iqLA8H61sfUmAn8pnacWdd8Oklx--fte9Jcivcq-Qk6g5Bk4blRiAL0qXq-yCIbUUSf7r-SLe-gx5j48pcVIfDMPLWzeYOH7lRkyjEe4voDIFF5NnxkN74EqN9Oob_s-g';

const _tokenExpired =
    'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLTEifQ.eyJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vcGhvZW5peC10ZXN0LXByb2plY3QiLCJhdWQiOiJwaG9lbml4LXRlc3QtcHJvamVjdCIsInN1YiI6InRlc3QtdWlkLTEyMyIsImlhdCI6MTU3NzgwMDAwMCwiZXhwIjoxNTc3ODM2MDAwLCJhdXRoX3RpbWUiOjE1Nzc4MDAwMDAsImVtYWlsIjoidGVzdEBleGFtcGxlLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJmaXJlYmFzZSI6eyJzaWduX2luX3Byb3ZpZGVyIjoicGFzc3dvcmQifX0.V_jDBTfPQ5_x8RjE5BJ2pcvd0cPLLjOZ8gpM1zQkW4xMbGTuxIU00tFozIYeGmw7FycFRrJv2Ypw8k7gKTU_lzxwceMNs6vQAAz-J66y6BtpBscvNfm_X9JI7ab4RS-g1OKeN-ifHs20FnuAAbSttgHIS_IKZ8FIr7JSFoHGzUgmXYj98dc1P0a1eYiPnuvt6uZ9SATNOUGBgl9Hcz5LovxC-R4wVWBGGlNZknLrI3w3zAzocFJDt1oDuKOTh8XRgcsQnsv0yAW5pST_p2yKgnoUxkmmC0FdAc8mZ7CbR0WnwmZo0MhUBYMRhwVD6UciA0ny_q713VfnZKOLy67Ytg';

const _tokenWrongAudience =
    'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLTEifQ.eyJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vcGhvZW5peC10ZXN0LXByb2plY3QiLCJhdWQiOiJzb21lLW90aGVyLXByb2plY3QiLCJzdWIiOiJ0ZXN0LXVpZC0xMjMiLCJpYXQiOjE3NTUwMDAwMDAsImV4cCI6MTg5MzQ1NjAwMCwiYXV0aF90aW1lIjoxNzU1MDAwMDAwLCJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiZmlyZWJhc2UiOnsic2lnbl9pbl9wcm92aWRlciI6InBhc3N3b3JkIn19.LYherveeHTkDbrUcffbeimDplrCZtQ6f_9jXPu6p5UdZI2IlhmDhhmUsIyGYZfIU_QtDlThOOf6vBky2ERVenMmth__qWLhYeCvg8csQoFnQrYyW6MtoSLhHtha4yp9hiPMNV6FGSHs3zrLauSLt-IlNlVdlzXw-ByqHWIUT7EwkQI5M3RIXkpTO48mKqzW9tTFgGGnfwF7VH-igvBATyOx_nmHvmeJG3nekyH6QAuqOrB6idrN3CANjsuZAhnEfiujZt_5jA3l7a0MP2VkibGp4-ac5xWIOycZW5K6H0vVPYQSPc89ZH6vMbz4fHFvHmTKE_re5-p5G4G8sqB5Twg';

const _tokenWrongIssuer =
    'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLTEifQ.eyJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vc29tZS1vdGhlci1wcm9qZWN0IiwiYXVkIjoicGhvZW5peC10ZXN0LXByb2plY3QiLCJzdWIiOiJ0ZXN0LXVpZC0xMjMiLCJpYXQiOjE3NTUwMDAwMDAsImV4cCI6MTg5MzQ1NjAwMCwiYXV0aF90aW1lIjoxNzU1MDAwMDAwLCJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiZmlyZWJhc2UiOnsic2lnbl9pbl9wcm92aWRlciI6InBhc3N3b3JkIn19.owX-IeySwyFU2dZ0PiRG7uiMv7n6xP-UeOBkQzzjkspBOaITk0P8OA7Z6BkWAT-6yXv5eLjjmHaFWGYdgbZPRLklU2aLRlS9OkTTdcdz2dYoyokLo6Ip83eIM_S9RZVXJKiVjL-u510yAc_ZHenKs0iuOliOjq5FNq2UqahwNof5QbbOKQXA--H1At0ZBwLAiv0wtdXGO62sR21qU946MFqQhIipaRkcUPHzqJEWg_PAEeYC3kg4nRsI0T5T0nWWqOk61SpCethffoBBG5jF1xcrLZfK0XXmn4X7_3w7q6kZlxO2ltzz4VN4IhxBbcfGhXMdo58EcRuKAu_Bia8yAg';

const _tokenGoogleProvider =
    'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2lkLTEifQ.eyJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vcGhvZW5peC10ZXN0LXByb2plY3QiLCJhdWQiOiJwaG9lbml4LXRlc3QtcHJvamVjdCIsInN1YiI6InRlc3QtdWlkLTQ1NiIsImlhdCI6MTc1NTAwMDAwMCwiZXhwIjoxODkzNDU2MDAwLCJhdXRoX3RpbWUiOjE3NTUwMDAwMDAsImVtYWlsIjoiZ29vZ2xldXNlckBleGFtcGxlLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJmaXJlYmFzZSI6eyJzaWduX2luX3Byb3ZpZGVyIjoiZ29vZ2xlLmNvbSJ9fQ.wsa7uH-n2zVi9y5GMteqYHcS_U_4JFAdU48Rz3eXmWl3PBhY-tv4_CgIVV-8fNDiE61u1hngxeppr4Tc5AXKWehDxXSte-lp14wE5-nIqwi2Jk45v_NY-mJM-dYLAt_voewKxZWS98cYBYyZLxzH0PQ-lqEERKj0Eeq9GpbuisZuNqM4STiZewvpx9axnh5kCHmLgVK1OFVWq_zytyo_yGe5a4SBJ80gCGE8AI44-gksZd2G_svHFum4H4FeXErJxeJws9P3BcF54XN4SVXdw3_EeHgGVqyRxrh7Oo3lVfI3kovjQWhoCZvVvtYl4FkW7ECbjF4ZWCbzwvLsh2uC1Q';

void main() {
  group('verifyFirebaseIdTokenWithCerts - happy path', () {
    test('accepts a validly signed token with correct audience/issuer', () {
      final identity = verifyFirebaseIdTokenWithCerts(
        _tokenValid,
        projectId: _projectId,
        certificatesByKeyId: _certsByKeyId,
      );
      expect(identity.uid, 'test-uid-123');
      expect(identity.email, 'test@example.com');
      expect(identity.emailVerified, isTrue);
      expect(identity.signInProvider, 'password');
    });

    test('recognizes a Google sign-in provider token', () {
      final identity = verifyFirebaseIdTokenWithCerts(
        _tokenGoogleProvider,
        projectId: _projectId,
        certificatesByKeyId: _certsByKeyId,
      );
      expect(identity.uid, 'test-uid-456');
      expect(identity.signInProvider, 'google.com');
    });
  });

  group('verifyFirebaseIdTokenWithCerts - rejections', () {
    test('rejects an expired token', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          _tokenExpired,
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects a token with the wrong audience (different Firebase project)', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          _tokenWrongAudience,
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects a token with the wrong issuer', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          _tokenWrongIssuer,
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects when no certificate matches the token kid (key rotation / unknown key)', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          _tokenValid,
          projectId: _projectId,
          certificatesByKeyId: const {},
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects an empty token', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          '',
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects a garbage/non-JWT string', () {
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          'not-a-jwt-at-all',
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });

    test('rejects a token whose signature was tampered with', () {
      final tampered = '${_tokenValid.substring(0, _tokenValid.length - 4)}AAAA';
      expect(
        () => verifyFirebaseIdTokenWithCerts(
          tampered,
          projectId: _projectId,
          certificatesByKeyId: _certsByKeyId,
        ),
        throwsA(isA<FirebaseTokenException>()),
      );
    });
  });
}
