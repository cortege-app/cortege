import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'geo.dart';

/// D'où vient le cap du téléphone. Sur Android : les capteurs du système, sans
/// bibliothèque tierce. Les tests en branchent un faux.
abstract class CompassProvider {
  /// Cap du téléphone en degrés par rapport au nord géographique (0 : nord,
  /// 90 : est), en continu. [at] sert à corriger l'écart entre nord magnétique
  /// et nord géographique. Le flux se termine ou lève une erreur si le
  /// téléphone n'a pas de capteur.
  Stream<double> headings(GeoPoint at);
}

class NoCompass implements CompassProvider {
  const NoCompass();

  @override
  Stream<double> headings(GeoPoint at) => const Stream.empty();
}

class PlatformCompass implements CompassProvider {
  const PlatformCompass();

  static const _channel = EventChannel('org.cortege.app/compass');

  /// Android envoie la matrice de rotation du téléphone (9 nombres) suivie de la
  /// déclinaison magnétique du lieu : le calcul du cap se fait ici, où il est
  /// testé.
  @override
  Stream<double> headings(GeoPoint at) =>
      _channel.receiveBroadcastStream({'lat': at.lat, 'lon': at.lon}).map((value) {
        final numbers = [for (final n in value as List<Object?>) (n! as num).toDouble()];
        return headingFromRotation(numbers.sublist(0, 9), declination: numbers[9]);
      });
}

/// Cap de l'avant du téléphone, en degrés depuis le nord géographique.
///
/// [r] est la matrice de rotation d'Android (appareil vers repère terrestre
/// est, nord, haut), ligne par ligne. L'« avant » dépend de la façon de tenir le
/// téléphone :
/// - à plat, c'est le haut de l'écran ;
/// - debout (en portrait comme en paysage), c'est l'arrière du téléphone, comme
///   un appareil photo.
/// Entre les deux, on mélange les deux directions selon l'inclinaison. Chacune
/// est ramenée à une longueur de 1 avant le mélange : quand le téléphone est
/// presque à plat, la direction de l'arrière n'a plus de sens (elle pointe vers
/// le bas) mais son poids est presque nul. Le cap ne saute donc jamais, et il
/// n'y a pas de seuil où il pourrait se retourner.
double headingFromRotation(List<double> r, {double declination = 0}) {
  // Haut de l'écran (axe Y) et arrière du téléphone (axe -Z), projetés sur le sol.
  final topEast = r[1], topNorth = r[4];
  final backEast = -r[2], backNorth = -r[5];
  // 1 à plat (moins de 26 degrés d'inclinaison), 0 debout (plus de 60 degrés),
  // progressif entre les deux. Un téléphone légèrement penché de côté reste donc
  // lu par le haut de l'écran, sans dérive.
  final flat = ((r[8].abs() - 0.5) / 0.4).clamp(0.0, 1.0);

  var east = 0.0;
  var north = 0.0;
  final topLength = math.sqrt(topEast * topEast + topNorth * topNorth);
  if (topLength > 1e-6) {
    east += flat * topEast / topLength;
    north += flat * topNorth / topLength;
  }
  final backLength = math.sqrt(backEast * backEast + backNorth * backNorth);
  if (backLength > 1e-6) {
    east += (1 - flat) * backEast / backLength;
    north += (1 - flat) * backNorth / backLength;
  }
  final degrees = math.atan2(east, north) * 180 / math.pi + declination;
  return (degrees % 360 + 360) % 360;
}

/// De combien tourner pour faire face au point : de 0 (droit devant) à 360,
/// dans le sens des aiguilles d'une montre.
double relativeAngle(double bearing, double heading) => (bearing - heading + 720) % 360;

/// Lisse un cap qui tremble sans casser au passage de 359 à 1 degré.
double smoothAngle(double? previous, double next, {double factor = 0.3}) {
  if (previous == null) return next;
  final delta = ((next - previous + 540) % 360) - 180;
  return (previous + delta * factor + 360) % 360;
}

/// « Droit devant », « Tourne-toi de 40° vers la droite ».
String turnInstruction(double relative) {
  final toRight = relative <= 180;
  final degrees = (toRight ? relative : 360 - relative).round();
  if (degrees < 10) return 'Droit devant';
  return 'Tourne-toi de $degrees° vers la ${toRight ? 'droite' : 'gauche'}';
}
