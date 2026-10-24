import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_source.dart';
import 'pmtiles.dart';
import 'projection.dart';

/// Une zone en degrés.
typedef ExtractArea = ({double west, double south, double east, double north});

class ExtractException implements Exception {
  ExtractException(this.message);

  final String message;

  @override
  String toString() => 'ExtractException($message)';
}

class ExtractResult {
  const ExtractResult({
    required this.addressedTiles,
    required this.contents,
    required this.bytes,
    required this.minZoom,
    required this.maxZoom,
  });

  /// Nombre de tuiles de la zone qui existent dans la carte source.
  final int addressedTiles;

  /// Nombre de contenus différents (une mer vide n'est écrite qu'une fois).
  final int contents;

  /// Taille du fichier écrit.
  final int bytes;
  final int minZoom;
  final int maxZoom;
}

/// Les numéros de tuile qui couvrent [area] entre deux zooms, du plus petit au
/// plus grand.
List<int> tileIdsCovering(ExtractArea area, int minZoom, int maxZoom, {int limit = 3000000}) {
  final ids = <int>[];
  for (var z = minZoom; z <= maxZoom; z++) {
    final n = 1 << z;
    final x0 = lonToTileX(area.west, z.toDouble()).floor().clamp(0, n - 1);
    final x1 = lonToTileX(area.east, z.toDouble()).floor().clamp(0, n - 1);
    final y0 = latToTileY(area.north, z.toDouble()).floor().clamp(0, n - 1);
    final y1 = latToTileY(area.south, z.toDouble()).floor().clamp(0, n - 1);
    final count = (x1 - x0 + 1) * (y1 - y0 + 1);
    if (ids.length + count > limit) {
      throw ExtractException(
        'zone trop grande : plus de $limit tuiles. Réduis la zone ou le zoom maximal.',
      );
    }
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        ids.add(zxyToTileId(z, x, y));
      }
    }
  }
  ids.sort();
  return ids;
}

class _Chosen {
  _Chosen(this.id, this.offset, this.length);

  final int id;
  final int offset;
  final int length;
}

