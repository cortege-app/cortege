import 'dart:convert';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late VaultCrypto crypto;
  late SodiumSumo sodium;
  const cheap = KdfParams.cheapForTests;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
    sodium = await SodiumSumoInit.init();
  });

  Future<SecureKey> keyFor(String pin, Uint8List salt, Uint8List hardware) =>
      crypto.deriveVaultKey(
        pin: pin,
        salt: salt,
        hardwareSecret: hardware,
        params: cheap,
      );

  group('chiffrement', () {
    test('aller-retour', () async {
      final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      final message = Uint8List.fromList(utf8.encode('rendez-vous place de la République'));
      final sealed = crypto.seal(key, message);
      expect(crypto.open(key, sealed), message);
    });

    test('deux chiffrements du même message sont différents', () {
      final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      final message = Uint8List.fromList(List.filled(64, 7));
      expect(crypto.seal(key, message), isNot(crypto.seal(key, message)));
    });

    test('mauvaise clé : refusé', () {
      final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
      final sealed = crypto.seal(aead.keygen(), Uint8List.fromList([1, 2, 3]));
      expect(crypto.open(aead.keygen(), sealed), isNull);
    });

    test('un octet modifié, où que ce soit : refusé', () {
      final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      final sealed = crypto.seal(key, Uint8List.fromList(List.filled(40, 9)));
      for (final index in [0, crypto.nonceBytes - 1, crypto.nonceBytes, sealed.length - 1]) {
        final broken = Uint8List.fromList(sealed)..[index] ^= 1;
        expect(crypto.open(key, broken), isNull, reason: 'octet $index');
      }
    });

    test('données trop courtes : refusé sans planter', () {
      final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      expect(crypto.open(key, Uint8List(5)), isNull);
    });

    test('données associées différentes : refusé', () {
      final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      final sealed = crypto.seal(
        key,
        Uint8List.fromList([1]),
        associatedData: Uint8List.fromList([1, 2]),
      );
      expect(
        crypto.open(key, sealed, associatedData: Uint8List.fromList([1, 3])),
        isNull,
      );
      expect(crypto.open(key, sealed), isNull);
    });
  });

  group('dérivation de la clé du coffre', () {
    late Uint8List salt;
    late Uint8List hardware;

    setUp(() {
      salt = crypto.randomBytes(crypto.saltBytes);
      hardware = crypto.randomBytes(32);
    });

    test('mêmes entrées, même clé', () async {
      final a = await keyFor('483920', salt, hardware);
      final b = await keyFor('483920', salt, hardware);
      expect(crypto.open(b, crypto.seal(a, Uint8List.fromList([4, 2]))), [4, 2]);
    });

    test('un autre PIN, un autre sel ou un autre secret matériel : clé différente', () async {
      final reference = await keyFor('483920', salt, hardware);
      final sealed = crypto.seal(reference, Uint8List.fromList([1]));
      final otherPin = await keyFor('483921', salt, hardware);
      final otherSalt = await keyFor(
        '483920',
        crypto.randomBytes(crypto.saltBytes),
        hardware,
      );
      final otherHardware = await keyFor('483920', salt, crypto.randomBytes(32));
      expect(crypto.open(otherPin, sealed), isNull);
      expect(crypto.open(otherSalt, sealed), isNull);
      expect(crypto.open(otherHardware, sealed), isNull);
    });

    test('c\'est bien BLAKE2b(Argon2id(PIN, sel), clé = secret matériel)', () async {
      final derived = await keyFor('483920', salt, hardware);
      final pinKey = sodium.crypto.pwhash(
        outLen: 32,
        password: Int8List.fromList(utf8.encode('483920')),
        salt: salt,
        opsLimit: cheap.opsLimit,
        memLimit: cheap.memLimit,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      final expected = sodium.secureCopy(
        pinKey.runUnlockedSync(
          (bytes) => sodium.crypto.genericHash(
            message: bytes,
            outLen: 32,
            key: sodium.secureCopy(hardware),
          ),
        ),
      );
      final sealed = crypto.seal(expected, Uint8List.fromList([5, 5, 5]));
      expect(crypto.open(derived, sealed), [5, 5, 5]);
    });
  });
}
