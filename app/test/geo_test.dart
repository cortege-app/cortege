import 'package:cortege/mesh/geo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const republique = GeoPoint(48.8675, 2.3637);
  const bastille = GeoPoint(48.8532, 2.3692);

  test('distance connue : République à Bastille, environ 1,6 km', () {
    final meters = distanceMeters(republique, bastille);
    expect(meters, inInclusiveRange(1500, 1700));
  });

  test('distance de soi à soi : zéro', () {
    expect(distanceMeters(republique, republique), closeTo(0, 0.001));
  });

  test('le sens : Bastille est au sud de République', () {
    final bearing = bearingDegrees(republique, bastille);
    expect(compassWord(bearing), anyOf('sud', 'sud-est'));
  });

  test('les huit points cardinaux', () {
    expect(compassWord(0), 'nord');
    expect(compassWord(44), 'nord-est');
    expect(compassWord(90), 'est');
    expect(compassWord(135), 'sud-est');
    expect(compassWord(180), 'sud');
    expect(compassWord(225), 'sud-ouest');
    expect(compassWord(270), 'ouest');
    expect(compassWord(315), 'nord-ouest');
    expect(compassWord(359), 'nord');
  });

  test('description : tout près, mètres, kilomètres', () {
    expect(describeOffset(republique, const GeoPoint(48.86752, 2.36371)), 'tout près');
    expect(describeOffset(republique, const GeoPoint(48.8700, 2.3637)), contains('m vers le nord'));
    expect(describeOffset(republique, bastille), contains('km vers le'));
  });

  test('la position floue tombe sur une grille de 0,002 degré', () {
    final coarse = coarsened(const GeoPoint(48.857133, 2.351357, 5));
    expect(coarse.lat, closeTo(48.858, 1e-9));
    expect(coarse.lon, closeTo(2.352, 1e-9));
    expect(coarse.accuracyMeters, 200);
  });

  test('deux points voisins tombent dans la même case', () {
    final a = coarsened(const GeoPoint(48.8571, 2.3513));
    final b = coarsened(const GeoPoint(48.8574, 2.3516));
    expect(a.lat, b.lat);
    expect(a.lon, b.lon);
  });

  test('la position floue est à moins de 160 mètres de la vraie', () {
    for (final point in [republique, bastille, const GeoPoint(45.7640, 4.8357)]) {
      expect(distanceMeters(point, coarsened(point)), lessThan(220));
    }
  });

  group('marge d\'incertitude', () {
    const here = GeoPoint(48.8600, 2.3500, 10);

    test('deux téléphones côte à côte : pas de cap', () {
      const near = GeoPoint(48.86003, 2.35003, 8);
      expect(isWithinMargin(here, near, precise: true), isTrue);
    });

    test('loin, la position précise donne un cap', () {
      const far = GeoPoint(48.8630, 2.3500, 8);
      expect(isWithinMargin(here, far, precise: true), isFalse);
    });

    test('une position approximative n\'est connue qu\'à 150 m près', () {
      const zone = GeoPoint(48.8610, 2.3500, 200); // environ 110 m
      expect(isWithinMargin(here, zone, precise: false), isTrue);
      const beyond = GeoPoint(48.8660, 2.3500, 200); // environ 670 m
      expect(isWithinMargin(here, beyond, precise: false), isFalse);
    });
  });
}
