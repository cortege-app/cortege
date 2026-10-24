import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/ui/app.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/disk_bundle.dart';
import 'support/memory_hardware.dart';

/// Un écran ouvert (une fiche, les réglages) ne doit jamais rester visible une
/// fois l'appli verrouillée.
void main() {
  Future<AppController> openedApp(WidgetTester tester) async {
    // Écran haut : la liste d'accueil est construite à la demande, les
    // dernières entrées n'existent pas tant qu'elles sont hors écran.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('cortege_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final crypto = (await tester.runAsync(VaultCrypto.create))!;
    final controller = AppController(
      store: VaultStore(
        crypto: crypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      ),
    );
    await tester.runAsync(() => controller.setUp(pin: '483920'));
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: DiskAssetBundle(),
        child: CortegeApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('verrouiller ferme une fiche ouverte', (tester) async {
    final controller = await openedApp(tester);

    await tester.tap(find.text('Droits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contrôle d\'identité'));
    await tester.pumpAndSettle();
    expect(find.text('Qui peut te contrôler, et quand'), findsOneWidget);

    controller.lock();
    await tester.pumpAndSettle();

    expect(find.text('Qui peut te contrôler, et quand'), findsNothing);
    expect(find.text('Tape ton code.'), findsOneWidget);
    addTearDown(controller.dispose);
  });

  testWidgets('verrouiller ferme les réglages', (tester) async {
    final controller = await openedApp(tester);

    await tester.tap(find.text('Réglages'));
    await tester.pumpAndSettle();
    expect(find.text('Effacement automatique'), findsOneWidget);

    controller.lock();
    await tester.pumpAndSettle();

    expect(find.text('Effacement automatique'), findsNothing);
    expect(find.text('Tape ton code.'), findsOneWidget);
    addTearDown(controller.dispose);
  });
}
