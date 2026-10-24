import 'dart:math' as math;

/// Projection de Mercator « web » : celle de toutes les cartes en tuiles. Les
/// coordonnées de tuile sont fractionnaires : la partie entière donne la tuile,
/// la partie décimale la position dedans.
double lonToTileX(double lon, double zoom) => (lon + 180) / 360 * math.pow(2, zoom);

double latToTileY(double lat, double zoom) {
  final clamped = lat.clamp(-85.05112878, 85.05112878);
  final radians = clamped * math.pi / 180;
  final y = (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) / 2;
  return y * math.pow(2, zoom);
}

double tileXToLon(double x, double zoom) => x / math.pow(2, zoom) * 360 - 180;

double tileYToLat(double y, double zoom) {
  final n = math.pi - 2 * math.pi * y / math.pow(2, zoom);
  return 180 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2);
}

/// Mètres par pixel de tuile (256 px) à cette latitude et à ce zoom.
double metersPerPixel(double lat, double zoom) =>
    156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
