import 'dart:io';

import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/mvt.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/projection.dart';
import 'package:flutter_test/flutter_test.dart';

// Sonde temporaire : liste les couches et les genres d'objets de la tuile
// d'essai, pour dessiner le style de la carte.
void main() {
  test('sonde', () async {
    final archive = await PmtilesArchive.open(await FileByteSource.open(File('test/fixtures/paris_fixture.pmtiles')));
    final lon = (archive.header.minLon + archive.header.maxLon) / 2;
    final lat = (archive.header.minLat + archive.header.maxLat) / 2;
    for (final z in [13, 15]) {
      final x = lonToTileX(lon, z.toDouble()).floor();
      final y = latToTileY(lat, z.toDouble()).floor();
      final bytes = (await archive.tile(z, x, y))!;
      final watch = Stopwatch()..start();
      final tile = decodeMvt(bytes);
      watch.stop();
      // ignore: avoid_print
      print('=== zoom $z, tuile $x/$y : ${bytes.length} octets, décodée en ${watch.elapsedMilliseconds} ms');
      for (final layer in tile.layers.values) {
        final kinds = <String, int>{};
        final types = <MvtGeometry, int>{};
        var named = 0;
        for (final f in layer.features) {
          final key = '${f.kind}/${f.props['kind_detail'] ?? ''}';
          kinds[key] = (kinds[key] ?? 0) + 1;
          types[f.type] = (types[f.type] ?? 0) + 1;
          if (f.name != null) named++;
        }
        final top = (kinds.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(12);
        // ignore: avoid_print
        print('${layer.name} extent=${layer.extent} n=${layer.features.length} noms=$named types=$types');
        // ignore: avoid_print
        print('   ${top.map((e) => '${e.key}:${e.value}').join('  ')}');
        final sample = layer.features.where((f) => f.name != null).take(2);
        for (final f in sample) {
          // ignore: avoid_print
          print('   ex: ${f.props}');
        }
      }
    }
  });
}
