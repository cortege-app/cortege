import 'dart:io';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import '../mesh/mesh_crypto.dart';
import 'byte_source.dart';

/// Le fichier de carte chiffré est altéré, tronqué ou n'a pas la bonne clé.
class EncryptedMapException implements Exception {
  EncryptedMapException(this.message);

  final String message;

  @override
  String toString() => 'EncryptedMapException($message)';
}

/// La carte hors ligne ne reste pas en clair dans le téléphone : elle montre la
/// zone d'un événement. Le fichier est découpé en morceaux de 64 Kio chiffrés
/// un par un (XChaCha20-Poly1305), ce qui permet de lire n'importe quel passage
/// sans tout déchiffrer. La clé vit dans le coffre : quand le coffre efface
/// l'événement, le fichier devient illisible même s'il reste sur le disque.
///
///     octets 0 à 3     « CTM1 »
///     octets 4 à 7     taille d'un morceau (entier, petit-boutiste)
///     octets 8 à 15    taille du fichier d'origine
///     octets 16 à 31   identifiant du fichier (au hasard)
///     ensuite          morceaux : chiffré + 16 octets d'étiquette
///
/// Le nonce d'un morceau est l'identifiant du fichier suivi du numéro du
/// morceau, et les 32 premiers octets servent de données authentifiées : on ne
/// peut ni réordonner les morceaux ni les mélanger avec ceux d'un autre fichier.
class EncryptedMap {
  static const magic = [0x43, 0x54, 0x4d, 0x31]; // « CTM1 »
  static const headerLength = 32;
  static const chunkSize = 64 * 1024;
  static const tagLength = 16;

  static Uint8List _nonce(Uint8List fileId, int index) {
    final nonce = Uint8List(24)..setRange(0, 16, fileId);
    ByteData.sublistView(nonce).setUint64(16, index, Endian.little);
    return nonce;
  }

  /// Chiffre [source] vers [target], morceau par morceau, et rend la taille des
  /// octets en clair. Avec [start] et [length], seule cette partie du fichier est
  /// prise : la carte jointe à un fichier d'événement.
  static Future<int> encrypt({
    required MeshCrypto crypto,
    required File source,
    required File target,
    required Uint8List keyBytes,
    int start = 0,
    int? length,
    void Function(int done, int total)? onProgress,
  }) async {
    final input = await source.open();
    final tmp = File('${target.path}.tmp');
    final output = await tmp.open(mode: FileMode.write);
    final key = crypto.secure(keyBytes);
    try {
      final total = length ?? (await input.length() - start);
      if (total < 0) throw EncryptedMapException('partie hors du fichier');
      await input.setPosition(start);
      final fileId = crypto.randomBytes(16);
      final header = Uint8List(headerLength)..setRange(0, 4, magic);
      ByteData.sublistView(header)
        ..setUint32(4, chunkSize, Endian.little)
        ..setUint64(8, total, Endian.little);
      header.setRange(16, 32, fileId);
      await output.writeFrom(header);
      var index = 0;
      var done = 0;
      while (done < total) {
        final want = total - done < chunkSize ? total - done : chunkSize;
        final plain = Uint8List(want);
        var got = 0;
        while (got < want) {
          final n = await input.readInto(plain, got, want);
          if (n <= 0) throw EncryptedMapException('fichier source tronqué');
          got += n;
        }
        await output.writeFrom(crypto.sealWithNonce(key, _nonce(fileId, index), plain, header));
        plain.fillRange(0, plain.length, 0);
        index++;
        done += want;
        onProgress?.call(done, total);
      }
      await output.flush();
      await output.close();
      await tmp.rename(target.path);
      return total;
    } catch (_) {
      try {
        await output.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } finally {
      key.dispose();
      await input.close();
    }
  }
}

/// Lit un fichier de carte chiffré comme s'il était en clair.
class EncryptedByteSource implements ByteSource {
  EncryptedByteSource._(this._file, this._crypto, this._key, this._header, this.length, this._fileId);

  final RandomAccessFile _file;
  final MeshCrypto _crypto;
  final SecureKey _key;
  final Uint8List _header;
  final Uint8List _fileId;
  final _cache = <int, Uint8List>{};
  Future<void> _queue = Future<void>.value();

  @override
  final int length;

  static Future<EncryptedByteSource> open(File file, Uint8List keyBytes, MeshCrypto crypto) async {
    final handle = await file.open();
    try {
      final fileLength = await handle.length();
      if (fileLength < EncryptedMap.headerLength) throw EncryptedMapException('fichier trop court');
      final header = Uint8List(EncryptedMap.headerLength);
      await handle.setPosition(0);
      var got = 0;
      while (got < header.length) {
        final n = await handle.readInto(header, got, header.length);
        if (n <= 0) throw EncryptedMapException('fichier tronqué');
        got += n;
      }
      for (var i = 0; i < 4; i++) {
        if (header[i] != EncryptedMap.magic[i]) throw EncryptedMapException('ce n\'est pas une carte chiffrée');
      }
      final view = ByteData.sublistView(header);
      final chunk = view.getUint32(4, Endian.little);
      final plainLength = view.getUint64(8, Endian.little);
      if (chunk != EncryptedMap.chunkSize) throw EncryptedMapException('taille de morceau inattendue');
      final chunks = (plainLength + chunk - 1) ~/ chunk;
      final expected = EncryptedMap.headerLength + plainLength + chunks * EncryptedMap.tagLength;
      if (fileLength != expected) throw EncryptedMapException('fichier tronqué ou rallongé');
      return EncryptedByteSource._(
        handle,
        crypto,
        crypto.secure(keyBytes),
        header,
        plainLength,
        Uint8List.fromList(header.sublist(16, 32)),
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  @override
  Future<Uint8List> read(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > length) {
      throw RangeError('lecture hors du fichier : $offset + $count sur $length');
    }
    final result = _queue.then((_) => _readNow(offset, count));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _readNow(int offset, int count) async {
    final out = Uint8List(count);
    if (count == 0) return out;
    var written = 0;
    final first = offset ~/ EncryptedMap.chunkSize;
    final last = (offset + count - 1) ~/ EncryptedMap.chunkSize;
    for (var index = first; index <= last; index++) {
      final plain = await _chunk(index);
      final from = index == first ? offset - index * EncryptedMap.chunkSize : 0;
      final to = index == last ? (offset + count) - index * EncryptedMap.chunkSize : plain.length;
      out.setRange(written, written + (to - from), plain, from);
      written += to - from;
    }
    return out;
  }

  Future<Uint8List> _chunk(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final start = index * EncryptedMap.chunkSize;
    final plainLength = length - start < EncryptedMap.chunkSize ? length - start : EncryptedMap.chunkSize;
    final sealedLength = plainLength + EncryptedMap.tagLength;
    await _file.setPosition(EncryptedMap.headerLength + index * (EncryptedMap.chunkSize + EncryptedMap.tagLength));
    final sealed = Uint8List(sealedLength);
    var got = 0;
    while (got < sealedLength) {
      final n = await _file.readInto(sealed, got, sealedLength);
      if (n <= 0) throw EncryptedMapException('fichier tronqué');
      got += n;
    }
    final nonce = Uint8List(24)..setRange(0, 16, _fileId);
    ByteData.sublistView(nonce).setUint64(16, index, Endian.little);
    final plain = _crypto.openWithNonce(_key, nonce, sealed, _header);
    if (plain == null) throw EncryptedMapException('morceau $index altéré ou mauvaise clé');
    _cache[index] = plain;
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
    return plain;
  }

  var _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _key.dispose();
    _cache.clear();
    await _file.close();
  }
}
