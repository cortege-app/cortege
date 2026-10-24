import 'dart:io';
import 'dart:typed_data';

import 'byte_source.dart';

/// Le fichier n'est pas un PMTiles lisible (mauvais format, compression non
/// prise en charge, répertoire abîmé).
class PmtilesException implements Exception {
  PmtilesException(this.message);

  final String message;

  @override
  String toString() => 'PmtilesException($message)';
}

enum PmtilesCompression { unknown, none, gzip, brotli, zstd }

/// L'en-tête d'un fichier PMTiles version 3 (127 octets).
class PmtilesHeader {
  PmtilesHeader._({
    required this.rootOffset,
    required this.rootLength,
    required this.metadataOffset,
    required this.metadataLength,
    required this.leafOffset,
    required this.leafLength,
    required this.tileDataOffset,
    required this.tileDataLength,
    required this.clustered,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
    required this.centerZoom,
    required this.centerLon,
    required this.centerLat,
  });

  static const length = 127;
  static const tileTypeMvt = 1;

  final int rootOffset;
  final int rootLength;
  final int metadataOffset;
  final int metadataLength;
  final int leafOffset;
  final int leafLength;
  final int tileDataOffset;
  final int tileDataLength;

  /// Les tuiles sont rangées dans l'ordre de leur numéro : lire une zone revient
  /// à lire des morceaux de fichier d'un seul tenant.
  final bool clustered;
  final PmtilesCompression internalCompression;
  final PmtilesCompression tileCompression;
  final int tileType;
  final int minZoom;
  final int maxZoom;

  /// Emprise des données, en degrés.
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final int centerZoom;
  final double centerLon;
  final double centerLat;

  factory PmtilesHeader.parse(Uint8List bytes) {
    if (bytes.length < length) throw PmtilesException('en-tête trop court');
    const magic = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73]; // "PMTiles"
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw PmtilesException('ce n\'est pas un fichier PMTiles');
    }
    if (bytes[7] != 3) throw PmtilesException('version ${bytes[7]} non prise en charge');
    final view = ByteData.sublistView(bytes);
    int u64(int at) => view.getUint64(at, Endian.little);
    double degrees(int at) => view.getInt32(at, Endian.little) / 1e7;
    PmtilesCompression compression(int value) =>
        value >= 0 && value < PmtilesCompression.values.length
            ? PmtilesCompression.values[value]
            : PmtilesCompression.unknown;
    return PmtilesHeader._(
      rootOffset: u64(8),
      rootLength: u64(16),
      metadataOffset: u64(24),
      metadataLength: u64(32),
      leafOffset: u64(40),
      leafLength: u64(48),
      tileDataOffset: u64(56),
      tileDataLength: u64(64),
      clustered: bytes[96] == 1,
      internalCompression: compression(bytes[97]),
      tileCompression: compression(bytes[98]),
      tileType: bytes[99],
      minZoom: bytes[100],
      maxZoom: bytes[101],
      minLon: degrees(102),
      minLat: degrees(106),
      maxLon: degrees(110),
      maxLat: degrees(114),
      centerZoom: bytes[118],
      centerLon: degrees(119),
      centerLat: degrees(123),
    );
  }
}

/// Une ligne d'un répertoire : où se trouvent les octets de la tuile [tileId]
/// (et des [runLength] - 1 suivantes, qui ont le même contenu).
class PmtilesEntry {
  PmtilesEntry(this.tileId, this.offset, this.length, this.runLength);

  final int tileId;
  final int offset;
  final int length;

  /// 0 : l'entrée pointe vers un répertoire de second niveau.
  final int runLength;
}

/// Numéro d'une tuile sur la courbe de Hilbert, comme dans la spécification
/// PMTiles : les tuiles voisines ont des numéros voisins, ce qui permet de ranger
/// un fichier par ordre de lecture.
int zxyToTileId(int z, int x, int y) {
  if (z < 0 || z > 26) throw PmtilesException('zoom $z hors limites');
  final n = 1 << z;
  if (x < 0 || y < 0 || x >= n || y >= n) throw PmtilesException('tuile $z/$x/$y hors du zoom');
  var acc = 0;
  for (var t = 0; t < z; t++) {
    acc += 1 << (2 * t);
  }
  var d = 0;
  var tx = x;
  var ty = y;
  for (var s = n ~/ 2; s > 0; s ~/= 2) {
    final rx = (tx & s) > 0 ? 1 : 0;
    final ry = (ty & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry == 0) {
      if (rx == 1) {
        tx = s - 1 - tx;
        ty = s - 1 - ty;
      }
      final swap = tx;
      tx = ty;
      ty = swap;
    }
  }
  return acc + d;
}

