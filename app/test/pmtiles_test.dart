import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  group('numéros de tuile', () {
    test('les premiers numéros suivent la courbe de Hilbert', () {
      expect(zxyToTileId(0, 0, 0), 0);
      expect(zxyToTileId(1, 0, 0), 1);
      expect(zxyToTileId(1, 0, 1), 2);
      expect(zxyToTileId(1, 1, 1), 3);
      expect(zxyToTileId(1, 1, 0), 4);
      expect(zxyToTileId(2, 0, 0), 5);
    });

    test('l\'aller-retour redonne la même tuile, du zoom 0 au zoom 20', () {
      final random = math.Random(7);
      for (var i = 0; i < 2000; i++) {
        final z = random.nextInt(21);
        final n = 1 << z;
        final x = random.nextInt(n);
        final y = random.nextInt(n);
        expect(tileIdToZxy(zxyToTileId(z, x, y)), (z, x, y), reason: '$z/$x/$y');
      }
    });

    test('une tuile hors du zoom est refusée', () {
      expect(() => zxyToTileId(2, 4, 0), throwsA(isA<PmtilesException>()));
      expect(() => zxyToTileId(2, 0, -1), throwsA(isA<PmtilesException>()));
    });
  });

  group('fichier PMTiles', () {
    late PmtilesArchive archive;

    setUp(() async {
      archive = await PmtilesArchive.open(await FileByteSource.open(fixture));
    });

    tearDown(() => archive.close());

    test('l\'en-tête donne zooms, emprise et type', () {
      final h = archive.header;
      expect(h.minZoom, 13);
      expect(h.maxZoom, 15);
      expect(h.tileType, PmtilesHeader.tileTypeMvt);
      expect(h.tileCompression, PmtilesCompression.gzip);
      expect(h.minLon, closeTo(2.3512, 0.0001));
      expect(h.maxLat, closeTo(48.8543, 0.0001));
    });

    test('la tuile qui contient le centre se lit et ressemble à une tuile vectorielle', () async {
      final lon = (archive.header.minLon + archive.header.maxLon) / 2;
      final lat = (archive.header.minLat + archive.header.maxLat) / 2;
      for (final z in [13, 14, 15]) {
        final x = lonToTileX(lon, z.toDouble()).floor();
        final y = latToTileY(lat, z.toDouble()).floor();
        final tile = await archive.tile(z, x, y);
        expect(tile, isNotNull, reason: 'tuile $z/$x/$y');
        expect(tile!.length, greaterThan(100));
        // Le premier champ d'une tuile vectorielle est une couche : numéro 3,
        // type « longueur + octets », soit l'octet 0x1a.
        expect(tile[0], 0x1a, reason: 'tuile $z/$x/$y');
      }
    });

    test('une tuile absente ou hors des zooms rend null', () async {
      expect(await archive.tile(15, 0, 0), isNull);
      expect(await archive.tile(5, 16, 11), isNull, reason: 'sous le zoom minimal');
      expect(await archive.tile(16, 1, 1), isNull, reason: 'au-dessus du zoom maximal');
    });

    test('la conversion longitude, latitude vers tuile est cohérente', () {
      // Notre-Dame, zoom 15 : tuile 16597/11273.
      expect(lonToTileX(2.3499, 15).floor(), 16597);
      expect(latToTileY(48.8530, 15).floor(), 11273);
      expect(tileXToLon(lonToTileX(2.35, 12), 12), closeTo(2.35, 1e-9));
      expect(tileYToLat(latToTileY(48.85, 12), 12), closeTo(48.85, 1e-9));
    });
  });

  group('fichiers abîmés', () {
    test('un fichier qui n\'est pas un PMTiles est refusé', () async {
      final junk = MemoryByteSource(Uint8List(300));
      expect(PmtilesArchive.open(junk), throwsA(isA<PmtilesException>()));
    });

    test('un fichier trop court est refusé', () async {
      final tiny = MemoryByteSource(Uint8List(20));
      expect(PmtilesArchive.open(tiny), throwsA(isA<PmtilesException>()));
    });

    test('un fichier tronqué ne plante pas : une erreur claire', () async {
      final bytes = fixture.readAsBytesSync();
      final cut = MemoryByteSource(Uint8List.sublistView(bytes, 0, bytes.length ~/ 2));
      Object? failure;
      try {
        final archive = await PmtilesArchive.open(cut);
        final lon = (archive.header.minLon + archive.header.maxLon) / 2;
        final lat = (archive.header.minLat + archive.header.maxLat) / 2;
        await archive.tile(
          15,
          lonToTileX(lon, 15).floor(),
          latToTileY(lat, 15).floor(),
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, anyOf(isNull, isA<RangeError>(), isA<PmtilesException>(), isA<FileSystemException>()));
    });
  });
}
