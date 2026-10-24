import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'mvt.dart';
import 'projection.dart';

/// Taille d'une tuile à l'écran au zoom entier, en pixels logiques.
const tilePixels = 256.0;

/// Les couleurs de la carte : fond presque noir, routes claires, rien de coloré
/// sauf ce qui compte (eau, parcs, hôpitaux). Lisible en plein soleil.
class MapColors {
  static const background = Color(0xFF0B0B0B);
  static const park = Color(0xFF122A1C);
  static const pedestrian = Color(0xFF191919);
  static const hospital = Color(0xFF331A1A);
  static const water = Color(0xFF0F2F48);
  static const building = Color(0xFF282828);
  static const buildingEdge = Color(0xFF444444);
  static const highway = Color(0xFFFFFFFF);
  static const majorRoad = Color(0xFFE8E8E8);
  static const mediumRoad = Color(0xFFD0D0D0);
  static const minorRoad = Color(0xFF9E9E9E);
  static const otherRoad = Color(0xFF7C7C7C);
  static const path = Color(0xFF626262);
  static const rail = Color(0xFF505050);
  static const text = Color(0xFFFFFFFF);
  static const mutedText = Color(0xFFBDBDBD);
  static const halo = Color(0xFF000000);
}

enum MapLabelKind { place, road, poi }

/// Un texte ou un symbole à poser sur la carte. Dessiné à chaque image, à
/// l'écran, pour rester droit et de taille constante quand on zoome.
class MapLabel {
  MapLabel({
    required this.kind,
    required this.text,
    required this.x,
    required this.y,
    required this.minZoom,
    this.angle = 0,
    this.priority = 0,
    this.symbol,
    this.color,
  });

  final MapLabelKind kind;
  final String text;

  /// Position en unités de tuile.
  final double x;
  final double y;
  final double minZoom;

  /// Pour une route : l'angle du texte, en radians.
  final double angle;
  final int priority;

  /// Pour un lieu utile : la lettre du symbole.
  final String? symbol;
  final Color? color;
}

/// Une tuile prête à être dessinée : un dessin enregistré en unités de tuile
/// (donc réutilisable à tous les zooms) et les textes à poser par-dessus.
class RenderedTile {
  RenderedTile(this.z, this.x, this.y, this.extent, this.picture, this.labels);

  final int z;
  final int x;
  final int y;
  final int extent;
  final Picture picture;
  final List<MapLabel> labels;

  void dispose() => picture.dispose();
}

class _RoadStyle {
  const _RoadStyle(this.meters, this.color, this.order);

  final double meters;
  final Color color;
  final int order;
}

_RoadStyle? _roadStyle(String? kind, String? detail) {
  switch (kind) {
    case 'highway':
      return const _RoadStyle(20, MapColors.highway, 6);
    case 'major_road':
      final width = switch (detail) {
        'primary' || 'primary_link' => 14.0,
        'secondary' || 'secondary_link' => 12.0,
        _ => 10.0,
      };
      return _RoadStyle(width, MapColors.majorRoad, 5);
    case 'medium_road':
      return const _RoadStyle(9, MapColors.mediumRoad, 4);
    case 'minor_road':
      return const _RoadStyle(6, MapColors.minorRoad, 3);
    case 'other':
      return const _RoadStyle(5, MapColors.otherRoad, 2);
    case 'path':
      return const _RoadStyle(2, MapColors.path, 1);
    case 'rail':
      return const _RoadStyle(2, MapColors.rail, 0);
  }
  return null;
}

/// Aux petits zooms, seules les grandes routes se dessinent : sinon la ville
/// n'est qu'un amas de traits blancs.
bool _roadVisible(_RoadStyle style, int z) => switch (style.order) {
      >= 5 => true,
      4 => z >= 12,
      0 => z >= 13,
      3 || 2 => z >= 14,
      _ => z >= 15,
    };

Color? _landuseColor(String? kind) => switch (kind) {
      'park' ||
      'forest' ||
      'wood' ||
      'grass' ||
      'garden' ||
      'scrub' ||
      'dog_park' ||
      'playground' ||
      'pitch' ||
      'nature_reserve' ||
      'cemetery' ||
      'meadow' ||
      'farmland' =>
        MapColors.park,
      'pedestrian' || 'platform' => MapColors.pedestrian,
      'hospital' => MapColors.hospital,
      _ => null,
    };

void _addRings(Path path, List<Float32List> rings) {
  for (final ring in rings) {
    if (ring.length < 6) continue;
    path.moveTo(ring[0], ring[1]);
    for (var i = 2; i + 1 < ring.length; i += 2) {
      path.lineTo(ring[i], ring[i + 1]);
    }
    path.close();
  }
}

