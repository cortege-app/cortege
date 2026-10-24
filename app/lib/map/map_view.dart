import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';

import 'pmtiles.dart';
import 'projection.dart';
import 'tile_store.dart';
import 'tile_style.dart';

/// Un lieu posé sur la carte par les organisateurs (point d'eau, rendez-vous...).
class MapMarker {
  const MapMarker({
    required this.lat,
    required this.lon,
    required this.symbol,
    required this.label,
    required this.color,
  });

  final double lat;
  final double lon;

  /// Une ou deux lettres, dessinées dans le rond.
  final String symbol;
  final String label;
  final Color color;
}

/// Ce qu'on pose par-dessus la carte : le parcours, les lieux, la position de
/// l'utilisateur.
class MapOverlay {
  const MapOverlay({
    this.routes = const [],
    this.markers = const [],
    this.meLat,
    this.meLon,
    this.meAccuracyMeters,
  });

  /// Les parcours : chacun est une suite de (latitude, longitude).
  final List<List<(double, double)>> routes;
  final List<MapMarker> markers;
  final double? meLat;
  final double? meLon;
  final double? meAccuracyMeters;
}

/// Où l'on regarde : un centre et un zoom. Le centre est en « coordonnées du
/// monde » (0 à 1 sur toute la carte du monde) pour que le zoom ne le déplace pas.
class MapCamera extends ChangeNotifier {
  MapCamera({
    required double lon,
    required double lat,
    required double zoom,
    required this.minZoom,
    required this.maxZoom,
    ({double west, double south, double east, double north})? bounds,
  })  : _bounds = bounds,
        _zoom = zoom.clamp(minZoom, maxZoom),
        _cx = lonToTileX(lon, 0),
        _cy = latToTileY(lat, 0);

  factory MapCamera.forArchive(PmtilesArchive archive) {
    final h = archive.header;
    final lon = h.centerLon != 0 || h.centerLat != 0 ? h.centerLon : (h.minLon + h.maxLon) / 2;
    final lat = h.centerLon != 0 || h.centerLat != 0 ? h.centerLat : (h.minLat + h.maxLat) / 2;
    return MapCamera(
      lon: lon,
      lat: lat,
      zoom: math.min(15, h.maxZoom).toDouble(),
      minZoom: h.minZoom.toDouble(),
      maxZoom: h.maxZoom + 2.0,
      bounds: (west: h.minLon, south: h.minLat, east: h.maxLon, north: h.maxLat),
    );
  }

  /// Une caméra sans fond de carte : elle cadre les points du parcours et des
  /// lieux. Au moins 600 m de large, pour qu'un seul lieu ne donne pas un zoom
  /// absurde.
  factory MapCamera.forPoints(Iterable<(double, double)> points) {
    var west = 180.0;
    var east = -180.0;
    var south = 90.0;
    var north = -90.0;
    for (final (lat, lon) in points) {
      west = math.min(west, lon);
      east = math.max(east, lon);
      south = math.min(south, lat);
      north = math.max(north, lat);
    }
    if (west > east) {
      west = -0.01;
      east = 0.01;
      south = -0.01;
      north = 0.01;
    }
    final lon = (west + east) / 2;
    final lat = (south + north) / 2;
    final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.05, 1.0);
    final minSpan = 600 / (40075017.0 * cosLat);
    final span = math.max(
      math.max(lonToTileX(east, 0) - lonToTileX(west, 0), latToTileY(south, 0) - latToTileY(north, 0)),
      minSpan,
    );
    // Environ 300 pixels pour l'ensemble : le tout tient sur un petit écran.
    final zoom = (math.log(300 / (tilePixels * span)) / math.ln2).clamp(3.0, 18.0);
    final halfLon = span * 360 / 2;
    final halfLat = halfLon * cosLat;
    return MapCamera(
      lon: lon,
      lat: lat,
      zoom: zoom,
      minZoom: 3,
      maxZoom: 19,
      bounds: (
        west: lon - halfLon,
        south: lat - halfLat,
        east: lon + halfLon,
        north: lat + halfLat,
      ),
    );
  }

  final double minZoom;
  final double maxZoom;
  final ({double west, double south, double east, double north})? _bounds;
  double _cx;
  double _cy;
  double _zoom;

  double get zoom => _zoom;
  double get worldX => _cx;
  double get worldY => _cy;

  double get lon => tileXToLon(_cx, 0);
  double get lat => tileYToLat(_cy, 0);

  /// Taille du monde entier à ce zoom, en pixels.
  double get worldPixels => tilePixels * math.pow(2, _zoom);

  void set({double? zoom, double? worldX, double? worldY}) {
    _zoom = (zoom ?? _zoom).clamp(minZoom, maxZoom);
    _cx = worldX ?? _cx;
    _cy = worldY ?? _cy;
    final b = _bounds;
    if (b != null) {
      // On ne s'éloigne pas de plus d'une demi-zone des données : se perdre sur
      // une carte vide, hors ligne, ne sert à rien.
      final w = lonToTileX(b.east, 0) - lonToTileX(b.west, 0);
      final h = latToTileY(b.south, 0) - latToTileY(b.north, 0);
      _cx = _cx.clamp(lonToTileX(b.west, 0) - w / 2, lonToTileX(b.east, 0) + w / 2);
      _cy = _cy.clamp(latToTileY(b.north, 0) - h / 2, latToTileY(b.south, 0) + h / 2);
    }
    notifyListeners();
  }

  void centerOn(double lat, double lon, {double? zoom}) =>
      set(zoom: zoom, worldX: lonToTileX(lon, 0), worldY: latToTileY(lat, 0));

  void zoomBy(double delta) => set(zoom: _zoom + delta);

  Offset toScreen(double lat, double lon, Size size) {
    final px = worldPixels;
    return Offset(
      size.width / 2 + (lonToTileX(lon, 0) - _cx) * px,
      size.height / 2 + (latToTileY(lat, 0) - _cy) * px,
    );
  }
}

