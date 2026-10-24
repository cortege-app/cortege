import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../crypto/vault_crypto.dart';

/// Crypto du maillage : dérivations de clés, signatures, remplissage. Tout
/// vient de libsodium (BLAKE2b avec clé, Ed25519, XChaCha20-Poly1305).
class MeshCrypto {
  MeshCrypto(this._vault) : _sodium = _vault.sodium;

  final VaultCrypto _vault;
  final SodiumSumo _sodium;

  static const signatureBytes = 64;
  static const publicKeyBytes = 32;
  static const padBlock = 64;

  Uint8List randomBytes(int length) => _vault.randomBytes(length);

  SecureKey secure(Uint8List bytes) => _sodium.secureCopy(bytes);

  /// Dérive [length] octets de [key], séparés par [label]. Deux étiquettes
  /// différentes ne donnent jamais des valeurs liées entre elles.
  Uint8List derive(SecureKey key, String label, int length, [Uint8List? extra]) {
    final message = BytesBuilder(copy: false)
      ..add(Uint8List.fromList('cortege/$label'.codeUnits))
      ..add(extra ?? Uint8List(0));
    final out = _sodium.crypto.genericHash(
      message: message.toBytes(),
      outLen: math.max(length, _sodium.crypto.genericHash.bytesMin),
      key: key,
    );
    return length == out.length ? out : Uint8List.fromList(out.sublist(0, length));
  }

  /// Empreinte sans clé, pour identifier une trame.
  Uint8List hash(Uint8List data, int length) => _sodium.crypto.genericHash(
        message: data,
        outLen: math.max(length, _sodium.crypto.genericHash.bytesMin),
      ).sublist(0, length);

  /// Empreinte BLAKE2b sur 256 bits d'un fichier, lu par morceaux (une carte peut
  /// peser des centaines de mégaoctets).
  /// Empreinte d'un fichier, ou d'une partie : [length] octets à partir de [start].
  Future<Uint8List> hashFile(
    File file, {
    int start = 0,
    int? length,
    void Function(int bytes)? onBytes,
  }) async {
    final consumer = _sodium.crypto.genericHash.createConsumer(outLen: 32);
    await for (final chunk in file.openRead(start, length == null ? null : start + length)) {
      consumer.add(Uint8List.fromList(chunk));
      onBytes?.call(chunk.length);
    }
    return consumer.close();
  }

  KeyPair newSigningKeyPair() => _sodium.crypto.sign.keyPair();

  Uint8List sign(Uint8List message, SecureKey secretKey) =>
      _sodium.crypto.sign.detached(message: message, secretKey: secretKey);

  bool verify(Uint8List message, Uint8List signature, Uint8List publicKey) {
    if (signature.length != signatureBytes || publicKey.length != publicKeyBytes) {
      return false;
    }
    try {
      return _sodium.crypto.sign.verifyDetached(
        message: message,
        signature: signature,
        publicKey: publicKey,
      );
    } on SodiumException {
      return false;
    }
  }

  Uint8List seal(SecureKey key, Uint8List plain, Uint8List aad) =>
      _vault.seal(key, plain, associatedData: aad);

  Uint8List? open(SecureKey key, Uint8List sealed, Uint8List aad) =>
      _vault.open(key, sealed, associatedData: aad);

  /// XChaCha20-Poly1305 avec un nonce imposé. À réserver aux clés qui ne
  /// servent qu'une fois (chaîne du binôme) : réutiliser un nonce avec la même
  /// clé détruirait la confidentialité.
  Uint8List sealWithNonce(SecureKey key, Uint8List nonce, Uint8List plain, Uint8List aad) =>
      _sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plain,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );

  Uint8List? openWithNonce(SecureKey key, Uint8List nonce, Uint8List cipher, Uint8List aad) {
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipher,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
    } on SodiumException {
      return null;
    }
  }

  KeyPair newBoxKeyPair() => _sodium.crypto.box.keyPair();

  /// Boîte scellée (X25519 + XSalsa20-Poly1305) : n'importe qui peut écrire à
  /// [publicKey], seul le détenteur de la clé secrète peut lire.
  Uint8List boxSeal(Uint8List message, Uint8List publicKey) =>
      _sodium.crypto.box.seal(message: message, publicKey: publicKey);

  Uint8List? boxSealOpen(Uint8List cipher, Uint8List publicKey, SecureKey secretKey) {
    if (cipher.length < _sodium.crypto.box.sealBytes) return null;
    try {
      return _sodium.crypto.box.sealOpen(
        cipherText: cipher,
        publicKey: publicKey,
        secretKey: secretKey,
      );
    } on SodiumException {
      return null;
    }
  }

  int get boxPublicKeyBytes => _sodium.crypto.box.publicKeyBytes;
  int get boxSealBytes => _sodium.crypto.box.sealBytes;

  Uint8List pad(Uint8List data) => _sodium.pad(data, padBlock);

  Uint8List? unpad(Uint8List data) {
    try {
      return _sodium.unpad(data, padBlock);
    } on SodiumException {
      return null;
    }
  }

  int get nonceBytes => _vault.nonceBytes;
  int get tagBytes => _vault.tagBytes;
}
