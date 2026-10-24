import 'dart:math' as math;

import 'package:cortege/mesh/compass.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/ui/compass_view.dart';
import 'package:cortege/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_location.dart';

void main() {
  group('calculs d\'angle', () {
    test('l\'angle à tourner se compte dans le sens des aiguilles d\'une montre', () {
      expect(relativeAngle(90, 100), 350);
      expect(relativeAngle(10, 350), 20);
      expect(relativeAngle(45, 45), 0);
      expect(relativeAngle(0, 90), 270);
    });

    test('le lissage passe de 359 à 1 par le plus court chemin', () {
      final smoothed = smoothAngle(359, 1);
      expect(smoothed, closeTo(359.6, 0.01));
      expect(smoothAngle(null, 123), 123);
      expect(smoothAngle(10, 350), closeTo(4, 0.01));
    });

    test('la consigne dit de quel côté tourner', () {
      expect(turnInstruction(4), 'Droit devant');
      expect(turnInstruction(356), 'Droit devant');
      expect(turnInstruction(40), 'Tourne-toi de 40° vers la droite');
      expect(turnInstruction(320), 'Tourne-toi de 40° vers la gauche');
      expect(turnInstruction(180), 'Tourne-toi de 180° vers la droite');
    });
  });

  group('cap à partir de la matrice de rotation d\'Android', () {
    // Lignes : est, nord, haut. Colonnes : axes X, Y, Z du téléphone.
    const flatNorth = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1]; // à plat, haut de l'écran vers le nord
    const flatEast = <double>[0, 1, 0, -1, 0, 0, 0, 0, 1]; // à plat, haut de l'écran vers l'est
    const uprightNorth = <double>[1, 0, 0, 0, 0, -1, 0, 1, 0]; // debout, l'arrière regarde le nord
    const uprightEast = <double>[0, 0, -1, -1, 0, 0, 0, 1, 0]; // debout, l'arrière regarde l'est

    test('à plat, c\'est le haut de l\'écran', () {
      expect(headingFromRotation(flatNorth), closeTo(0, 0.001));
      expect(headingFromRotation(flatEast), closeTo(90, 0.001));
    });

    test('debout, c\'est l\'arrière du téléphone, sans retournement de 180 degrés', () {
      expect(headingFromRotation(uprightNorth), closeTo(0, 0.001));
      expect(headingFromRotation(uprightEast), closeTo(90, 0.001));
    });

    test('incliné entre les deux, le cap reste le même', () {
      for (final tilt in [10.0, 30.0, 45.0, 60.0, 80.0]) {
        final c = math.cos(tilt * math.pi / 180);
        final s = math.sin(tilt * math.pi / 180);
        // Téléphone tourné vers le nord, penché de `tilt` degrés par rapport au plat.
        final r = [1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c];
        expect(headingFromRotation(r), closeTo(0, 0.001), reason: 'inclinaison $tilt');
      }
    });

    test('en paysage, debout, c\'est l\'arrière du téléphone qui compte', () {
      // Téléphone tenu comme un appareil photo en paysage, l'arrière vers le nord :
      // le haut de l'écran pointe alors vers l'ouest, ce n'est pas la direction visée.
      const landscapeNorth = <double>[0, -1, 0, 0, 0, -1, 1, 0, 0];
      expect(headingFromRotation(landscapeNorth), closeTo(0, 0.001));
    });

    test('un cap incliné de côté ne dérive pas', () {
      // À plat avec un léger roulis : le haut de l'écran reste la référence.
      for (final roll in [5.0, 15.0, 25.0]) {
        final c = math.cos(roll * math.pi / 180);
        final s = math.sin(roll * math.pi / 180);
        final r = <double>[c, 0, s, 0, 1, 0, -s, 0, c];
        expect(headingFromRotation(r), closeTo(0, 0.001), reason: 'roulis $roll');
      }
    });

    test('la déclinaison magnétique s\'ajoute, et le cap reste entre 0 et 360', () {
      expect(headingFromRotation(flatNorth, declination: 2.5), closeTo(2.5, 0.001));
      expect(headingFromRotation(flatNorth, declination: -3), closeTo(357, 0.001));
    });
  });

  group('boussole à l\'écran', () {
    Widget app(Widget child) =>
        MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: child)));

    testWidgets('elle attend le premier cap, puis donne la consigne', (tester) async {
      final compass = FakeCompass();
      await tester.pumpWidget(
        app(CompassView(bearing: 90, headings: compass.headings(const GeoPoint(48.85, 2.35)))),
      );
      expect(find.text('La boussole démarre...'), findsOneWidget);

      compass.turn(90);
      await tester.pump();
      expect(find.text('Droit devant'), findsOneWidget);

      // Le téléphone tourne vers le nord : la cible est à 90 degrés à droite.
      for (var i = 0; i < 30; i++) {
        compass.turn(0);
        await tester.pump();
      }
      expect(find.text('Tourne-toi de 90° vers la droite'), findsOneWidget);
    });

    testWidgets('sans capteur, elle le dit', (tester) async {
      final compass = FakeCompass();
      await tester.pumpWidget(
        app(CompassView(bearing: 90, headings: compass.headings(const GeoPoint(48.85, 2.35)))),
      );

      compass.breakDown();
      await tester.pump();

      expect(find.textContaining('pas de boussole'), findsOneWidget);
    });
  });
}
