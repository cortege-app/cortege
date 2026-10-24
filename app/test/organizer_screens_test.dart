import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/map/map_view.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/event_file.dart';
import 'package:cortege/organizer/file_picker.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:cortege/ui/app.dart';
import 'package:cortege/ui/map_screens.dart';
import 'package:cortege/ui/organizer_screens.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

class _FakePicker implements FilePicker {
  /// Le fichier que choisira « Importer un événement ».
  File? next;

  /// Le fichier qu'une autre appli a ouvert avec Cortège.
  File? incoming;

  @override
  Future<PickedFile?> pick() async {
    final file = next;
    next = null;
    return file == null ? null : PickedFile(file, 'evenement.cortege');
  }

  @override
  Future<PickedFile?> takeIncoming() async {
    final file = incoming;
    incoming = null;
    return file == null ? null : PickedFile(file, 'evenement.cortege');
  }

  @override
  Future<void> clean({bool all = false}) async {}
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
  });

  Future<(AppController, _FakePicker, Directory)> open(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('cortege_org_ui');
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Un fichier encore tenu par le coffre : le dossier temporaire reste.
      }
    });
    final picker = _FakePicker();
    final controller = AppController(
      store: VaultStore(
        crypto: vaultCrypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      ),
      mapsDirectory: Directory('${dir.path}/maps'),
      filePicker: picker,
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.setUp(pin: '483920');
    });
    addTearDown(controller.dispose);
    return (controller, picker, dir);
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

  /// Une suite d'opérations de fichier se déroule dans le temps réel : on
  /// alterne attente réelle et images simulées jusqu'à ce que tout soit passé.
  Future<void> settle(WidgetTester tester, {Finder? until}) async {
    for (var i = 0; i < (until == null ? 10 : 80); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
      if (until != null && until.evaluate().isNotEmpty) return;
    }
  }

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  ({Uint8List publicKey, String Function({String by, String name, MapReference? map, DateTime? expires}) sign}) organizer() {
    final pair = crypto.newSigningKeyPair();
    return (
      publicKey: pair.publicKey,
      sign: ({by = 'Collectif', name = 'Marche d\'essai', map, expires}) => OrganizerPacket.sign(
            crypto: crypto,
            publicKey: pair.publicKey,
            secretKey: pair.secretKey,
            payload: OrganizerPayload(
              name: name,
              issued: DateTime.now().subtract(const Duration(minutes: 5)),
              expires: expires ?? DateTime.now().add(const Duration(hours: 8)),
              route: const [(48.85, 2.35), (48.86, 2.36)],
              points: const [OrganizerPoint(kind: PointKind.water, name: 'Fontaine', lat: 48.85, lon: 2.35)],
              contacts: const [OrganizerContact(name: 'Permanence', phone: '01 23 45 67 89')],
              map: map,
              organizerName: by,
            ),
          ),
    );
  }

  File textFile(Directory dir, String text, [String name = 'evenement.cortege']) =>
      File('${dir.path}/$name')..writeAsStringSync(text);

  test('chaque refus a son message en français', () {
    for (final problem in PacketProblem.values) {
      final message = describePacketProblem(PacketRejected(problem, 'abcd-1234'));
      expect(message, isNotEmpty);
      expect(message, isNot(contains('PacketProblem')));
    }
    expect(
      describePacketProblem(PacketRejected(PacketProblem.unknownOrganizer, 'abcd-1234')),
      contains('abcd-1234'),
    );
    expect(
      describePacketProblem(PacketRejected(PacketProblem.badSignature)),
      contains('Ne l\'utilise pas'),
    );
  });

  testWidgets('sans événement, l\'écran de la carte l\'explique et renvoie vers l\'organisation', (tester) async {
    bigScreen(tester);
    final (controller, _, _) = await open(tester);

    await tester.pumpWidget(app(MapScreen(controller: controller)));
    await tester.pump();
    await tester.pump();

    expect(find.text('Pas d\'événement sur ce téléphone'), findsOneWidget);
    expect(find.textContaining('ne télécharge rien'), findsOneWidget);
    expect(find.text('Organisation'), findsWidgets);
    expect(find.byType(MapView), findsNothing);
  });

  testWidgets('depuis l\'écran de la carte vide, un seul appui mène à l\'import, puis la carte se remplit', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    picker.next = textFile(dir, org.sign(by: 'Collectif Eau'));

    await tester.pumpWidget(app(MapScreen(controller: controller)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Importer un événement (fichier)'), findsOneWidget);

    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester, until: find.text('Faire confiance et importer'));
    await tester.tap(find.text('Faire confiance et importer'));
    await settle(tester, until: find.text('Événement en place'));
    await tester.tap(find.text('Terminé'));
    await settle(tester, until: find.text('Sans fond de carte'));

    expect(find.text('Sans fond de carte'), findsOneWidget);
    expect(find.text('Pas d\'événement sur ce téléphone'), findsNothing);
  });

  testWidgets('avec un événement mais sans carte, le parcours et les lieux s\'affichent sur un fond vide', (tester) async {
    bigScreen(tester);
    final (controller, _, dir) = await open(tester);
    final org = organizer();
    await tester.runAsync(() async {
      await controller.organizer!.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey));
      await controller.organizer!.importPacket(org.sign());
    });

    await tester.pumpWidget(app(MapScreen(controller: controller)));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sans fond de carte'), findsOneWidget);
    final view = tester.widget<MapView>(find.byType(MapView));
    expect(view.store, isNull);
    expect(find.text('GPS'), findsOneWidget);
    expect(find.text('Pas d\'événement sur ce téléphone'), findsNothing);
    expect(dir.existsSync(), isTrue);
  });

  testWidgets('l\'organisation sans rien : un seul bouton pour tout importer', (tester) async {
    bigScreen(tester);
    final (controller, _, _) = await open(tester);

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));

    expect(find.text('Aucun événement valable.'), findsOneWidget);
    expect(find.text('Aucun pour l\'instant.'), findsOneWidget);
    expect(find.text('Importer un événement (fichier)'), findsOneWidget);
    expect(find.text('Importer la carte (fichier)'), findsNothing);
    expect(find.text('Importer un paquet (fichier)'), findsNothing);
  });

  testWidgets('un événement d\'un organisateur de confiance s\'importe en un appui', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    picker.next = textFile(dir, org.sign());
    await tester.runAsync(
      () => controller.organizer!.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey)),
    );

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    expect(find.text('Collectif'), findsOneWidget);
    expect(find.textContaining('Empreinte ${OrganizerPacket.fingerprintOf(org.publicKey)}'), findsOneWidget);

    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);

    expect(find.text('Marche d\'essai'), findsOneWidget);
    expect(find.text('Organisateur de confiance'), findsOneWidget);
    expect(find.text('Faire confiance et importer'), findsNothing);
    await tester.tap(find.text('Importer'));
    await settle(tester, until: find.text('Événement en place'));

    expect(find.text('Événement en place'), findsOneWidget);
    expect(find.textContaining('Pas de carte avec cet événement'), findsOneWidget);
    await tester.tap(find.text('Terminé'));
    await settle(tester);

    expect(find.text('Marche d\'essai'), findsOneWidget);
    expect(find.textContaining('1 lieu'), findsOneWidget);
    expect(File('${dir.path}/evenement.cortege').existsSync(), isFalse, reason: 'la copie temporaire est supprimée');
  });

  testWidgets('un organisateur inconnu montre son empreinte et attend un accord', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    picker.next = textFile(dir, org.sign(by: 'Collectif Eau'));

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);

    expect(find.text('Organisateur inconnu'), findsOneWidget);
    expect(find.text(OrganizerPacket.fingerprintOf(org.publicKey)), findsOneWidget);
    expect(find.textContaining('Collectif Eau'), findsOneWidget);
    expect(find.textContaining('ça ne prouve rien'), findsOneWidget);
    expect(controller.organizer!.organizers, isEmpty);
    expect(controller.organizer!.packets, isEmpty);

    await tester.tap(find.text('Faire confiance et importer'));
    await settle(tester, until: find.text('Événement en place'));

    expect(find.text('Événement en place'), findsOneWidget);
    expect(controller.organizer!.organizers.single.name, 'Collectif Eau');
    expect(controller.organizer!.packets, hasLength(1));
  });

  testWidgets('annuler ne retient rien', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    picker.next = textFile(dir, org.sign());

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);
    await tester.tap(find.text('Annuler'));
    await settle(tester);

    expect(find.text('Aucun événement valable.'), findsOneWidget);
    expect(controller.organizer!.organizers, isEmpty);
    expect(controller.organizer!.packets, isEmpty);
    expect(File('${dir.path}/evenement.cortege').existsSync(), isFalse);
  });

  testWidgets('un événement qui fixe la clé des medics le dit avant l\'import', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final pair = crypto.newSigningKeyPair();
    String sign({Uint8List? medicKey}) => OrganizerPacket.sign(
          crypto: crypto,
          publicKey: pair.publicKey,
          secretKey: pair.secretKey,
          payload: OrganizerPayload(
            name: 'Marche',
            issued: DateTime.now().subtract(const Duration(minutes: 5)),
            expires: DateTime.now().add(const Duration(hours: 8)),
            medicKey: medicKey,
            organizerName: 'Collectif',
          ),
        );

    picker.next = textFile(dir, sign(medicKey: Uint8List(32)));
    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester, until: find.text('Faire confiance et importer'));

    expect(find.textContaining('fixe aussi la clé des medics'), findsOneWidget);
    expect(find.textContaining('avec ta position'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await settle(tester);

    picker.next = textFile(dir, sign(), 'sans-medic.cortege');
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester, until: find.text('Faire confiance et importer'));

    expect(find.textContaining('fixe aussi la clé des medics'), findsNothing);
  });

  testWidgets('un nom déjà pris par une autre clé est signalé', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final known = organizer();
    await tester.runAsync(
      () => controller.organizer!.trust(OrganizerInvite(name: 'Collectif', publicKey: known.publicKey)),
    );
    picker.next = textFile(dir, organizer().sign(by: 'Collectif'));

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);

    expect(find.textContaining('Quelqu\'un se fait peut-être passer pour lui'), findsOneWidget);
    expect(find.text('Faire confiance et importer'), findsOneWidget);
  });

  testWidgets('le fichier unique apporte aussi la carte', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    final reference = await tester.runAsync(
      () async => MapReference(
        hash: _hex(await crypto.hashFile(fixture)),
        size: fixture.lengthSync(),
        name: 'paris.pmtiles',
      ),
    );
    final bundle = File('${dir.path}/evenement.cortege');
    await tester.runAsync(() => EventFile.write(packet: org.sign(map: reference), map: fixture, target: bundle));
    picker.next = bundle;
    await tester.runAsync(
      () => controller.organizer!.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey)),
    );

    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);
    expect(find.textContaining('jointe'), findsOneWidget);
    await tester.tap(find.text('Importer'));
    await settle(tester, until: find.text('Événement en place'));

    expect(find.text('Événement en place'), findsOneWidget);
    expect(find.textContaining('Carte hors ligne en place : paris.pmtiles'), findsOneWidget);
    expect(controller.organizer!.mapInfo, isNotNull);
  });

  testWidgets('un fichier quelconque, ou un événement expiré, est refusé avec un message clair', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);

    picker.next = File('${dir.path}/photo.jpg')..writeAsBytesSync(Uint8List.fromList(List.generate(3000, (i) => i % 200)));
    await tester.pumpWidget(app(OrganizationScreen(controller: controller)));
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);

    expect(find.text('Import impossible'), findsOneWidget);
    expect(find.textContaining('n\'est pas un événement Cortège lisible'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await settle(tester);

    final org = organizer();
    picker.next = textFile(
      dir,
      org.sign(expires: DateTime.now().subtract(const Duration(minutes: 1))),
      'vieux.cortege',
    );
    await tester.tap(find.text('Importer un événement (fichier)'));
    await settle(tester);

    expect(find.text('Import impossible'), findsOneWidget);
  });

  testWidgets('un fichier ouvert avec Cortège apparaît dès que le code est saisi', (tester) async {
    bigScreen(tester);
    final (controller, picker, dir) = await open(tester);
    final org = organizer();
    controller.lock();

    await tester.pumpWidget(CortegeApp(controller: controller));
    await tester.pump();
    // L'autre appli a ouvert le fichier pendant que le téléphone était verrouillé.
    picker.incoming = textFile(dir, org.sign(by: 'Collectif Eau'));
    await tester.pump();
    expect(find.text('Organisateur inconnu'), findsNothing);

    await tester.runAsync(() => controller.unlock('483920'));
    await settle(tester);

    expect(find.text('Organisateur inconnu'), findsOneWidget);
    expect(find.text(OrganizerPacket.fingerprintOf(org.publicKey)), findsOneWidget);
    expect(find.text('Faire confiance et importer'), findsOneWidget);
  });

  testWidgets('l\'écran d\'un paquet montre le signataire, les lieux et les contacts', (tester) async {
    bigScreen(tester);
    final pair = crypto.newSigningKeyPair();
    final packet = OrganizerPacket.parse(
      OrganizerPacket.sign(
        crypto: crypto,
        publicKey: pair.publicKey,
        secretKey: pair.secretKey,
        payload: OrganizerPayload(
          name: 'Marche d\'essai',
          issued: DateTime.now().subtract(const Duration(minutes: 5)),
          expires: DateTime.now().add(const Duration(hours: 8)),
          points: const [
            OrganizerPoint(kind: PointKind.water, name: 'Fontaine', lat: 48.85, lon: 2.35, note: 'Eau potable'),
            OrganizerPoint(kind: PointKind.meeting, name: 'Départ', lat: 48.85, lon: 2.36),
          ],
          contacts: const [OrganizerContact(name: 'Permanence', phone: '01 23 45 67 89', note: 'Jour et nuit')],
        ),
      ),
      crypto,
    );

    await tester.pumpWidget(app(PacketScreen(packet: packet, organizerName: 'Collectif')));

    expect(find.text('Collectif'), findsOneWidget);
    expect(find.text(packet.fingerprint), findsOneWidget);
    expect(find.text('Point d\'eau (1)'), findsOneWidget);
    expect(find.text('Eau potable'), findsOneWidget);
    expect(find.text('Rendez-vous (1)'), findsOneWidget);
    expect(find.text('Permanence'), findsOneWidget);
    expect(find.text('01 23 45 67 89'), findsOneWidget);
    expect(find.textContaining('prouve qui l\'a écrit'), findsOneWidget);
  });
}