/// La carte : tuiles, parcours, lieux, position. Se déplace au doigt, se zoome
/// en pinçant ou en touchant deux fois. Pas de rotation : le nord est en haut.
/// Sans [store], il n'y a pas de fond : parcours, lieux et position sur un
/// quadrillage, avec l'échelle.
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    this.store,
    required this.camera,
    this.overlay = const MapOverlay(),
    this.onMarkerTap,
  });

  final TileStore? store;
  final MapCamera camera;
  final MapOverlay overlay;
  final void Function(MapMarker marker)? onMarkerTap;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final _text = _TextCache();
  var _size = Size.zero;
  var _startZoom = 0.0;
  var _startX = 0.0;
  var _startY = 0.0;
  var _startFocal = Offset.zero;
  var _doubleTapAt = Offset.zero;

  MapCamera get _camera => widget.camera;

  void _onScaleStart(ScaleStartDetails details) {
    _startZoom = _camera.zoom;
    _startX = _camera.worldX;
    _startY = _camera.worldY;
    _startFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final zoom = (_startZoom + math.log(details.scale) / math.ln2).clamp(_camera.minZoom, _camera.maxZoom);
    final startPixels = tilePixels * math.pow(2, _startZoom);
    // Le point du monde qui était sous les doigts au début doit y rester.
    final worldX = _startX + (_startFocal.dx - _size.width / 2) / startPixels;
    final worldY = _startY + (_startFocal.dy - _size.height / 2) / startPixels;
    final pixels = tilePixels * math.pow(2, zoom);
    _camera.set(
      zoom: zoom.toDouble(),
      worldX: worldX - (details.localFocalPoint.dx - _size.width / 2) / pixels,
      worldY: worldY - (details.localFocalPoint.dy - _size.height / 2) / pixels,
    );
  }

  void _zoomAt(Offset point, double delta) {
    final before = _camera.worldPixels;
    final worldX = _camera.worldX + (point.dx - _size.width / 2) / before;
    final worldY = _camera.worldY + (point.dy - _size.height / 2) / before;
    final zoom = (_camera.zoom + delta).clamp(_camera.minZoom, _camera.maxZoom).toDouble();
    final after = tilePixels * math.pow(2, zoom);
    _camera.set(
      zoom: zoom,
      worldX: worldX - (point.dx - _size.width / 2) / after,
      worldY: worldY - (point.dy - _size.height / 2) / after,
    );
  }

  void _onTapUp(TapUpDetails details) {
    final onTap = widget.onMarkerTap;
    if (onTap == null) return;
    MapMarker? nearest;
    var best = 30.0;
    for (final marker in widget.overlay.markers) {
      final distance = (_camera.toScreen(marker.lat, marker.lon, _size) - details.localPosition).distance;
      if (distance < best) {
        best = distance;
        nearest = marker;
      }
    }
    if (nearest != null) onTap(nearest);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          _size = constraints.biggest;
          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _zoomAt(event.localPosition, -event.scrollDelta.dy / 300);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onTapUp: _onTapUp,
              onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
              onDoubleTap: () => _zoomAt(_doubleTapAt, 1),
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _MapPainter(widget.store, _camera, widget.overlay, _text),
                ),
              ),
            ),
          );
        },
      );
}

