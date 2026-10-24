import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/pmtiles_extract.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pmtiles_builder.dart';

void main() {
  late Directory dir;

  // La région du « monde » de ces tests : un peu de Paris, du zoom 10 au zoom 14.
  const region = (west: 2.25, south: 48.80, east: 2.45, north: 48.92);
  late Map<int, Uint8List> tiles;
  late Uint8List flatFile;
  late Uint8List leafyFile;

  setUpAll(() {
    tiles = blockOfTiles(region, 10, 14);
    flatFile = buildPmtiles(tiles: tiles, bounds: region, minZoom: 10, maxZoom: 14);
    leafyFile = buildPmtiles(tiles: tiles, bounds: region, minZoom: 10, maxZoom: 14, leafSize: 9);
  });

  setUp(() => dir = Directory.systemTemp.createTempSync('cortege_extract'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<PmtilesArchive> openBytes(Uint8List bytes) => PmtilesArchive.open(MemoryByteSource(bytes));

  Future<PmtilesArchive> openFile(File file) async => PmtilesArchive.open(await FileByteSource.open(file));

  /// Chaque tuile de la zone doit être la même dans l'extrait que dans la source
  /// (ou absente des deux côtés). Rend combien on en a comparé.
  Future<int> expectSameTiles(PmtilesArchive extracted, ExtractArea area, int minZoom, int maxZoom) async {
    var compared = 0;
    for (final id in tileIdsCovering(area, minZoom, maxZoom)) {
      final (z, x, y) = tileIdToZxy(id);
      final actual = await extracted.tile(z, x, y);
      expect(actual, tiles[id], reason: 'tuile $z/$x/$y');
      if (tiles[id] != null) compared++;
    }
    return compared;
  }

  test('la source de ces tests est bien lue par le lecteur', () async {
    for (final bytes in [flatFile, leafyFile]) {
      final archive = await openBytes(bytes);
      addTearDown(archive.close);
      expect(tiles.length, greaterThan(100));
      for (final entry in tiles.entries.take(40)) {
        final (z, x, y) = tileIdToZxy(entry.key);
        expect(await archive.tile(z, x, y), entry.value);
      }
    }
    expect((await openBytes(leafyFile)).header.leafLength, greaterThan(0));
  });

  test('extraire toute la région redonne les mêmes tuiles, sans doublons de contenu', () async {
    final target = File('${dir.path}/tout.pmtiles');

    final result = await extractPmtiles(
      source: MemoryByteSource(flatFile),
      target: target,
      area: region,
      minZoom: 10,
      maxZoom: 14,
    );

    final extracted = await openFile(target);
    addTearDown(extracted.close);
    expect(await expectSameTiles(extracted, region, 10, 14), tiles.length);
    expect(result.addressedTiles, tiles.length);
    // Le contenu partagé n'est écrit qu'une fois.
    expect(result.contents, lessThan(tiles.length));
    expect(result.contents, tiles.values.map(String.fromCharCodes).toSet().length);
    expect(extracted.header.clustered, isTrue);
    expect(extracted.header.tileType, PmtilesHeader.tileTypeMvt);
    expect(extracted.header.internalCompression, PmtilesCompression.gzip);
    expect(extracted.header.tileCompression, PmtilesCompression.none);
    expect(extracted.header.minZoom, 10);
    expect(extracted.header.maxZoom, 14);
    expect(result.bytes, target.lengthSync());
    expect(File('${target.path}.tuiles').existsSync(), isFalse);
    expect(File('${target.path}.tmp').existsSync(), isFalse);
  });

  test('un morceau de la région à des zooms plus bas : seulement ce qui est demandé', () async {
    final target = File('${dir.path}/morceau.pmtiles');
    const part = (west: 2.30, south: 48.83, east: 2.36, north: 48.87);

    final result = await extractPmtiles(
      source: MemoryByteSource(flatFile),
      target: target,
      area: part,
      minZoom: 11,
      maxZoom: 13,
    );

    final extracted = await openFile(target);
    addTearDown(extracted.close);
    final wanted = tileIdsCovering(part, 11, 13).toSet();
    expect(await expectSameTiles(extracted, part, 11, 13), wanted.length);
    expect(result.minZoom, 11);
    expect(result.maxZoom, 13);
    // Tout le reste de la source est absent de l'extrait.
    for (final id in tiles.keys.where((id) => !wanted.contains(id))) {
      final (z, x, y) = tileIdToZxy(id);
      expect(await extracted.tile(z, x, y), isNull, reason: 'tuile $z/$x/$y');
    }
    expect(result.bytes, lessThan(flatFile.length ~/ 3));
    expect(extracted.header.minLon, closeTo(part.west, 1e-6));
    expect(extracted.header.maxLat, closeTo(part.north, 1e-6));
  });

  test('des répertoires de second niveau, en entrée comme en sortie', () async {
    final leafy = File('${dir.path}/feuilles.pmtiles');
    await extractPmtiles(
      source: MemoryByteSource(leafyFile),
      target: leafy,
      area: region,
      minZoom: 10,
      maxZoom: 14,
      leafSize: 7,
    );
    final leafyArchive = await openFile(leafy);
    addTearDown(leafyArchive.close);
    expect(leafyArchive.header.leafLength, greaterThan(0));
    expect(await expectSameTiles(leafyArchive, region, 10, 14), tiles.length);

    // On repart de ce fichier : sa lecture passe par les répertoires de second niveau.
    const part = (west: 2.28, south: 48.82, east: 2.40, north: 48.90);
    final again = File('${dir.path}/encore.pmtiles');
    final leafySource = await FileByteSource.open(leafy);
    try {
      await extractPmtiles(source: leafySource, target: again, area: part, minZoom: 10, maxZoom: 14);
    } finally {
      await leafySource.close();
    }
    final againArchive = await openFile(again);
    addTearDown(againArchive.close);
    final wanted = tileIdsCovering(part, 10, 14).where(tiles.containsKey).length;
    expect(await expectSameTiles(againArchive, part, 10, 14), wanted);
  });

  test('un répertoire racine trop gros est découpé pour tenir dans les premiers 16 Kio', () async {
    // Des dizaines de milliers de tuiles de tailles quelconques : le répertoire
    // compressé dépasse largement 16 Kio.
    const z = 14;
    const x0 = 8000;
    const y0 = 5500;
    final area = areaOfTiles(z, x0, y0, 200, 200);
    final random = Random(7);
    final big = <int, Uint8List>{
      for (var y = y0; y < y0 + 200; y++)
        for (var x = x0; x < x0 + 200; x++)
          if (random.nextInt(10) < 7)
            zxyToTileId(z, x, y): Uint8List.fromList(List.filled(1 + random.nextInt(400), (x ^ y) & 255)),
    };
    final bigFile = buildPmtiles(tiles: big, bounds: area, minZoom: z, maxZoom: z);
    final target = File('${dir.path}/gros.pmtiles');

    final result = await extractPmtiles(
      source: MemoryByteSource(bigFile),
      target: target,
      area: area,
      minZoom: z,
      maxZoom: z,
    );

    final extracted = await openFile(target);
    addTearDown(extracted.close);
    expect(result.addressedTiles, big.length);
    expect(extracted.header.leafLength, greaterThan(0));
    expect(extracted.header.rootOffset + extracted.header.rootLength, lessThanOrEqualTo(16384));
    final sample = big.entries.toList()..shuffle(random);
    for (final entry in sample.take(1500)) {
      final (tz, tx, ty) = tileIdToZxy(entry.key);
      expect(await extracted.tile(tz, tx, ty), entry.value, reason: 'tuile $tz/$tx/$ty');
    }
  });

  test('une carte trop lourde, une zone vide ou hors carte sont refusées', () async {
    final target = File('${dir.path}/refus.pmtiles');

    await expectLater(
      extractPmtiles(
        source: MemoryByteSource(flatFile),
        target: target,
        area: region,
        minZoom: 10,
        maxZoom: 14,
        maxBytes: 1000,
      ),
      throwsA(isA<ExtractException>().having((e) => e.message, 'message', contains('Réduis la zone'))),
    );
    await expectLater(
      extractPmtiles(
        source: MemoryByteSource(flatFile),
        target: target,
        area: (west: 2, south: 48, east: 1, north: 49),
      ),
      throwsA(isA<ExtractException>().having((e) => e.message, 'message', contains('zone vide'))),
    );
    await expectLater(
      extractPmtiles(
        source: MemoryByteSource(flatFile),
        target: target,
        area: (west: 100, south: -30, east: 101, north: -29),
      ),
      throwsA(isA<ExtractException>().having((e) => e.message, 'message', contains('hors de la carte'))),
    );
    await expectLater(
      extractPmtiles(
        source: MemoryByteSource(flatFile),
        target: target,
        area: region,
        minZoom: 0,
        maxZoom: 5,
      ),
      throwsA(isA<ExtractException>().having((e) => e.message, 'message', contains('zooms 10 à 14'))),
    );
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.tuiles').existsSync(), isFalse);
  });

  test('le nombre de tuiles à chercher est borné', () {
    expect(tileIdsCovering((west: -10, south: -10, east: 10, north: 10), 0, 0), [0]);
    expect(
      () => tileIdsCovering((west: -170, south: -80, east: 170, north: 80), 0, 14, limit: 100000),
      throwsA(isA<ExtractException>()),
    );
    final ids = tileIdsCovering((west: 2.3, south: 48.8, east: 2.4, north: 48.9), 8, 12);
    expect(ids, [...ids]..sort());
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('une source qui n\'est pas du PMTiles est refusée', () async {
    await expectLater(
      extractPmtiles(source: MemoryByteSource(Uint8List(500)), target: File('${dir.path}/x.pmtiles'), area: region),
      throwsA(isA<PmtilesException>()),
    );
  });

  test('la carte d\'essai du dépôt s\'extrait aussi', () async {
    final fixture = File('test/fixtures/paris_fixture.pmtiles');
    final source = await openBytes(fixture.readAsBytesSync());
    final h = source.header;
    final target = File('${dir.path}/essai.pmtiles');

    final result = await extractPmtiles(
      source: MemoryByteSource(fixture.readAsBytesSync()),
      target: target,
      area: (west: h.minLon, south: h.minLat, east: h.maxLon, north: h.maxLat),
      minZoom: h.minZoom,
      maxZoom: h.maxZoom,
    );

    final extracted = await openFile(target);
    addTearDown(extracted.close);
    expect(result.addressedTiles, 3);
    for (final id in tileIdsCovering((west: h.minLon, south: h.minLat, east: h.maxLon, north: h.maxLat), h.minZoom, h.maxZoom)) {
      final (z, x, y) = tileIdToZxy(id);
      expect(await extracted.tile(z, x, y), await source.tile(z, x, y));
    }
    await source.close();
  });
}
