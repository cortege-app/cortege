import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/ui/app.dart';
import 'package:cortege/ui/lock_screen.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/ui/widgets.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

const realPin = '483920';
const duressPin = '715204';
const newPin = '291847';

/// Code oublié : la seule issue est de tout effacer, sans rien récupérer, même
/// pendant l'attente imposée après trop d'essais ratés.
void main() {
  late VaultCrypto crypto;
  late Directory dir;
  late MemoryHardwareSecretStore hardware;
  late DateTime clock;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cortege_forgot');
    hardware = MemoryHardwareSecretStore();
    clock = DateTime.utc(2026, 10, 24, 12);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  VaultStore newStore() => VaultStore(
        crypto: crypto,
        hardware: hardware,
        directory: dir,
        kdf: KdfParams.cheapForTests,
        now: () => clock,
      );

  Future<(AppController, VaultStore)> lockedApp(WidgetTester tester) async {
    final store = newStore();
    final controller = AppController(store: store);
    await tester.runAsync(() async {
      await controller.start();
      await controller.setUp(pin: realPin, duressPin: duressPin);
    });
    controller.lock();
    addTearDown(controller.dispose);
    return (controller, store);
  }

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Laisse passer les accès aux fichiers (réels) et les animations.
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < (until == null ? 12 : 120); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
      if (until != null && until()) return;
    }
  }

  Future<void> openForgotScreen(WidgetTester tester) async {
    await tester.tap(find.text('Code oublié ?'));
    await settle(tester);
  }

  void confirmWipe(WidgetTester tester) {
    tester.widget<HoldToConfirmButton>(find.byType(HoldToConfirmButton)).onConfirmed();
  }

  testWidgets('l\'écran de code propose « Code oublié ? » et dit qu\'on ne retrouve rien', (tester) async {
    bigScreen(tester);
    final (controller, _) = await lockedApp(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: LockScreen(controller: controller)));
    await settle(tester);

    expect(find.text('Code oublié ?'), findsOneWidget);
    // Le clavier est toujours là, rien n'a bougé.
    expect(find.text('OK'), findsOneWidget);

    await openForgotScreen(tester);
    expect(find.textContaining('Personne ne peut retrouver ton code'), findsOneWidget);
    expect(find.textContaining('La seule issue est de tout effacer'), findsOneWidget);
    expect(find.textContaining('trois secondes'), findsOneWidget);
    expect(find.byType(HoldToConfirmButton), findsOneWidget);
    expect(find.text('Retour à l\'écran de code'), findsOneWidget);
  });

  testWidgets('« Retour » ne touche à rien : le même code ouvre toujours le coffre', (tester) async {
    bigScreen(tester);
    final (controller, store) = await lockedApp(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: LockScreen(controller: controller)));
    await settle(tester);

    await openForgotScreen(tester);
    await tester.tap(find.text('Retour à l\'écran de code'));
    await settle(tester);

    expect(find.text('Tape ton code.'), findsOneWidget);
    expect(await tester.runAsync(store.isInitialized), isTrue);
    expect(controller.phase, AppPhase.locked);
    final opened = await tester.runAsync(() => controller.unlock(realPin));
    expect(opened, isTrue);
    // Le minuteur d'effacement de l'appli ouverte ne doit pas survivre au test.
    controller.lock();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('un appui trop court sur « Tout effacer » n\'efface rien', (tester) async {
    bigScreen(tester);
    final (controller, store) = await lockedApp(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: LockScreen(controller: controller)));
    await settle(tester);
    await openForgotScreen(tester);

    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await settle(tester);

    expect(controller.phase, AppPhase.locked);
    expect(await tester.runAsync(store.isInitialized), isTrue);
    expect(hardware.secrets, isNotEmpty);
  });

  testWidgets('tout effacer détruit le coffre et l\'appli repart de zéro', (tester) async {
    bigScreen(tester);
    final (controller, store) = await lockedApp(tester);
    await tester.pumpWidget(CortegeApp(controller: controller));
    await settle(tester);
    expect(find.text('Tape ton code.'), findsOneWidget);

    await openForgotScreen(tester);
    confirmWipe(tester);
    await settle(tester, until: () => controller.phase == AppPhase.needsSetup);
    // Laisse finir l'animation qui retire l'écran « Code oublié ».
    await settle(tester);

    // L'écran « Code oublié » ne reste pas empilé : on tombe sur la création du coffre.
    expect(controller.phase, AppPhase.needsSetup);
    expect(find.text('Choisir mon code'), findsOneWidget);
    expect(find.text('Code oublié'), findsNothing);
    expect(find.text('Tape ton code.'), findsNothing);

    // Plus rien du coffre : ni fichier, ni secret matériel.
    expect(await tester.runAsync(store.isInitialized), isFalse);
    expect(hardware.secrets, isEmpty);

    // On repart avec un nouveau code : l'ancien, et celui de contrainte, n'ouvrent plus rien.
    await tester.runAsync(() => controller.setUp(pin: newPin));
    controller.lock();
    expect(await tester.runAsync(() => controller.unlock(realPin)), isFalse);
    expect(await tester.runAsync(() => controller.unlock(duressPin)), isFalse);
    expect(await tester.runAsync(() => controller.unlock(newPin)), isTrue);
    controller.lock();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('le chemin reste ouvert pendant l\'attente, et l\'effacement la remet à zéro', (tester) async {
    bigScreen(tester);
    final (controller, store) = await lockedApp(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        expect(await controller.unlock('000999'), isFalse);
      }
    });
    expect(await tester.runAsync(controller.lockoutRemaining), greaterThan(Duration.zero));

    await tester.pumpWidget(CortegeApp(controller: controller));
    await settle(tester);
    expect(find.textContaining('Trop d\'essais'), findsOneWidget);

    await openForgotScreen(tester);
    confirmWipe(tester);
    await settle(tester, until: () => controller.phase == AppPhase.needsSetup);

    expect(controller.phase, AppPhase.needsSetup);
    expect(await tester.runAsync(controller.lockoutRemaining), Duration.zero);
    expect(await tester.runAsync(store.isInitialized), isFalse);
    expect(find.text('Choisir mon code'), findsOneWidget);
  });
}
