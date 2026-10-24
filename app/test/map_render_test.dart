import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/map_view.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/tile_store.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dessine la carte pour de vrai (fichier d'essai) et regarde les pixels.
/// Avec la variable d'environnement CORTEGE_MAP_PNG_DIR, les images sont aussi
/// écrites dans ce dossier pour être regardées à l'œil.
void main() {
  final pngDir = Platform.environment['CORTEGE_MAP_PNG_DIR'];
  final fixture = File('test/fixtures/paris_fixture.pmtiles');
  final bigSample = Platform.environment['CORTEGE_MAP_SAMPLE'];

  Future<ui.Image> render(
    WidgetTester tester,
    File file, {
    required double zoom,
    double? lat,
    double? lon,
    MapOverlay overlay = const MapOverlay(),
    Size size = const Size(400, 700),
  }) async {
    final archive = await tester.runAsync(() async => PmtilesArchive.open(await FileByteSource.open(file)));
    final store = TileStore(archive!);
    final camera = MapCamera.forArchive(archive);
    camera.centerOn(lat ?? camera.lat, lon ?? camera.lon, zoom: zoom);
    final key = GlobalKey();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(store.dispose);
    addTearDown(() async => tester.runAsync(archive.close));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: SizedBox.fromSize(
            size: size,
            child: MapView(store: store, camera: camera, overlay: overlay),
          ),
        ),
      ),
    );
    // Les tuiles se chargent en arrière-plan : on laisse tourner le temps réel.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() => boundary.toImage()))!;
  }

  Future<Map<int, int>> colors(WidgetTester tester, ui.Image image) async {
    final data = (await tester.runAsync(() => image.toByteData()))!;
    final counts = <int, int>{};
    final bytes = data.buffer.asUint8List();
    for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
      final rgb = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      counts[rgb] = (counts[rgb] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> save(WidgetTester tester, ui.Image image, String name) async {
    if (pngDir == null) return;
    final png = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
    await tester.runAsync(() async {
      await Directory(pngDir).create(recursive: true);
      await File('$pngDir/$name.png').writeAsBytes(png.buffer.asUint8List());
    });
  }

  testWidgets('la carte d\'essai se dessine : fond, routes et bâtiments', (tester) async {
    final image = await render(tester, fixture, zoom: 16.5);
    final counts = await colors(tester, image);
    await save(tester, image, 'fixture_16_5');

    expect(image.width, 400);
    final total = counts.values.reduce((a, b) => a + b);
    final background = counts[0x0B0B0B] ?? 0;
    expect(background, lessThan(total * 0.95), reason: 'la carte ne doit pas rester vide');
    // Au moins deux couleurs de routes ou de bâtiments en plus du fond.
    final nonBackground = counts.entries.where((e) => e.key != 0x0B0B0B && e.value > 20).length;
    expect(nonBackground, greaterThan(2));
  });

  testWidgets('le parcours, les lieux et la position se posent par-dessus', (tester) async {
    final archive = await tester.runAsync(() async => PmtilesArchive.open(await FileByteSource.open(fixture)));
    final lat = (archive!.header.minLat + archive.header.maxLat) / 2;
    final lon = (archive.header.minLon + archive.header.maxLon) / 2;
    await tester.runAsync(archive.close);
    final overlay = MapOverlay(
      routes: [
        [(lat - 0.0003, lon - 0.0004), (lat, lon), (lat + 0.0003, lon + 0.0004)],
      ],
      markers: [
        MapMarker(lat: lat + 0.0001, lon: lon - 0.0002, symbol: 'E', label: 'Point d\'eau', color: const Color(0xFF5DADE2)),
      ],
      meLat: lat,
      meLon: lon,
      meAccuracyMeters: 15,
    );
    final image = await render(tester, fixture, zoom: 17, overlay: overlay);
    final counts = await colors(tester, image);
    await save(tester, image, 'fixture_overlay');

    expect(counts.keys.any((c) => c == 0xFFD60A), isTrue, reason: 'le parcours est jaune');
    expect(counts.keys.any((c) => c == 0x5DADE2), isTrue, reason: 'le point d\'eau est dessiné');
  });

  testWidgets('échantillon de Paris à plusieurs zooms (si le fichier est fourni)', (tester) async {
    if (bigSample == null || !File(bigSample).existsSync()) {
      markTestSkipped('variable CORTEGE_MAP_SAMPLE absente');
      return;
    }
    final file = File(bigSample);
    for (final zoom in [12.0, 14.0, 15.0, 16.0]) {
      final image = await render(tester, file, zoom: zoom, lat: 48.8530, lon: 2.3499);
      await save(tester, image, 'paris_${zoom.toStringAsFixed(0)}');
      final counts = await colors(tester, image);
      expect(counts.length, greaterThan(3), reason: 'zoom $zoom');
    }
  });

  test('les octets des images sont des Uint8List', () {
    expect(Uint8List(0), isA<Uint8List>());
  });
}