/// L'inverse de [zxyToTileId] : (zoom, x, y).
(int, int, int) tileIdToZxy(int id) {
  var acc = 0;
  for (var z = 0; z < 27; z++) {
    final count = 1 << (2 * z);
    if (acc + count > id) {
      final n = 1 << z;
      var t = id - acc;
      var x = 0;
      var y = 0;
      for (var s = 1; s < n; s *= 2) {
        final rx = 1 & (t ~/ 2);
        final ry = 1 & (t ^ rx);
        if (ry == 0) {
          if (rx == 1) {
            x = s - 1 - x;
            y = s - 1 - y;
          }
          final swap = x;
          x = y;
          y = swap;
        }
        x += s * rx;
        y += s * ry;
        t ~/= 4;
      }
      return (z, x, y);
    }
    acc += count;
  }
  throw PmtilesException('numéro de tuile $id hors limites');
}

/// Le fichier de carte vient d'un organisateur de confiance, mais un fichier
/// abîmé ou piégé ne doit pas pouvoir remplir la mémoire du téléphone : un petit
/// morceau compressé peut se gonfler de plusieurs centaines de fois. Ces limites
/// sont très au-dessus de ce que produit une vraie carte (une tuile pèse quelques
/// centaines de Ko, un répertoire quelques dizaines).
const maxTileCompressedBytes = 16 * 1024 * 1024;
const maxTilePlainBytes = 64 * 1024 * 1024;
const maxDirectoryCompressedBytes = 16 * 1024 * 1024;
const maxDirectoryPlainBytes = 64 * 1024 * 1024;

/// Reçoit ce que décompresse zlib, morceau par morceau, et s'arrête dès que la
/// limite est dépassée : la décompression ne remplit jamais la mémoire.
class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit, this.what);

  final int limit;
  final String what;
  final out = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (out.length + chunk.length > limit) {
      throw PmtilesException('$what trop gros une fois décompressé (plus de ${limit ~/ (1024 * 1024)} Mo)');
    }
    out.add(chunk);
  }

  @override
  void close() {}
}

/// Décompresse du gzip sans dépasser [limit] octets. Les données illisibles et
/// les dépassements lèvent tous deux [PmtilesException].
Uint8List _gunzip(Uint8List raw, int limit, String what) {
  final sink = _BoundedSink(limit, what);
  try {
    final input = gzip.decoder.startChunkedConversion(sink);
    input.add(raw);
    input.close();
  } on FormatException {
    throw PmtilesException('$what : données compressées illisibles');
  }
  return sink.out.takeBytes();
}

/// Un fichier PMTiles ouvert. On ne lit que ce qu'il faut : l'en-tête, le
/// répertoire racine, puis la tuile demandée. Aucun accès au réseau.
class PmtilesArchive {
  PmtilesArchive._(this._source, this.header, this._root);

  final ByteSource _source;
  final PmtilesHeader header;
  final List<PmtilesEntry> _root;
  final _leaves = <int, List<PmtilesEntry>>{};

  static Future<PmtilesArchive> open(ByteSource source) async {
    if (source.length < PmtilesHeader.length) throw PmtilesException('fichier trop court');
    final header = PmtilesHeader.parse(await source.read(0, PmtilesHeader.length));
    if (header.tileType != PmtilesHeader.tileTypeMvt) {
      throw PmtilesException('seules les tuiles vectorielles (MVT) sont prises en charge');
    }
    if (header.tileCompression != PmtilesCompression.gzip &&
        header.tileCompression != PmtilesCompression.none) {
      throw PmtilesException('compression des tuiles non prise en charge');
    }
    final root = await readDirectory(source, header, header.rootOffset, header.rootLength);
    return PmtilesArchive._(source, header, root);
  }

  Future<void> close() => _source.close();

