import 'dart:math' as math;

/// Un point sur la Terre. Jamais écrit sur disque : une position ne vit qu'en
/// mémoire, le temps d'une alerte.
class GeoPoint {
  const GeoPoint(this.lat, this.lon, [this.accuracyMeters = 0]);

  final double lat;
  final double lon;

  /// Précision annoncée par le téléphone, en mètres. 0 : inconnue.
  final double accuracyMeters;

  @override
  String toString() => 'GeoPoint(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})';
}

/// D'où viennent les positions. Sur Android : le système, sans service Google
/// de notre côté. Les tests en branchent une fausse.
abstract class LocationProvider {
  /// Position actuelle, ou null si elle n'est pas disponible (permission
  /// refusée, pas de signal).
  ///
  /// Avec [accurate], on attend le GPS (jusqu'à quelques secondes) plutôt que de
  /// prendre la première position venue, même floue : pour guider quelqu'un ou
  /// donner sa position précise. Sans, la première position reçue suffit, ce qui
  /// va plus vite pour une alerte.
  Future<GeoPoint?> current({bool accurate = false});

  /// Les positions successives, tant qu'on écoute (une par seconde environ avec
  /// le GPS). Sert à suivre un déplacement à l'écran ; rien n'est gardé, et
  /// quand on cesse d'écouter, le GPS s'arrête. L'autorisation doit avoir été
  /// demandée avant (par [current]).
  Stream<GeoPoint> updates();
}

class NoLocation implements LocationProvider {
  const NoLocation();

  @override
  Future<GeoPoint?> current({bool accurate = false}) async => null;

  @override
  Stream<GeoPoint> updates() => const Stream.empty();
}

/// Grille de 0,002 degré (environ 200 mètres) : la position envoyée à tous les
/// medics est volontairement floue. La position précise ne part qu'à celui qui
/// répond, et seulement si la personne le décide.
const coarseStepDegrees = 0.002;

GeoPoint coarsened(GeoPoint point) => GeoPoint(
      (point.lat / coarseStepDegrees).round() * coarseStepDegrees,
      (point.lon / coarseStepDegrees).round() * coarseStepDegrees,
      200,
    );

/// Distance en mètres entre deux points (formule de haversine).
double distanceMeters(GeoPoint a, GeoPoint b) {
  const earth = 6371000.0;
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earth * math.asin(math.sqrt(h));
}

/// Cap de [from] vers [to], en degrés depuis le nord, dans le sens des aiguilles
/// d'une montre.
double bearingDegrees(GeoPoint from, GeoPoint to) {
  final dLon = _rad(to.lon - from.lon);
  final y = math.sin(dLon) * math.cos(_rad(to.lat));
  final x = math.cos(_rad(from.lat)) * math.sin(_rad(to.lat)) -
      math.sin(_rad(from.lat)) * math.cos(_rad(to.lat)) * math.cos(dLon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Vrai quand la distance entre deux positions est plus petite que leur
/// incertitude : le cap de l'une à l'autre n'a alors plus de sens (deux
/// téléphones côte à côte donnent n'importe quel cap, et la flèche tournerait
/// avec le nord au lieu de viser quelque chose). Une position approximative est
/// connue à environ 150 m près ; une position précise à la précision que le GPS
/// annonce, majorée de moitié.
bool isWithinMargin(GeoPoint me, GeoPoint target, {required bool precise}) {
  final uncertainty = precise
      ? (me.accuracyMeters + target.accuracyMeters) * 1.5
      : me.accuracyMeters + 150;
  return distanceMeters(me, target) < math.max(30, uncertainty);
}

const _compass = [
  'nord',
  'nord-est',
  'est',
  'sud-est',
  'sud',
  'sud-ouest',
  'ouest',
  'nord-ouest',
];

String compassWord(double degrees) => _compass[((degrees + 22.5) % 360 ~/ 45) % 8];

/// « à 350 m vers le nord-est », arrondi pour ne pas promettre plus de précision
/// que la position n'en a.
String describeOffset(GeoPoint from, GeoPoint to) {
  final meters = distanceMeters(from, to);
  final word = compassWord(bearingDegrees(from, to));
  if (meters < 60) return 'tout près';
  if (meters < 1000) return 'à ${(meters / 10).round() * 10} m vers le $word';
  return 'à ${(meters / 1000).toStringAsFixed(1)} km vers le $word';
}

double _rad(double degrees) => degrees * math.pi / 180;
