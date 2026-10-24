import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Coût de la dérivation Argon2id du code PIN.
///
/// À régler sur de vrais téléphones d'entrée de gamme : le but est environ une
/// seconde par essai, pas plus (le coffre est testé deux fois à chaque
/// déverrouillage).
class KdfParams {
  const KdfParams({required this.opsLimit, required this.memLimit});

  final int opsLimit;
  final int memLimit;

  static const standard = KdfParams(opsLimit: 3, memLimit: 64 * 1024 * 1024);

  /// Minimum accepté par libsodium. Pour les tests uniquement.
  static const cheapForTests = KdfParams(opsLimit: 1, memLimit: 8 * 1024);
}

/// Toute la crypto du coffre passe par ici, et uniquement par libsodium.
class VaultCrypto {
  VaultCrypto._(this._sodium);

  final SodiumSumo _sodium;

  static const keyBytes = 32;

  static Future<VaultCrypto> create() async =>
      VaultCrypto._(await SodiumSumoInit.init());

  /// Pour les autres modules qui ont besoin de libsodium (maillage). Ils
  /// n'ouvrent pas leur propre instance : une seule initialisation par appli.
  SodiumSumo get sodium => _sodium;

  int get saltBytes => _sodium.crypto.pwhash.saltBytes;
  int get nonceBytes => _sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes;
  int get tagBytes => _sodium.crypto.aeadXChaCha20Poly1305IETF.aBytes;

  Uint8List randomBytes(int length) => _sodium.randombytes.buf(length);

  /// Argon2id(PIN, sel). C'est la part de la clé du coffre qui vient du code ;
  /// l'autre part est le secret du matériel ([mixHardwareSecret]). On la garde en
  /// mémoire tant que le coffre est ouvert pour pouvoir changer le secret matériel
  /// (renouvellement) sans redemander le code.
  ///
  /// Le calcul tourne dans un isolate : Argon2id bloquerait l'interface.
  Future<SecureKey> derivePinKey({
    required String pin,
    required Uint8List salt,
    KdfParams params = KdfParams.standard,
  }) async {
    final sodium = _sodium;
    final password = Int8List.fromList(utf8.encode(pin));
    try {
      return await sodium.runIsolated((_, _) {
        return sodium.crypto.pwhash(
          outLen: keyBytes,
          password: password,
          salt: salt,
          opsLimit: params.opsLimit,
          memLimit: params.memLimit,
          alg: CryptoPwhashAlgorithm.argon2id13,
        );
      });
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  /// Clé du coffre = BLAKE2b(Argon2id(PIN, sel), clé = secret matériel).
  SecureKey mixHardwareSecret(SecureKey pinKey, Uint8List hardwareSecret) {
    final sodium = _sodium;
    final hardwareKey = sodium.secureCopy(hardwareSecret);
    try {
      final mixed = pinKey.runUnlockedSync(
        (pinBytes) => sodium.crypto.genericHash(
          message: pinBytes,
          outLen: keyBytes,
          key: hardwareKey,
        ),
      );
      final vaultKey = sodium.secureCopy(mixed);
      mixed.fillRange(0, mixed.length, 0);
      return vaultKey;
    } finally {
      hardwareKey.dispose();
    }
  }

  /// Les deux étapes d'un coup, quand on n'a pas besoin de garder la première.
  Future<SecureKey> deriveVaultKey({
    required String pin,
    required Uint8List salt,
    required Uint8List hardwareSecret,
    KdfParams params = KdfParams.standard,
  }) async {
    final pinKey = await derivePinKey(pin: pin, salt: salt, params: params);
    try {
      return mixHardwareSecret(pinKey, hardwareSecret);
    } finally {
      pinKey.dispose();
    }
  }

  /// XChaCha20-Poly1305. Résultat : nonce (24 octets) puis chiffré avec son tag.
  Uint8List seal(
    SecureKey key,
    Uint8List plaintext, {
    Uint8List? associatedData,
  }) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = randomBytes(aead.nonceBytes);
    final cipher = aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: key,
      additionalData: associatedData,
    );
    return (BytesBuilder(copy: false)
          ..add(nonce)
          ..add(cipher))
        .toBytes();
  }

  /// Renvoie null si la clé est mauvaise ou si les données ont été modifiées.
  Uint8List? open(
    SecureKey key,
    Uint8List sealed, {
    Uint8List? associatedData,
  }) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    if (sealed.length < aead.nonceBytes + aead.aBytes) return null;
    try {
      return aead.decrypt(
        cipherText: Uint8List.sublistView(sealed, aead.nonceBytes),
        nonce: Uint8List.sublistView(sealed, 0, aead.nonceBytes),
        key: key,
        additionalData: associatedData,
      );
    } on SodiumException {
      return null;
    }
  }
}
