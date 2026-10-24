import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:cortege/mesh/proximity.dart';
import 'package:cortege/ui/beacon_screens.dart';
import 'package:cortege/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_location.dart';
import 'support/fake_transport.dart';
import 'support/rig.dart';

/// « Chaud / froid » par le signal Bluetooth d'une balise, et le clignotement
/// pour se faire repérer à vue.
void main() {
  group('ProximityTracker', () {
    final t0 = DateTime.utc(2026, 10, 20, 12);
    DateTime at(double seconds) => t0.add(Duration(milliseconds: (seconds * 1000).round()));

    test('les niveaux suivent la force du signal', () {
      expect(ProximityTracker.levelOf(-45), ProximityLevel.veryClose);
      expect(ProximityTracker.levelOf(-64), ProximityLevel.veryClose);
      expect(ProximityTracker.levelOf(-70), ProximityLevel.close);
      expect(ProximityTracker.levelOf(-80), ProximityLevel.near);
      expect(ProximityTracker.levelOf(-90), ProximityLevel.far);
    });

    test('la jauge va de 0 à 1 sans dépasser', () {
      expect(ProximityTracker.fraction(-30), 1);
      expect(ProximityTracker.fraction(-120), 0);
      expect(ProximityTracker.fraction(-72.5.round()), closeTo(0.5, 0.06));
    });

    test('la force est le plus fort de chaque seconde, médiane des dernières secondes', () {
      final tracker = ProximityTracker()
        ..add(at(0), -90)
        ..add(at(4), -60)
        ..add(at(5), -64);
      expect(tracker.current(at(5.5)), -62);
    });

    test('sans mesure depuis huit secondes, il n\'y a plus de signal', () {
      final tracker = ProximityTracker()..add(at(0), -60);
      expect(tracker.current(at(2)), -60);
      expect(tracker.current(at(9)), isNull);
      expect(ProximityTracker().current(at(0)), isNull);
    });

    test('la tendance compare le niveau lissé de maintenant à celui d\'il y a quatre secondes', () {
      ProximityTracker walk(List<int> early, List<int> late) {
        final tracker = ProximityTracker();
        for (var i = 0; i < early.length; i++) {
          tracker.add(at(i * 0.8), early[i]);
        }
        for (var i = 0; i < late.length; i++) {
          tracker.add(at(3.2 + i * 0.8), late[i]);
        }
        return tracker;
      }

      expect(
        walk([-76, -74, -75], [-62, -60, -61]).trend(at(6.2)),
        ProximityTrend.closer,
      );
      expect(
        walk([-58, -60, -59], [-72, -74, -73]).trend(at(6.2)),
        ProximityTrend.farther,
      );
      expect(
        walk([-66, -68, -67], [-66, -67, -68]).trend(at(6.2)),
        ProximityTrend.steady,
      );
    });

    test('la médiane ignore une mesure aberrante', () {
      final tracker = ProximityTracker()
        ..add(at(0), -64)
        ..add(at(0.5), -63)
        ..add(at(1), -95) // un parasite
        ..add(at(1.5), -65)
        ..add(at(2), -64);
      expect(tracker.current(at(2.2)), -64);
    });

    test('le meilleur signal est conservé quand on s\'éloigne', () {
      final tracker = ProximityTracker();
      expect(tracker.best, isNull);
      tracker
        ..add(at(0), -80)
        ..add(at(2), -70)
        ..add(at(3.5), -58)
        ..add(at(4), -58)
        ..add(at(4.5), -58)
        ..add(at(8), -75)
        ..add(at(10), -78);
      expect(tracker.best, -58);
      expect(tracker.current(at(10.5)), lessThan(-70));
    });

    test('une variation de quelques dB n\'est pas une tendance', () {
      final tracker = ProximityTracker();
      for (var i = 0; i < 3; i++) {
        tracker.add(at(i * 0.8), -66);
      }
      for (var i = 0; i < 3; i++) {
        tracker.add(at(3.2 + i * 0.8), -69);
      }
      expect(tracker.trend(at(6.2)), ProximityTrend.steady);
    });

    test('une seule fenêtre de mesures ne suffit pas pour une tendance', () {
      final tracker = ProximityTracker()
        ..add(at(0), -60)
        ..add(at(1), -61);
      expect(tracker.trend(at(2)), isNull);
    });
  });

  group('balise d\'une alerte', () {
    late VaultCrypto vaultCrypto;
    late FakeAir air;
    late DateTime clock;
    late RigFactory rigs;
    const here = GeoPoint(48.857, 2.351, 10);

    setUpAll(() async {
      vaultCrypto = await VaultCrypto.create();
    });

    setUp(() {
      air = FakeAir();
      clock = DateTime.utc(2026, 10, 20, 12);
      rigs = RigFactory(vaultCrypto, air, () => clock);
    });

    tearDown(() => rigs.close());

    Future<({Rig medic, Rig reporter, SentAlert sent, MedicAlert received})> scene() async {
      final medic = await rigs.create('Mel', at: here);
      final reporter = await rigs.create('Remi', at: here);
      await medic.mesh.medic.createChannel();
      final invite = await medic.mesh.createGroup('Place');
      await reporter.mesh.joinGroup(invite);
      final sent = await reporter.mesh.medic.report(AlertKind.injury);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return (
        medic: medic,
        reporter: reporter,
        sent: sent,
        received: medic.mesh.medic.alertsForMedic.single,
      );
    }

    test('la personne et le medic dérivent la même balise de cinq octets', () async {
      final s = await scene();

      await s.reporter.mesh.medic.startBeacon(s.sent.id);

      final announced = s.reporter.transport.beacon!;
      expect(announced, hasLength(5));
      expect(announced, s.medic.mesh.medic.beaconIdFor(s.received.replyPublicKey));
      expect(s.reporter.mesh.medic.beaconOn, isTrue);
    });

    test('le medic n\'entend que la balise de son alerte', () async {
      final s = await scene();
      await s.reporter.mesh.medic.startBeacon(s.sent.id);
      final mine = s.reporter.transport.beacon!;
      final heard = <int>[];
      final subscription = s.medic.mesh.medic.proximityTo(s.received).listen(heard.add);

      s.medic.transport.hear(Uint8List.fromList([1, 2, 3, 4, 5]), -40);
      s.medic.transport.hear(mine, -63);
      s.medic.transport.hear(mine, -58);

      expect(heard, [-63, -58]);
      await subscription.cancel();
    });

    test("si Android refuse la balise, on ne prétend pas émettre", () async {
      final s = await scene();
      s.reporter.transport.refuseBeacon = true;

      await s.reporter.mesh.medic.startBeacon(s.sent.id);

      expect(s.reporter.mesh.medic.beaconOn, isFalse);
      expect(s.reporter.transport.beacon, isNull);
    });

    test("deux alertes n'ont pas la même balise", () async {
      final s = await scene();
      clock = clock.add(const Duration(seconds: 20));
      final second = await s.reporter.mesh.medic.report(AlertKind.gas);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await s.reporter.mesh.medic.startBeacon(s.sent.id);
      final first = List<int>.of(s.reporter.transport.beacon!);
      await s.reporter.mesh.medic.startBeacon(second.id);

      expect(s.reporter.transport.beacon, isNot(first));
    });

    test('arrêter la balise, retirer l\'alerte ou tout oublier la coupe', () async {
      final s = await scene();

      await s.reporter.mesh.medic.startBeacon(s.sent.id);
      await s.reporter.mesh.medic.stopBeacon();
      expect(s.reporter.transport.beacon, isNull);
      expect(s.reporter.mesh.medic.beaconOn, isFalse);

      await s.reporter.mesh.medic.startBeacon(s.sent.id);
      s.reporter.mesh.medic.cancel(s.sent.id);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(s.reporter.transport.beacon, isNull);

      await s.reporter.mesh.medic.startBeacon('inconnue');
      expect(s.reporter.mesh.medic.beaconOn, isFalse, reason: 'pas d\'alerte, pas de balise');
    });
  });

  group('écrans', () {
    late VaultCrypto vaultCrypto;
    late FakeAir air;
    late DateTime clock;
    late RigFactory rigs;
    const here = GeoPoint(48.857, 2.351, 10);

    setUpAll(() async {
      vaultCrypto = await VaultCrypto.create();
    });

    setUp(() {
      air = FakeAir();
      clock = DateTime.utc(2026, 10, 20, 12);
      rigs = RigFactory(vaultCrypto, air, () => clock);
    });

    Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

    void bigScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<Rig> rig(WidgetTester tester, String name) async {
      final made = (await tester.runAsync(() => rigs.create(name, at: here)))!;
      addTearDown(() async => rigs.close());
      return made;
    }

    testWidgets('chaud / froid : aucun signal, puis tout près, puis plus rien', (tester) async {
      bigScreen(tester);
      final medic = await rig(tester, 'Mel');
      final reporter = await rig(tester, 'Remi');
      late MedicAlert received;
      await tester.runAsync(() async {
        await medic.mesh.medic.createChannel();
        final invite = await medic.mesh.createGroup('Place');
        await reporter.mesh.joinGroup(invite);
        await reporter.mesh.medic.report(AlertKind.injury);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        received = medic.mesh.medic.alertsForMedic.single;
      });
      final beacon = medic.mesh.medic.beaconIdFor(received.replyPublicKey);

      await tester.pumpWidget(app(FindScreen(mesh: medic.mesh, alert: received)));
      expect(find.text('Aucun signal'), findsOneWidget);

      medic.transport.hear(beacon, -50);
      await tester.pump();
      expect(find.text('Tout près'), findsOneWidget);
      expect(find.textContaining('-50 dBm'), findsWidgets);
      expect(find.textContaining('Cherche le point où la jauge est la plus haute'), findsOneWidget);
      expect(find.textContaining('faire clignoter'), findsOneWidget);

      // Plus rien pendant dix secondes : le signal est perdu.
      clock = clock.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Aucun signal'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      reporter.mesh.stop();
      medic.mesh.stop();
    });

    testWidgets('Aider à me trouver : la balise vit tant que l\'écran est ouvert', (tester) async {
      bigScreen(tester);
      final medic = await rig(tester, 'Mel');
      final reporter = await rig(tester, 'Remi');
      late SentAlert sent;
      await tester.runAsync(() async {
        await medic.mesh.medic.createChannel();
        final invite = await medic.mesh.createGroup('Place');
        await reporter.mesh.joinGroup(invite);
        sent = await reporter.mesh.medic.report(AlertKind.faint);
      });

      await tester.pumpWidget(app(ImHereScreen(mesh: reporter.mesh, alertId: sent.id)));
      await tester.pump();
      expect(reporter.transport.beacon, isNotNull);
      expect(find.text('Signal Bluetooth actif'), findsOneWidget);
      expect(find.text('Faire clignoter l\'écran et la lampe'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(reporter.transport.beacon, isNull, reason: 'le signal s\'arrête avec l\'écran');

      reporter.mesh.stop();
      medic.mesh.stop();
    });

    testWidgets('le clignotement alterne écran et lampe, et éteint la lampe en partant', (tester) async {
      bigScreen(tester);
      final torch = FakeTorch();

      await tester.pumpWidget(app(FlashScreen(torch: torch)));
      expect(torch.calls, [true]);
      expect(find.text('Je suis ici'), findsOneWidget);
      expect(find.text('Arrêter'), findsOneWidget);

      await tester.pump(FlashScreen.half);
      expect(torch.calls, [true, false]);
      await tester.pump(FlashScreen.half);
      expect(torch.calls, [true, false, true]);

      await tester.pumpWidget(const SizedBox());
      expect(torch.isOn, isFalse, reason: 'la lampe ne reste jamais allumée');
    });
  });
}
