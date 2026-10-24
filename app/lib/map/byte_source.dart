import 'dart:io';
import 'dart:typed_data';

/// Une source d'octets à accès direct : un fichier, ou un fichier chiffré, lu
/// par morceaux. Le fichier de tuiles est lu par petits bouts, jamais en entier.
abstract class ByteSource {
  /// Taille totale en octets.
  int get length;

  /// Lit [count] octets à partir de [offset]. Lève [RangeError] au-delà de la fin.
  Future<Uint8List> read(int offset, int count);

  Future<void> close();
}

class MemoryByteSource implements ByteSource {
  MemoryByteSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > _bytes.length) {
      throw RangeError('lecture hors du fichier : $offset + $count sur ${_bytes.length}');
    }
    return Uint8List.sublistView(_bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {}
}

class FileByteSource implements ByteSource {
  FileByteSource._(this._file, this.length);

  final RandomAccessFile _file;

  @override
  final int length;

  static Future<FileByteSource> open(File file) async {
    final handle = await file.open();
    return FileByteSource._(handle, await handle.length());
  }

  // Un fichier ouvert n'accepte qu'une opération à la fois : plusieurs tuiles
  // se chargent en parallèle, leurs lectures passent donc l'une après l'autre.
  Future<void> _queue = Future<void>.value();

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
    await _file.setPosition(offset);
    final bytes = Uint8List(count);
    var done = 0;
    while (done < count) {
      final got = await _file.readInto(bytes, done, count);
      if (got <= 0) throw const FileSystemException('fichier tronqué');
      done += got;
    }
    return bytes;
  }

  var _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.close();
  }
}