  /// Les octets décompressés de la tuile, ou null si le fichier ne la contient pas.
  Future<Uint8List?> tile(int z, int x, int y) async {
    if (z < header.minZoom || z > header.maxZoom) return null;
    final id = zxyToTileId(z, x, y);
    var directory = _root;
    for (var depth = 0; depth < 4; depth++) {
      final entry = _find(directory, id);
      if (entry == null) return null;
      if (entry.runLength > 0) {
        if (id - entry.tileId >= entry.runLength) return null;
        if (entry.length < 0 || entry.length > maxTileCompressedBytes) {
          throw PmtilesException('tuile de taille absurde (${entry.length} octets)');
        }
        final raw = await _source.read(header.tileDataOffset + entry.offset, entry.length);
        if (header.tileCompression == PmtilesCompression.gzip) {
          return _gunzip(raw, maxTilePlainBytes, 'tuile');
        }
        if (raw.length > maxTilePlainBytes) throw PmtilesException('tuile trop grosse');
        return raw;
      }
      directory = await _leaf(entry);
    }
    throw PmtilesException('répertoires imbriqués trop profondément');
  }

  Future<List<PmtilesEntry>> _leaf(PmtilesEntry pointer) async {
    final cached = _leaves[pointer.offset];
    if (cached != null) return cached;
    final directory = await readDirectory(
      _source,
      header,
      header.leafOffset + pointer.offset,
      pointer.length,
    );
    if (_leaves.length > 64) _leaves.remove(_leaves.keys.first);
    return _leaves[pointer.offset] = directory;
  }

  /// La dernière entrée dont le numéro est inférieur ou égal à [id].
  static PmtilesEntry? _find(List<PmtilesEntry> entries, int id) {
    var low = 0;
    var high = entries.length - 1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      final entry = entries[middle];
      if (entry.tileId < id) {
        low = middle + 1;
      } else if (entry.tileId > id) {
        high = middle - 1;
      } else {
        return entry;
      }
    }
    if (high < 0) return null;
    final candidate = entries[high];
    // Une entrée sans longueur de série pointe vers un répertoire : il couvre
    // toutes les tuiles qui suivent jusqu'à l'entrée suivante.
    return candidate;
  }

  static Future<List<PmtilesEntry>> readDirectory(
    ByteSource source,
    PmtilesHeader header,
    int offset,
    int length,
  ) async {
    if (length < 0 || length > maxDirectoryCompressedBytes) {
      throw PmtilesException('répertoire de taille absurde ($length octets)');
    }
    final raw = await source.read(offset, length);
    final bytes = switch (header.internalCompression) {
      PmtilesCompression.gzip => _gunzip(raw, maxDirectoryPlainBytes, 'répertoire'),
      PmtilesCompression.none || PmtilesCompression.unknown => raw,
      _ => throw PmtilesException('compression des répertoires non prise en charge'),
    };
    var position = 0;
    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (position >= bytes.length) throw PmtilesException('répertoire tronqué');
        final byte = bytes[position++];
        result |= (byte & 0x7f) << shift;
        if (byte < 0x80) return result;
        shift += 7;
        if (shift > 63) throw PmtilesException('entier trop grand dans un répertoire');
      }
    }

    final count = varint();
    // Chaque ligne occupe au moins un octet dans chacune des quatre listes : un
    // nombre de lignes plus grand que cela ne peut pas être vrai, et ne doit pas
    // nous faire réserver de la mémoire.
    if (count < 0 || count > 10000000 || count * 4 > bytes.length) {
      throw PmtilesException('répertoire absurde');
    }
    final ids = List<int>.filled(count, 0);
    var last = 0;
    for (var i = 0; i < count; i++) {
      last += varint();
      ids[i] = last;
    }
    final runs = [for (var i = 0; i < count; i++) varint()];
    final lengths = [for (var i = 0; i < count; i++) varint()];
    final entries = <PmtilesEntry>[];
    var previousEnd = 0;
    for (var i = 0; i < count; i++) {
      final value = varint();
      final entryOffset = (value == 0 && i > 0) ? previousEnd : value - 1;
      entries.add(PmtilesEntry(ids[i], entryOffset, lengths[i], runs[i]));
      previousEnd = entryOffset + lengths[i];
    }
    return entries;
  }
}