void _addLines(Path path, List<Float32List> lines) {
  for (final line in lines) {
    if (line.length < 4) continue;
    path.moveTo(line[0], line[1]);
    for (var i = 2; i + 1 < line.length; i += 2) {
      path.lineTo(line[i], line[i + 1]);
    }
  }
}

/// Le milieu de la plus longue ligne et l'angle du segment qui s'y trouve.
(double, double, double)? _lineMiddle(List<Float32List> lines) {
  Float32List? best;
  var bestLength = 0.0;
  for (final line in lines) {
    var length = 0.0;
    for (var i = 2; i + 1 < line.length; i += 2) {
      length += math.sqrt(math.pow(line[i] - line[i - 2], 2) + math.pow(line[i + 1] - line[i - 1], 2));
    }
    if (length > bestLength) {
      bestLength = length;
      best = line;
    }
  }
  if (best == null || bestLength == 0) return null;
  var walked = 0.0;
  for (var i = 2; i + 1 < best.length; i += 2) {
    final dx = best[i] - best[i - 2];
    final dy = best[i + 1] - best[i - 1];
    final segment = math.sqrt(dx * dx + dy * dy);
    if (walked + segment >= bestLength / 2 && segment > 0) {
      final t = (bestLength / 2 - walked) / segment;
      return (best[i - 2] + dx * t, best[i - 1] + dy * t, math.atan2(dy, dx));
    }
    walked += segment;
  }
  return null;
}

({String symbol, Color color, double minZoom})? _poiSymbol(String? kind) => switch (kind) {
      'hospital' || 'clinic' => (symbol: 'H', color: const Color(0xFFFF6B5E), minZoom: 14),
      'pharmacy' => (symbol: 'P', color: const Color(0xFF58D68D), minZoom: 16),
      'drinking_water' => (symbol: 'E', color: const Color(0xFF5DADE2), minZoom: 16),
      'toilets' => (symbol: 'WC', color: const Color(0xFFD7BDE2), minZoom: 16),
      // Le jaune est réservé au parcours et aux lieux des organisateurs.
      'station' => (symbol: 'M', color: const Color(0xFFE0E0E0), minZoom: 15),
      _ => null,
    };

