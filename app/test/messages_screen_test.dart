import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/ui/messages_screens.dart';
import 'package:cortege/ui/qr_widgets.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/memory_hardware.dart';

void main() {
  /// Un coffre ouvert avec un groupe et quelques messages, prêt pour les écrans.
  /// Tout ce qui touche au disque se fait dans `runAsync` : dans `testWidgets`,
  /// le temps est simulé et une vraie écriture ne se terminerait jamais.
  Future<(MeshController, String)> prepare(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('cortege_ui_mesh');
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final vaultCrypto = (await tester.runAsync(VaultCrypto.create))!;
    final store = VaultStore(
      crypto: vaultCrypto,
      hardware: MemoryHardwareSecretStore(),
      directory: dir,
      kdf: KdfParams.cheapForTests,
    );
    final session = (await tester.runAsync(() => store.create(pin: '483920')))!;
    final mesh = MeshController(
      crypto: MeshCrypto(vaultCrypto),
      session: session,
      transport: FakeTransport(FakeAir(), 'moi'),
      jitter: false,
    );
    await tester.runAsync(() async {
      await mesh.start();
      await mesh.setDisplayName('Alex');
      await mesh.createGroup('Équipe');
    });
    final id = mesh.groups.single.id;
    session.state.records.addAll([
      VaultRecord(
        id: 'm1',
        kind: MeshController.kind,
        createdAt: DateTime.now(),
        data: {'g': id, 'n': 'Blan', 'k': 'a1b2c3', 't': 'rendez-vous à 18 h', 'm': false},
      ),
      VaultRecord(
        id: 'm2',
        kind: MeshController.kind,
        createdAt: DateTime.now(),
        data: {'g': id, 'n': 'Alex', 'k': 'ffeedd', 't': 'bien reçu', 'm': true},
      ),
    ]);
    addTearDown(mesh.dispose);
    return (mesh, id);
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

  testWidgets('la liste des groupes montre le nom, le compte de messages et l\'état', (tester) async {
    final (mesh, _) = await prepare(tester);
    await tester.pumpWidget(app(MessagesScreen(mesh: mesh)));

    expect(find.text('Équipe'), findsOneWidget);
    expect(find.text('2 messages'), findsOneWidget);
    expect(find.text('Pseudo'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Créer un groupe'), findsOneWidget);
    expect(find.text('Rejoindre avec un QR'), findsOneWidget);
  });

  testWidgets('la conversation montre qui parle, et distingue ses propres messages', (tester) async {
    final (mesh, id) = await prepare(tester);
    await tester.pumpWidget(app(GroupScreen(mesh: mesh, groupId: id)));

    expect(find.text('rendez-vous à 18 h'), findsOneWidget);
    expect(find.text('bien reçu'), findsOneWidget);
    expect(find.textContaining('Blan (a1b2c3)'), findsOneWidget);
    expect(find.textContaining('Toi'), findsOneWidget);
  });

  testWidgets('un message trop long est refusé avant l\'envoi', (tester) async {
    final (mesh, id) = await prepare(tester);
    await tester.pumpWidget(app(GroupScreen(mesh: mesh, groupId: id)));

    await tester.enterText(find.byType(TextField), 'x' * 301);
    await tester.pump();
    expect(find.textContaining('Trop long'), findsOneWidget);
    final send = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Envoyer'));
    expect(send.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'x' * 300);
    await tester.pump();
    expect(find.textContaining('300 / 300'), findsOneWidget);
    final ok = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Envoyer'));
    expect(ok.onPressed, isNotNull);
  });

  testWidgets('le QR d\'invitation s\'affiche avec son avertissement', (tester) async {
    final (mesh, id) = await prepare(tester);
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(InviteScreen(mesh: mesh, groupId: id)));

    expect(find.byType(QrCodeView), findsOneWidget);
    expect(find.textContaining('Quiconque le scanne'), findsOneWidget);
    expect(find.text('Équipe'), findsOneWidget);
  });
}