class _TextCache {
  final _cache = <String, TextPainter>{};

  TextPainter get(String text, double size, Color color, {bool bold = false, bool halo = false}) {
    final key = '$text|$size|${color.toARGB32()}|$bold|$halo';
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length > 600) _cache.clear();
    final style = TextStyle(
      fontSize: size,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
      color: halo ? null : color,
      foreground: halo
          ? (Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..strokeJoin = StrokeJoin.round
            ..color = MapColors.halo)
          : null,
    );
    return _cache[key] = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.store, this.camera, this.overlay, this.text)
      : super(repaint: Listenable.merge([?store, camera]));

  final TileStore? store;
  final MapCamera camera;
  final MapOverlay overlay;
  final _TextCache text;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = MapColors.background);
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final labels = <(MapLabel, Offset, double)>[]; // étiquette, position, échelle
    final tiles = store;
    if (tiles == null) {
      _drawGrid(canvas, size);
    } else if (!_paintTiles(canvas, size, tiles, labels)) {
      canvas.restore();
      return; // zoom incohérent avec la taille de l'écran : on ne charge rien
    }
    canvas.restore();

    _drawOverlay(canvas, size);
    _drawLabels(canvas, size, labels);
    _drawScale(canvas, size);
  }

  /// Quadrillage en degrés, quand il n'y a pas de fond de carte : de quoi sentir
  /// qu'on se déplace et de quoi se repérer entre les lieux.
  void _drawGrid(Canvas canvas, Size size) {
    final perDegree = camera.worldPixels / 360;
    double? step;
    for (final candidate in [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]) {
      if (candidate * perDegree >= 70) {
        step = candidate;
        break;
      }
    }
    if (step == null) return;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x33FFFFFF);
    final west = camera.lon - size.width / 2 / perDegree;
    final east = camera.lon + size.width / 2 / perDegree;
    for (var lon = (west / step).floorToDouble() * step; lon <= east; lon += step) {
      final x = camera.toScreen(camera.lat, lon, size).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    final north = camera.lat + size.height / 2 / perDegree;
    final south = camera.lat - size.height / 2 / perDegree;
    for (var lat = (south / step).floorToDouble() * step; lat <= north; lat += step) {
      final y = camera.toScreen(lat, camera.lon, size).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  /// Dessine les tuiles visibles. Faux si l'écran demanderait trop de tuiles.
  bool _paintTiles(Canvas canvas, Size size, TileStore store, List<(MapLabel, Offset, double)> labels) {
    final header = store.archive.header;
    final zoom = camera.zoom;
    final tz = zoom.round().clamp(header.minZoom, header.maxZoom);
    final n = 1 << tz;
    final worldPixels = camera.worldPixels;
    final tileScreen = worldPixels / n;
    final left = camera.worldX - size.width / 2 / worldPixels;
    final right = camera.worldX + size.width / 2 / worldPixels;
    final top = camera.worldY - size.height / 2 / worldPixels;
    final bottom = camera.worldY + size.height / 2 / worldPixels;
    final x0 = (left * n).floor().clamp(0, n - 1);
    final x1 = (right * n).floor().clamp(0, n - 1);
    final y0 = (top * n).floor().clamp(0, n - 1);
    final y1 = (bottom * n).floor().clamp(0, n - 1);

    final visible = <(int, int, int)>[
      for (var y = y0; y <= y1; y++)
        for (var x = x0; x <= x1; x++) (tz, x, y),
    ];
    if (visible.length > 64) return false;
    // Les tuiles du centre d'abord.
    visible.sort((a, b) {
      double d((int, int, int) t) {
        final cx = (t.$2 + 0.5) / n - camera.worldX;
        final cy = (t.$3 + 0.5) / n - camera.worldY;
        return cx * cx + cy * cy;
      }

      return d(a).compareTo(d(b));
    });
    store.want(visible);

    for (final t in visible) {
      final sx = size.width / 2 + (t.$2 / n - camera.worldX) * worldPixels;
      final sy = size.height / 2 + (t.$3 / n - camera.worldY) * worldPixels;
      final tile = store.peek(t.$1, t.$2, t.$3);
      if (tile != null) {
        _drawTile(canvas, tile, sx, sy, tileScreen);
        final k = tileScreen / tile.extent;
        for (final label in tile.labels) {
          if (label.minZoom > zoom + 0.5) continue;
          labels.add((label, Offset(sx + label.x * k, sy + label.y * k), k));
        }
      } else if (!store.isAbsent(t.$1, t.$2, t.$3)) {
        _drawAncestor(canvas, store, t, sx, sy, tileScreen, header.minZoom);
      }
    }
    return true;
  }

  void _drawTile(Canvas canvas, RenderedTile tile, double sx, double sy, double tileScreen) {
    final k = tileScreen / tile.extent;
    canvas.save();
    canvas.translate(sx, sy);
    canvas.scale(k);
    final bleed = 0.5 / k;
    canvas.clipRect(
      Rect.fromLTWH(-bleed, -bleed, tile.extent + 2 * bleed, tile.extent + 2 * bleed),
      doAntiAlias: false,
    );
    canvas.drawPicture(tile.picture);
    canvas.restore();
  }

  /// En attendant la bonne tuile, on montre celle du dessus, agrandie.
  void _drawAncestor(
    Canvas canvas,
    TileStore store,
    (int, int, int) t,
    double sx,
    double sy,
    double tileScreen,
    int minZoom,
  ) {
    for (var up = 1; up <= 3; up++) {
      final az = t.$1 - up;
      if (az < minZoom) return;
      final ax = t.$2 >> up;
      final ay = t.$3 >> up;
      final ancestor = store.peek(az, ax, ay);
      if (ancestor == null) continue;
      final ancestorScreen = tileScreen * (1 << up);
      final ox = sx - (t.$2 - (ax << up)) * tileScreen;
      final oy = sy - (t.$3 - (ay << up)) * tileScreen;
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(sx, sy, tileScreen, tileScreen), doAntiAlias: false);
      _drawTile(canvas, ancestor, ox, oy, ancestorScreen);
      canvas.restore();
      return;
    }
  }

  void _drawOverlay(Canvas canvas, Size size) {
    for (final route in overlay.routes) {
      if (route.length < 2) continue;
      final path = Path();
      for (var i = 0; i < route.length; i++) {
        final p = camera.toScreen(route[i].$1, route[i].$2, size);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, line..color = Colors.black..strokeWidth = 9);
      canvas.drawPath(path, line..color = const Color(0xFFFFD60A)..strokeWidth = 5);
    }
    final lat = overlay.meLat;
    final lon = overlay.meLon;
    if (lat != null && lon != null) {
      final p = camera.toScreen(lat, lon, size);
      final accuracy = overlay.meAccuracyMeters;
      if (accuracy != null && accuracy > 0) {
        final radius = accuracy / metersPerPixel(lat, camera.zoom);
        if (radius > 10) {
          canvas.drawCircle(
            p,
            radius,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = const Color(0xAAFFD60A),
          );
        }
      }
      canvas.drawCircle(p, 9, Paint()..color = Colors.black);
      canvas.drawCircle(p, 6.5, Paint()..color = Colors.white);
    }
  }

  void _drawLabels(Canvas canvas, Size size, List<(MapLabel, Offset, double)> labels) {
    final placed = <Rect>[];
    bool free(Rect r) {
      for (final other in placed) {
        if (other.overlaps(r)) return false;
      }
      return true;
    }

    // Les lieux des organisateurs passent avant tout le reste.
    for (final marker in overlay.markers) {
      final p = camera.toScreen(marker.lat, marker.lon, size);
      if (!(Offset.zero & size).inflate(40).contains(p)) continue;
      placed.add(Rect.fromCircle(center: p, radius: 16));
      canvas.drawCircle(p, 14, Paint()..color = Colors.black);
      canvas.drawCircle(p, 12, Paint()..color = marker.color);
      final symbol = text.get(marker.symbol, 12, Colors.black, bold: true);
      symbol.paint(canvas, p - Offset(symbol.width / 2, symbol.height / 2));
      if ((camera.zoom >= 14.5 || store == null) && marker.label.isNotEmpty) {
        final halo = text.get(marker.label, 12, MapColors.text, bold: true, halo: true);
        final fill = text.get(marker.label, 12, MapColors.text, bold: true);
        final at = p + Offset(-halo.width / 2, 15);
        final box = at & halo.size;
        if (free(box)) {
          placed.add(box);
          halo.paint(canvas, at);
          fill.paint(canvas, at);
        }
      }
    }

    final sorted = labels.toList()..sort((a, b) => b.$1.priority.compareTo(a.$1.priority));
    var drawn = 0;
    for (final (label, at, _) in sorted) {
      if (drawn >= 160) break;
      if (!(Offset.zero & size).inflate(20).contains(at)) continue;
      switch (label.kind) {
        case MapLabelKind.poi:
          final box = Rect.fromCircle(center: at, radius: 11);
          if (!free(box)) continue;
          placed.add(box);
          canvas.drawCircle(at, 10, Paint()..color = Colors.black);
          canvas.drawCircle(at, 8.5, Paint()..color = label.color ?? Colors.white);
          final symbol = text.get(label.symbol ?? '', 10, Colors.black, bold: true);
          symbol.paint(canvas, at - Offset(symbol.width / 2, symbol.height / 2));
          drawn++;
        case MapLabelKind.place:
          final halo = text.get(label.text, label.priority > 8 ? 15 : 12, MapColors.mutedText, bold: true, halo: true);
          final fill = text.get(label.text, label.priority > 8 ? 15 : 12, MapColors.mutedText, bold: true);
          final box = Rect.fromCenter(center: at, width: halo.width, height: halo.height);
          if (!free(box)) continue;
          placed.add(box.inflate(4));
          halo.paint(canvas, box.topLeft);
          fill.paint(canvas, box.topLeft);
          drawn++;
        case MapLabelKind.road:
          var angle = label.angle;
          if (angle > math.pi / 2) angle -= math.pi;
          if (angle < -math.pi / 2) angle += math.pi;
          final halo = text.get(label.text, 11, MapColors.text, halo: true);
          final fill = text.get(label.text, 11, MapColors.text);
          final bounds = Rect.fromCenter(
            center: at,
            width: halo.width * math.cos(angle).abs() + halo.height * math.sin(angle).abs(),
            height: halo.width * math.sin(angle).abs() + halo.height * math.cos(angle).abs(),
          );
          if (!free(bounds)) continue;
          placed.add(bounds.inflate(3));
          canvas.save();
          canvas.translate(at.dx, at.dy);
          canvas.rotate(angle);
          halo.paint(canvas, Offset(-halo.width / 2, -halo.height / 2));
          fill.paint(canvas, Offset(-halo.width / 2, -halo.height / 2));
          canvas.restore();
          drawn++;
      }
    }

    // L'attribution OpenStreetMap est obligatoire dès qu'on montre ses données :
    // elle reste toujours visible.
    if (store == null) return;
    final attribution = text.get('© OpenStreetMap', 10, MapColors.mutedText, halo: true);
    final attributionFill = text.get('© OpenStreetMap', 10, MapColors.mutedText);
    final at = Offset(8, size.height - attribution.height - 6);
    attribution.paint(canvas, at);
    attributionFill.paint(canvas, at);
  }

  void _drawScale(Canvas canvas, Size size) {
    final lat = camera.lat;
    final perPixel = metersPerPixel(lat, camera.zoom);
    for (final meters in [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]) {
      final pixels = meters / perPixel;
      if (pixels < 50) continue;
      if (pixels > 150) break;
      final y = size.height - 34;
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white;
      final shadow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = Colors.black;
      final path = Path()
        ..moveTo(8, y - 5)
        ..lineTo(8, y)
        ..lineTo(8 + pixels, y)
        ..lineTo(8 + pixels, y - 5);
      canvas.drawPath(path, shadow);
      canvas.drawPath(path, line);
      final label = meters >= 1000 ? '${meters ~/ 1000} km' : '$meters m';
      final halo = text.get(label, 11, MapColors.text, halo: true);
      final fill = text.get(label, 11, MapColors.text);
      halo.paint(canvas, Offset(8, y - 22));
      fill.paint(canvas, Offset(8, y - 22));
      return;
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.overlay != overlay || old.store != store || old.camera != camera;
}
