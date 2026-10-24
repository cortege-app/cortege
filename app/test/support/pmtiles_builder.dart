import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/pmtiles_extract.dart';
import 'package:cortege/map/projection.dart';

/// Fabrique un fichier PMTiles de test, indépendamment de l'extracteur : les
/// tests de l'extracteur comparent donc deux écritures du format, relues par le
/// même lecteur (lui, vérifié sur de vraies cartes).
///
/// Les tuiles ne sont pas compressées : leur contenu est libre.
Uint8List buildPmtiles({
  required Map<int, Uint8List> tiles,
  required ExtractArea bounds,
  required int minZoom,
  required int maxZoom,

  /// 0 : tout dans le répertoire racine. Sinon, nombre d'entrées par feuille.
  int leafSize = 0,

  /// 1 : tuiles non compressées, 2 : gzip (les octets donnés sont alors déjà
  /// compressés).
  int tileCompression = 1,
}) {
  final ids = tiles.keys.toList()..sort();
  final data = BytesBuilder(copy: false);
  final placed = <String, int>{};
  final entries = <PmtilesEntry>[];
  for (final id in ids) {
    final bytes = tiles[id]!;
    final offset = placed.putIfAbsent(String.fromCharCodes(bytes), () {
      final at = data.length;
      data.add(bytes);
      return at;
    });
    final last = entries.isEmpty ? null : entries.last;
    if (last != null && last.offset == offset && last.length == bytes.length && last.tileId + last.runLength == id) {
      entries[entries.length - 1] = PmtilesEntry(last.tileId, offset, last.length, last.runLength + 1);
    } else {
      entries.add(PmtilesEntry(id, offset, bytes.length, 1));
    }
  }

  Uint8List varints(List<PmtilesEntry> list) {
    final out = BytesBuilder(copy: false);
    void put(int value) {
      var v = value;
      while (v >= 0x80) {
        out.addByte((v & 0x7f) | 0x80);
        v >>= 7;
      }
      out.addByte(v);
    }

    put(list.length);
    var previous = 0;
    for (final e in list) {
      put(e.tileId - previous);
      previous = e.tileId;
    }
    for (final e in list) {
      put(e.runLength);
    }
    for (final e in list) {
      put(e.length);
    }
    for (var i = 0; i < list.length; i++) {
      final contiguous = i > 0 && list[i].offset == list[i - 1].offset + list[i - 1].length;
      put(contiguous ? 0 : list[i].offset + 1);
    }
    return Uint8List.fromList(gzip.encode(out.toBytes()));
  }

  late Uint8List root;
  var leaves = Uint8List(0);
  if (leafSize <= 0) {
    root = varints(entries);
  } else {
    final leafBytes = BytesBuilder(copy: false);
    final pointers = <PmtilesEntry>[];
    for (var i = 0; i < entries.length; i += leafSize) {
      final chunk = entries.sublist(i, i + leafSize > entries.length ? entries.length : i + leafSize);
      final encoded = varints(chunk);
      pointers.add(PmtilesEntry(chunk.first.tileId, leafBytes.length, encoded.length, 0));
      leafBytes.add(encoded);
    }
    root = varints(pointers);
    leaves = leafBytes.toBytes();
  }
  final metadata = Uint8List.fromList(gzip.encode('{"name":"essai"}'.codeUnits));

  final rootOffset = PmtilesHeader.length;
  final metadataOffset = rootOffset + root.length;
  final leafOffset = metadataOffset + metadata.length;
  final dataOffset = leafOffset + leaves.length;
  final head = Uint8List(PmtilesHeader.length)..setRange(0, 7, 'PMTiles'.codeUnits);
  head[7] = 3;
  final view = ByteData.sublistView(head)
    ..setUint64(8, rootOffset, Endian.little)
    ..setUint64(16, root.length, Endian.little)
    ..setUint64(24, metadataOffset, Endian.little)
    ..setUint64(32, metadata.length, Endian.little)
    ..setUint64(40, leafOffset, Endian.little)
    ..setUint64(48, leaves.length, Endian.little)
    ..setUint64(56, dataOffset, Endian.little)
    ..setUint64(64, data.length, Endian.little)
    ..setUint64(72, ids.length, Endian.little)
    ..setUint64(80, entries.length, Endian.little)
    ..setUint64(88, placed.length, Endian.little);
  head[96] = 1;
  head[97] = 2; // répertoires en gzip
  head[98] = tileCompression;
  head[99] = 1; // vectorielles
  head[100] = minZoom;
  head[101] = maxZoom;
  int e7(double degrees) => (degrees * 1e7).round();
  view
    ..setInt32(102, e7(bounds.west), Endian.little)
    ..setInt32(106, e7(bounds.south), Endian.little)
    ..setInt32(110, e7(bounds.east), Endian.little)
    ..setInt32(114, e7(bounds.north), Endian.little)
    ..setInt32(119, e7((bounds.west + bounds.east) / 2), Endian.little)
    ..setInt32(123, e7((bounds.south + bounds.north) / 2), Endian.little);
  head[118] = minZoom;

  return Uint8List.fromList([...head, ...root, ...metadata, ...leaves, ...data.toBytes()]);
}

/// Un bloc de tuiles : toutes celles qui couvrent [area], de [minZoom] à
/// [maxZoom]. Un tiers partagent le même contenu (de la mer, par exemple), les
/// autres ont un contenu à elles.
Map<int, Uint8List> blockOfTiles(ExtractArea area, int minZoom, int maxZoom) {
  final sea = Uint8List.fromList(List.filled(300, 9));
  final tiles = <int, Uint8List>{};
  for (final id in tileIdsCovering(area, minZoom, maxZoom)) {
    final (z, x, y) = tileIdToZxy(id);
    tiles[id] = (x + y) % 3 == 0
        ? sea
        : Uint8List.fromList([z, x & 255, x >> 8, y & 255, y >> 8, ...List.filled((x * 7 + y * 13) % 40, z)]);
  }
  return tiles;
}

/// La zone exacte d'un rectangle de tuiles au zoom [z].
ExtractArea areaOfTiles(int z, int x0, int y0, int width, int height) => (
      west: tileXToLon(x0.toDouble(), z.toDouble()) + 1e-7,
      north: tileYToLat(y0.toDouble(), z.toDouble()) - 1e-7,
      east: tileXToLon((x0 + width).toDouble(), z.toDouble()) - 1e-7,
      south: tileYToLat((y0 + height).toDouble(), z.toDouble()) + 1e-7,
    );
