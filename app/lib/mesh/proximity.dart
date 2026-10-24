import 'dart:typed_data';

/// Une mesure du signal d'une balise : [rssi] est la force du signal reçu, en
/// dBm (plus c'est proche de zéro, plus l'émetteur est près : environ -65 pour
/// deux téléphones collés, -75 à quelques mètres, -90 au bout de la portée).
class ProximityReading {
  const ProximityReading(this.beacon, this.rssi);

  /// Identifiant de la balise (5 octets), dérivé de la clé de réponse d'une
  /// alerte : seuls ceux qui ont reçu l'alerte savent le reconnaître.
  final Uint8List beacon;
  final int rssi;
}

enum ProximityLevel { veryClose, close, near, far }

enum ProximityTrend { closer, steady, farther }

/// Lisse les mesures de signal et en tire un niveau (tout près, près, dans les
/// parages, loin), une tendance (on se rapproche ou on s'éloigne) et le meilleur
/// signal vu jusque-là.
///
/// Ce qu'on a mesuré sur deux téléphones (enregistrement de 15 minutes) : à
/// distance fixe, le signal reste plat quelques secondes puis saute de 5 à 7 dB,
/// parce que la façon de tenir le téléphone ou une main devant l'antenne
/// compte autant que la distance. Et les trois canaux d'annonce Bluetooth
/// arrivent à des forces différentes. On garde donc le plus fort de chaque
/// seconde (le moins touché par les creux) et la médiane des cinq dernières
/// secondes.
class ProximityTracker {
  ProximityTracker({
    this.span = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 8),
    this.trendGap = const Duration(seconds: 4),
    this.trendThreshold = 4,
  });

  /// Durée sur laquelle on lisse (cinq tranches d'une seconde).
  final Duration span;

  /// Sans mesure depuis ce temps, on n'a plus de signal.
  final Duration staleAfter;

  /// La tendance compare le niveau lissé de maintenant à celui d'il y a ce temps.
  final Duration trendGap;

  /// Écart (en dB) à partir duquel on parle de rapprochement ou d'éloignement.
  final int trendThreshold;

  final _samples = <(DateTime, int)>[];
  int? _best;

  /// Le plus fort signal lissé depuis le début : à courte distance, c'est le
  /// repère pour trouver le point où l'on est le plus près.
  int? get best => _best;

  void add(DateTime at, int rssi) {
    _samples.add((at, rssi));
    _samples.removeWhere((s) => at.difference(s.$1) > span + trendGap + const Duration(seconds: 1));
    final smoothed = _smoothed(at);
    if (smoothed != null) {
      final value = smoothed.round();
      if (_best == null || value > _best!) _best = value;
    }
  }

  /// Niveau lissé à l'instant [at] : médiane des maxima de chacune des dernières
  /// secondes.
  double? _smoothed(DateTime at) {
    final maxima = <int>[];
    for (var i = 0; i < span.inSeconds; i++) {
      final to = at.subtract(Duration(seconds: i));
      final from = to.subtract(const Duration(seconds: 1));
      int? top;
      for (final s in _samples) {
        if (s.$1.isAfter(from) && !s.$1.isAfter(to) && (top == null || s.$2 > top)) top = s.$2;
      }
      if (top != null) maxima.add(top);
    }
    if (maxima.isEmpty) return null;
    maxima.sort();
    final middle = maxima.length ~/ 2;
    return maxima.length.isOdd ? maxima[middle].toDouble() : (maxima[middle - 1] + maxima[middle]) / 2;
  }

  /// Force du signal ces dernières secondes, ou null si on n'entend plus rien.
  int? current(DateTime now) {
    if (_samples.isEmpty || now.difference(_samples.last.$1) > staleAfter) return null;
    return _smoothed(now)?.round() ?? _samples.last.$2;
  }

  /// Null tant qu'on n'a pas de quoi comparer deux instants.
  ProximityTrend? trend(DateTime now) {
    final latest = _smoothed(now);
    final before = _smoothed(now.subtract(trendGap));
    if (latest == null || before == null) return null;
    final delta = latest - before;
    if (delta >= trendThreshold) return ProximityTrend.closer;
    if (delta <= -trendThreshold) return ProximityTrend.farther;
    return ProximityTrend.steady;
  }

  static ProximityLevel levelOf(int rssi) {
    // Mesuré sur deux téléphones collés : environ -65 dBm. L'annonce Bluetooth
    // d'Android émet à puissance moyenne, bien moins fort qu'un téléphone qui
    // s'annonce à pleine puissance.
    if (rssi >= -64) return ProximityLevel.veryClose;
    if (rssi >= -74) return ProximityLevel.close;
    if (rssi >= -84) return ProximityLevel.near;
    return ProximityLevel.far;
  }

  /// 0 (portée limite) à 1 (collé), pour la jauge.
  static double fraction(int rssi) => ((rssi + 95) / 45).clamp(0.0, 1.0);
}