/// Dessine une tuile décodée. Les largeurs de route sont en mètres réels : une
/// avenue de 14 m reste une avenue de 14 m à tous les zooms.
RenderedTile renderTile(MvtTile tile, int z, int x, int y) {
  var extent = 4096;
  for (final layer in tile.layers.values) {
    extent = layer.extent;
    break;
  }
  final lat = tileYToLat(y + 0.5, z.toDouble());
  final pixelsPerMeter = 1 / metersPerPixel(lat, z.toDouble());
  final unitsPerPixel = extent / tilePixels;
  final unitsPerMeter = pixelsPerMeter * unitsPerPixel;
  double widthOf(double meters, {double minPixels = 1.0}) =>
      math.max(meters * unitsPerMeter, minPixels * unitsPerPixel);

  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  final fill = Paint()..style = PaintingStyle.fill;
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final labels = <MapLabel>[];

  // Fond de la tuile. Elle est découpée à ses bords quand on la dessine : les
  // objets qui débordent (routes, bâtiments) sont aussi dans la tuile voisine.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, extent.toDouble(), extent.toDouble()),
    fill..color = MapColors.background,
  );

  // Surfaces : parcs, zones piétonnes, hôpitaux.
  final landuse = tile['landuse'];
  if (landuse != null) {
    final byColor = <Color, Path>{};
    for (final f in landuse.features) {
      if (f.type != MvtGeometry.polygon) continue;
      final color = _landuseColor(f.kind);
      if (color == null) continue;
      _addRings(byColor.putIfAbsent(color, () => Path()..fillType = PathFillType.evenOdd), f.parts);
    }
    byColor.forEach((color, path) => canvas.drawPath(path, fill..color = color));
  }
  final landcover = tile['landcover'] ?? tile['natural'];
  if (landcover != null) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final f in landcover.features) {
      if (f.type == MvtGeometry.polygon && _landuseColor(f.kind) == MapColors.park) {
        _addRings(path, f.parts);
      }
    }
    canvas.drawPath(path, fill..color = MapColors.park);
  }

  // Eau : surfaces, puis cours d'eau.
  final water = tile['water'];
  if (water != null) {
    final surfaces = Path()..fillType = PathFillType.evenOdd;
    final rivers = Path();
    final streams = Path();
    for (final f in water.features) {
      switch (f.type) {
        case MvtGeometry.polygon:
          _addRings(surfaces, f.parts);
        case MvtGeometry.line:
          _addLines(f.kind == 'stream' || f.kind == 'ditch' || f.kind == 'drain' ? streams : rivers, f.parts);
        case MvtGeometry.point:
          break;
      }
    }
    canvas.drawPath(surfaces, fill..color = MapColors.water);
    canvas.drawPath(rivers, stroke..color = MapColors.water..strokeWidth = widthOf(14, minPixels: 1.5));
    canvas.drawPath(streams, stroke..color = MapColors.water..strokeWidth = widthOf(2));
  }

  // Bâtiments.
  final buildings = tile['buildings'];
  if (buildings != null) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final f in buildings.features) {
      if (f.type == MvtGeometry.polygon && f.kind != 'building_part') _addRings(path, f.parts);
    }
    canvas.drawPath(path, fill..color = MapColors.building);
    if (z >= 15) {
      canvas.drawPath(
        path,
        stroke
          ..color = MapColors.buildingEdge
          ..strokeWidth = 0.7 * unitsPerPixel,
      );
    }
  }

  // Routes, des plus petites aux plus grandes.
  final roads = tile['roads'];
  if (roads != null) {
    final classes = <_RoadStyle, Path>{};
    final seen = <String, _RoadStyle>{};
    for (final f in roads.features) {
      if (f.type != MvtGeometry.line) continue;
      final style = _roadStyle(f.kind, f.props['kind_detail'] as String?);
      if (style == null || !_roadVisible(style, z)) continue;
      final canonical = seen.putIfAbsent('${style.order}/${style.meters}', () => style);
      _addLines(classes.putIfAbsent(canonical, () => Path()), f.parts);

      final name = f.name;
      if (name != null && style.order >= 2) {
        final middle = _lineMiddle(f.parts);
        if (middle != null) {
          labels.add(MapLabel(
            kind: MapLabelKind.road,
            text: name,
            x: middle.$1,
            y: middle.$2,
            angle: middle.$3,
            minZoom: style.order >= 4 ? 14 : 16,
            priority: style.order,
          ));
        }
      }
    }
    final ordered = classes.entries.toList()..sort((a, b) => a.key.order.compareTo(b.key.order));
    for (final entry in ordered) {
      canvas.drawPath(
        entry.value,
        stroke
          ..color = entry.key.color
          ..strokeWidth = widthOf(entry.key.meters, minPixels: entry.key.order == 0 ? 0.8 : 1.0),
      );
    }
  }

  // Lieux et symboles.
  final places = tile['places'];
  if (places != null) {
    for (final f in places.features) {
      final name = f.name;
      if (name == null || f.type != MvtGeometry.point || f.parts.isEmpty) continue;
      final kind = f.kind;
      if (kind != 'locality' && kind != 'neighbourhood' && kind != 'macrohood') continue;
      final minZoom = (f.props['min_zoom'] as num?)?.toDouble() ?? 12;
      labels.add(MapLabel(
        kind: MapLabelKind.place,
        text: kind == 'locality' ? name : name.toUpperCase(),
        x: f.parts.first[0],
        y: f.parts.first[1],
        minZoom: minZoom,
        priority: (f.props['population_rank'] as num?)?.toInt() ?? 0,
      ));
    }
  }
  final pois = tile['pois'];
  if (pois != null) {
    for (final f in pois.features) {
      if (f.type != MvtGeometry.point || f.parts.isEmpty) continue;
      final symbol = _poiSymbol(f.kind);
      if (symbol == null) continue;
      labels.add(MapLabel(
        kind: MapLabelKind.poi,
        text: f.name ?? '',
        x: f.parts.first[0],
        y: f.parts.first[1],
        minZoom: symbol.minZoom,
        priority: 100,
        symbol: symbol.symbol,
        color: symbol.color,
      ));
    }
  }
  final waterPoints = tile['water'];
  if (waterPoints != null) {
    for (final f in waterPoints.features) {
      if (f.type == MvtGeometry.point && f.kind == 'drinking_water' && f.parts.isNotEmpty) {
        labels.add(MapLabel(
          kind: MapLabelKind.poi,
          text: f.name ?? '',
          x: f.parts.first[0],
          y: f.parts.first[1],
          minZoom: 16,
          priority: 100,
          symbol: 'E',
          color: const Color(0xFF5DADE2),
        ));
      }
    }
  }

  return RenderedTile(z, x, y, extent, recorder.endRecording(), labels);
}