int _lowerBound(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (sorted[middle] < value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// Parcourt les répertoires en ne descendant que dans ceux qui contiennent une
/// tuile voulue : sur une carte du monde, on ne lit qu'une infime partie.
Future<void> _walk(
  ByteSource source,
  PmtilesHeader header,
  List<PmtilesEntry> entries,
  int upperLimit,
  List<int> wanted,
  List<_Chosen> out,
  int depth,
) async {
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final end = i + 1 < entries.length ? entries[i + 1].tileId : upperLimit;
    var k = _lowerBound(wanted, entry.tileId);
    if (entry.runLength > 0) {
      final stop = entry.tileId + entry.runLength;
      while (k < wanted.length && wanted[k] < stop) {
        out.add(_Chosen(wanted[k], entry.offset, entry.length));
        k++;
      }
    } else if (k < wanted.length && wanted[k] < end) {
      if (depth >= 3) throw ExtractException('répertoires imbriqués trop profondément');
      final leaf = await PmtilesArchive.readDirectory(
        source,
        header,
        header.leafOffset + entry.offset,
        entry.length,
      );
      await _walk(source, header, leaf, end, wanted, out, depth + 1);
    }
  }
}

Uint8List _serialize(List<PmtilesEntry> entries) {
  final bytes = BytesBuilder(copy: false);
  void varint(int value) {
    var v = value;
    while (v >= 0x80) {
      bytes.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    bytes.addByte(v);
  }

  varint(entries.length);
  var last = 0;
  for (final e in entries) {
    varint(e.tileId - last);
    last = e.tileId;
  }
  for (final e in entries) {
    varint(e.runLength);
  }
  for (final e in entries) {
    varint(e.length);
  }
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (i > 0 && e.offset == entries[i - 1].offset + entries[i - 1].length) {
      varint(0);
    } else {
      varint(e.offset + 1);
    }
  }
  return bytes.toBytes();
}

Uint8List _gzip(Uint8List bytes) => Uint8List.fromList(gzip.encode(bytes));

/// Le répertoire racine, et les répertoires de second niveau s'il est trop gros
/// pour tenir avec l'en-tête dans les premiers 16 Kio, comme le demande la
/// spécification (une lecture suffit alors à ouvrir le fichier).
({Uint8List root, Uint8List leaves}) _directories(List<PmtilesEntry> entries, int? forcedLeafSize) {
  const budget = 16384 - PmtilesHeader.length;
  if (forcedLeafSize == null) {
    final root = _gzip(_serialize(entries));
    if (root.length <= budget) return (root: root, leaves: Uint8List(0));
  }
  var leafSize = forcedLeafSize ?? 4096;
  while (true) {
    final leaves = BytesBuilder(copy: false);
    final rootEntries = <PmtilesEntry>[];
    for (var i = 0; i < entries.length; i += leafSize) {
      final chunk = entries.sublist(i, math.min(i + leafSize, entries.length));
      final bytes = _gzip(_serialize(chunk));
      rootEntries.add(PmtilesEntry(chunk.first.tileId, leaves.length, bytes.length, 0));
      leaves.add(bytes);
    }
    final root = _gzip(_serialize(rootEntries));
    if (root.length <= budget || forcedLeafSize != null || leafSize >= entries.length) {
      return (root: root, leaves: leaves.toBytes());
    }
    leafSize *= 2;
  }
}

int _e7(double degrees) => (degrees * 1e7).round();

/// Extrait d'une carte PMTiles (même très grosse, lue par morceaux) les tuiles
/// d'une zone, et écrit un petit fichier PMTiles que l'appli sait lire. Ne
/// touche pas au réseau elle-même : c'est la [source] qui lit où elle veut.
///
/// Sert à l'outil de l'organisateur, jamais à l'appli.
Future<ExtractResult> extractPmtiles({
  required ByteSource source,
  required File target,
  required ExtractArea area,
  int minZoom = 0,
  int maxZoom = 15,
  int maxBytes = 150 * 1024 * 1024,
  int? leafSize,
  void Function(String line)? log,
}) async {
  if (area.west >= area.east || area.south >= area.north) {
    throw ExtractException('zone vide : l\'ouest doit être avant l\'est, le sud avant le nord');
  }
  final header = PmtilesHeader.parse(await source.read(0, PmtilesHeader.length));
  if (header.tileType != PmtilesHeader.tileTypeMvt) {
    throw ExtractException('seules les tuiles vectorielles (MVT) sont prises en charge');
  }
  if (header.internalCompression != PmtilesCompression.gzip &&
      header.internalCompression != PmtilesCompression.none) {
    throw ExtractException('compression des répertoires non prise en charge');
  }
  if (header.tileCompression != PmtilesCompression.gzip &&
      header.tileCompression != PmtilesCompression.none) {
    throw ExtractException('compression des tuiles non prise en charge');
  }
  final lowest = math.max(header.minZoom, minZoom);
  final highest = math.min(header.maxZoom, maxZoom);
  if (lowest > highest) {
    throw ExtractException('la carte source couvre les zooms ${header.minZoom} à ${header.maxZoom}');
  }
  final west = math.max(area.west, header.minLon);
  final south = math.max(area.south, header.minLat);
  final east = math.min(area.east, header.maxLon);
  final north = math.min(area.north, header.maxLat);
  if (west >= east || south >= north) {
    throw ExtractException('la zone est hors de la carte source');
  }

  final wanted = tileIdsCovering(
    (west: west, south: south, east: east, north: north),
    lowest,
    highest,
  );
  log?.call('${wanted.length} tuiles à chercher, zooms $lowest à $highest');

  final root = await PmtilesArchive.readDirectory(source, header, header.rootOffset, header.rootLength);
  final chosen = <_Chosen>[];
  await _walk(source, header, root, 1 << 62, wanted, chosen, 0);
  if (chosen.isEmpty) throw ExtractException('aucune tuile dans cette zone : la carte source ne la couvre pas');

  // Les contenus différents, dans l'ordre des tuiles.
  final seen = <(int, int)>{};
  final fresh = <_Chosen>[];
  var freshBytes = 0;
  for (final c in chosen) {
    if (seen.add((c.offset, c.length))) {
      fresh.add(c);
      freshBytes += c.length;
    }
  }
  log?.call('${chosen.length} tuiles trouvées, ${fresh.length} contenus différents, '
      '${(freshBytes / (1024 * 1024)).toStringAsFixed(1)} Mo');
  if (freshBytes > maxBytes) {
    throw ExtractException(
      'la carte ferait ${(freshBytes / (1024 * 1024)).toStringAsFixed(0)} Mo, '
      'plus que la limite de ${(maxBytes / (1024 * 1024)).toStringAsFixed(0)} Mo. '
      'Réduis la zone ou le zoom maximal.',
    );
  }

  final tilesFile = File('${target.path}.tuiles');
  final tilesOut = await tilesFile.open(mode: FileMode.write);
  final placed = <(int, int), int>{};
  var written = 0;
  try {
    const gap = 32 * 1024;
    const batchMax = 4 * 1024 * 1024;
    var i = 0;
    while (i < fresh.length) {
      final batchStart = fresh[i].offset;
      var batchEnd = batchStart + fresh[i].length;
      var j = i + 1;
      while (j < fresh.length &&
          fresh[j].offset >= batchEnd &&
          fresh[j].offset - batchEnd <= gap &&
          fresh[j].offset + fresh[j].length - batchStart <= batchMax) {
        batchEnd = fresh[j].offset + fresh[j].length;
        j++;
      }
      final data = await source.read(header.tileDataOffset + batchStart, batchEnd - batchStart);
      for (var k = i; k < j; k++) {
        final c = fresh[k];
        final from = c.offset - batchStart;
        placed[(c.offset, c.length)] = written;
        await tilesOut.writeFrom(data, from, from + c.length);
        written += c.length;
      }
      i = j;
      log?.call('  ${(written / (1024 * 1024)).toStringAsFixed(1)} Mo lus');
    }
    await tilesOut.close();
  } on Object {
    await tilesOut.close();
    if (await tilesFile.exists()) await tilesFile.delete();
    rethrow;
  }

  // Une suite de tuiles voisines au même contenu (mer, forêt) tient en une ligne.
  final entries = <PmtilesEntry>[];
  for (final c in chosen) {
    final offset = placed[(c.offset, c.length)]!;
    if (entries.isNotEmpty) {
      final last = entries.last;
      if (last.offset == offset && last.length == c.length && last.tileId + last.runLength == c.id) {
        entries[entries.length - 1] = PmtilesEntry(last.tileId, last.offset, last.length, last.runLength + 1);
        continue;
      }
    }
    entries.add(PmtilesEntry(c.id, offset, c.length, 1));
  }

  final directories = _directories(entries, leafSize);

  Uint8List metadata;
  if (header.metadataLength == 0) {
    metadata = _gzip(Uint8List.fromList('{}'.codeUnits));
  } else {
    final raw = await source.read(header.metadataOffset, header.metadataLength);
    metadata = header.internalCompression == PmtilesCompression.gzip ? raw : _gzip(raw);
  }

  final firstZoom = tileIdToZxy(chosen.first.id).$1;
  final lastZoom = tileIdToZxy(chosen.last.id).$1;
  final rootOffset = PmtilesHeader.length;
  final metadataOffset = rootOffset + directories.root.length;
  final leafOffset = metadataOffset + metadata.length;
  final tileDataOffset = leafOffset + directories.leaves.length;

  final head = Uint8List(PmtilesHeader.length)..setRange(0, 7, 'PMTiles'.codeUnits);
  head[7] = 3;
  final view = ByteData.sublistView(head);
  view
    ..setUint64(8, rootOffset, Endian.little)
    ..setUint64(16, directories.root.length, Endian.little)
    ..setUint64(24, metadataOffset, Endian.little)
    ..setUint64(32, metadata.length, Endian.little)
    ..setUint64(40, leafOffset, Endian.little)
    ..setUint64(48, directories.leaves.length, Endian.little)
    ..setUint64(56, tileDataOffset, Endian.little)
    ..setUint64(64, written, Endian.little)
    ..setUint64(72, chosen.length, Endian.little)
    ..setUint64(80, entries.length, Endian.little)
    ..setUint64(88, fresh.length, Endian.little);
  head[96] = 1; // rangé dans l'ordre des tuiles
  head[97] = PmtilesCompression.gzip.index;
  head[98] = header.tileCompression.index;
  head[99] = header.tileType;
  head[100] = firstZoom;
  head[101] = lastZoom;
  view
    ..setInt32(102, _e7(west), Endian.little)
    ..setInt32(106, _e7(south), Endian.little)
    ..setInt32(110, _e7(east), Endian.little)
    ..setInt32(114, _e7(north), Endian.little);
  head[118] = math.min(lastZoom, 14);
  view
    ..setInt32(119, _e7((west + east) / 2), Endian.little)
    ..setInt32(123, _e7((south + north) / 2), Endian.little);

  final tmp = File('${target.path}.tmp');
  final sink = tmp.openWrite();
  try {
    sink
      ..add(head)
      ..add(directories.root)
      ..add(metadata)
      ..add(directories.leaves);
    await sink.addStream(tilesFile.openRead());
    await sink.flush();
    await sink.close();
    await tmp.rename(target.path);
  } on Object {
    try {
      await sink.close();
    } on Object {
      // Déjà fermé par l'échec.
    }
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  } finally {
    if (await tilesFile.exists()) await tilesFile.delete();
  }
  return ExtractResult(
    addressedTiles: chosen.length,
    contents: fresh.length,
    bytes: await target.length(),
    minZoom: firstZoom,
    maxZoom: lastZoom,
  );
}
