import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:cortege/ui/buddy_screens.dart';
import 'package:cortege/ui/compass_view.dart';
import 'package:cortege/ui/medic_screens.dart';
import 'package:cortege/ui/report_screen.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_location.dart';
import 'support/fake_transport.dart';
import 'support/rig.dart';

/// Les écrans du binôme, du signalement et des medics, sur de vrais maillages
/// reliés par une fausse radio. Tout ce qui touche au disque ou à la radio se
/// fait dans `runAsync` : dans `testWidgets`, le temps est simulé.
void main() {
  late VaultCrypto vaultCrypto;
  late FakeAir air;
  late DateTime clock;
  late RigFactory rigs;

  const reporterAt = GeoPoint(48.857133, 2.351357, 12);
  const medicAt = GeoPoint(48.8602, 2.3470, 8);

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
    rigs = RigFactory(vaultCrypto, air, () => clock);
  });

  Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<Rig> rig(WidgetTester tester, String name, {GeoPoint? at}) async {
    final made = (await tester.runAsync(() => rigs.create(name, at: at)))!;
    addTearDown(() async {
      await rigs.close();
    });
    return made;
  }

  Future<void> pair(WidgetTester tester, Rig a, Rig b) async {
    await tester.runAsync(() async {
      final invite = await a.mesh.buddies.create();
      final joined = await b.mesh.buddies.accept(BuddyInvite.decode(invite.encode()));
      final back = b.mesh.buddies.inviteFor(joined.buddyId);
      await a.mesh.buddies.accept(BuddyInvite.decode(back.encode()));
    });
  }

  group('binôme', () {
    testWidgets('la liste montre le proche et le détail laisse dire qu\'on va bien', (tester) async {
      bigScreen(tester);
      final alex = await rig(tester, 'Alex');
      final blan = await rig(tester, 'Blan');
      await pair(tester, alex, blan);

      await tester.pumpWidget(app(BuddyScreen(mesh: alex.mesh)));
      expect(find.text('Avec Blan'), findsOneWidget);
      expect(find.text('Créer un binôme'), findsOneWidget);
      expect(find.textContaining('Plus de nouvelles'), findsNothing);

      await tester.tap(find.text('Avec Blan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Blan ('), findsOneWidget);

      await tester.tap(find.text('Je vais bien'));
      await tester.pump();
      expect(find.textContaining('Tes proches savent que tu vas bien'), findsOneWidget);
    });

    testWidgets('un proche qui se tait fait apparaître le bandeau rouge, puis disparaître', (tester) async {
      bigScreen(tester);
      final alex = await rig(tester, 'Alex');
      final blan = await rig(tester, 'Blan');
      await pair(tester, alex, blan);

      await tester.pumpWidget(app(BuddyScreen(mesh: alex.mesh)));
      expect(find.textContaining('Plus de nouvelles de Blan'), findsNothing);

      clock = clock.add(const Duration(minutes: 20));
      alex.mesh.changed();
      await tester.pump();
      expect(find.textContaining('Plus de nouvelles de Blan'), findsWidgets);

      await tester.runAsync(() => blan.mesh.buddies.checkIn(blan.mesh.buddies.infos.single.id));
      await tester.pump();
      expect(find.textContaining('Plus de nouvelles de Blan'), findsNothing);
    });

    testWidgets('le code de binôme s\'affiche pour être scanné', (tester) async {
      bigScreen(tester);
      final alex = await rig(tester, 'Alex');
      await tester.runAsync(() => alex.mesh.buddies.create());
      final id = alex.mesh.buddies.infos.single.id;

      await tester.pumpWidget(
        app(BuddyCodeScreen(mesh: alex.mesh, buddyId: id, instruction: 'Fais scanner ce code.')),
      );
      expect(find.text('Fais scanner ce code.'), findsOneWidget);
      expect(find.text('Terminé'), findsOneWidget);
    });
  });

  group('signaler un blessé', () {
    testWidgets('sans canal des medics, l\'écran dit quoi faire', (tester) async {
      bigScreen(tester);
      final alex = await rig(tester, 'Alex');

      await tester.pumpWidget(app(ReportScreen(mesh: alex.mesh)));
      expect(find.textContaining('ne connaît pas le canal des medics'), findsOneWidget);
      expect(find.textContaining('15 ou 112'), findsOneWidget);
      expect(find.byType(HoldToConfirmButton), findsNothing);
    });

    testWidgets('avec le canal, trois boutons à maintenir, puis l\'alerte et sa suite', (tester) async {
      bigScreen(tester);
      final mel = await rig(tester, 'Mel', at: medicAt);
      final remi = await rig(tester, 'Rémi', at: reporterAt);
      await tester.runAsync(() async {
        await mel.mesh.medic.createChannel();
        final invite = await mel.mesh.createGroup('Place');
        await remi.mesh.joinGroup(invite);
      });
      expect(remi.mesh.medic.hasChannel, isTrue);

      await tester.pumpWidget(app(ReportScreen(mesh: remi.mesh)));
      expect(find.byType(HoldToConfirmButton), findsNWidgets(3));
      expect(find.text('Blessure'), findsOneWidget);
      expect(find.text('Malaise'), findsOneWidget);
      expect(find.text('Gaz'), findsOneWidget);

      // Un simple appui ne fait rien.
      await tester.tap(find.text('Blessure'));
      await tester.pump();
      expect(find.textContaining('signalé'), findsNothing);

      tester.widget<HoldToConfirmButton>(find.byType(HoldToConfirmButton).first).onConfirmed();
      await tester.pump();
      await tester.pump();
      expect(find.text('Blessure signalé'), findsOneWidget);
      expect(find.textContaining('Aucun medic'), findsOneWidget);

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final alert = mel.mesh.medic.alertsForMedic.single;
        await mel.mesh.medic.respond(alert.id, medicName: 'Mel');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('Mel arrive'), findsOneWidget);
      expect(find.text('Aider à me trouver'), findsOneWidget);
      expect(find.textContaining('Envoyer ma position précise à Mel'), findsOneWidget);

      // Les renvois en cours reposent sur des minuteries : on arrête tout.
      remi.mesh.stop();
      mel.mesh.stop();
    });
  });

  group('medic', () {
    testWidgets('sans rôle, on peut créer le canal ou rejoindre celui d\'un autre', (tester) async {
      bigScreen(tester);
      final alex = await rig(tester, 'Alex');

      await tester.pumpWidget(app(MedicScreen(mesh: alex.mesh)));
      expect(find.text('Créer le canal des medics'), findsOneWidget);
      expect(find.text('Rejoindre le canal d\'un medic'), findsOneWidget);
    });

    testWidgets('sur place, la flèche reste mais elle est grisée et prévient', (tester) async {
      bigScreen(tester);
      final mel = await rig(tester, 'Mel', at: medicAt);
      final remi = await rig(tester, 'Remi', at: reporterAt);
      await tester.runAsync(() async {
        await mel.mesh.medic.createChannel();
        final invite = await mel.mesh.createGroup('Place');
        await remi.mesh.joinGroup(invite);
        await remi.mesh.medic.report(AlertKind.injury);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      final alert = mel.mesh.medic.alertsForMedic.single;
      // Le medic se trouve dans la zone de l'alerte.
      mel.location.point = alert.coarse;
      final compass = FakeCompass();
      mel.mesh.medic.compass = compass;

      await tester.pumpWidget(app(AlertDetailScreen(mesh: mel.mesh, alertId: alert.id)));
      await tester.tap(find.text('Voir la direction depuis ici'));
      await tester.pump();
      await tester.pump();
      compass.turn(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('Tu es dans la zone'), findsOneWidget);
      // Guider quelqu'un demande le vrai GPS ; une alerte, elle, part avec la
      // première position venue.
      expect(mel.location.lastAccurate, isTrue);
      expect(remi.location.lastAccurate, isFalse);
      expect(find.byType(CompassView), findsOneWidget);
      expect(tester.widget<CompassView>(find.byType(CompassView)).indicative, isTrue);
      expect(find.textContaining('Indicatif'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      remi.mesh.stop();
      mel.mesh.stop();
    });

    testWidgets('une alerte reçue s\'annonce, se lit et reçoit une réponse', (tester) async {
      bigScreen(tester);
      final mel = await rig(tester, 'Mel', at: medicAt);
      final remi = await rig(tester, 'Rémi', at: reporterAt);
      await tester.runAsync(() async {
        await mel.mesh.medic.createChannel();
        final invite = await mel.mesh.createGroup('Place');
        await remi.mesh.joinGroup(invite);
        await remi.mesh.medic.report(AlertKind.injury);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      final alert = mel.mesh.medic.alertsForMedic.single;

      await tester.pumpWidget(
        app(Scaffold(body: MedicAlertBanner(mesh: mel.mesh, onTap: () {}))),
      );
      expect(find.text('Un blessé attend un medic'), findsOneWidget);

      await tester.pumpWidget(app(MedicScreen(mesh: mel.mesh)));
      expect(find.text('Réception des alertes'), findsOneWidget);
      expect(find.textContaining('Blessure'), findsOneWidget);

      final compass = FakeCompass();
      mel.mesh.medic.compass = compass;
      await tester.pumpWidget(app(AlertDetailScreen(mesh: mel.mesh, alertId: alert.id)));
      expect(find.textContaining('Position approximative'), findsOneWidget);
      expect(find.text('J\'arrive'), findsOneWidget);

      // La boussole guide vers la zone de l'alerte, depuis la position du medic.
      await tester.tap(find.text('Voir la direction depuis ici'));
      await tester.pump();
      await tester.pump();
      expect(compass.askedAt, isNotNull);
      expect(find.text('La boussole démarre...'), findsOneWidget);
      compass.turn(bearingDegrees(medicAt, alert.coarse!));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Droit devant'), findsOneWidget);
      expect(find.textContaining('200 m près'), findsOneWidget);

      await tester.tap(find.text('J\'arrive'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Tu as répondu'), findsOneWidget);
      expect(find.text('Chaud / froid (signal Bluetooth)'), findsOneWidget);
      expect(find.text('J\'arrive'), findsNothing);

      await tester.pumpWidget(
        app(Scaffold(body: MedicAlertBanner(mesh: mel.mesh, onTap: () {}))),
      );
      expect(find.text('Un blessé attend un medic'), findsNothing);

      remi.mesh.stop();
      mel.mesh.stop();
    });
  });
}
