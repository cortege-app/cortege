import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/ui/lock_screen.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/vault/attempt_limiter.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

const realPin = '483920';
const duressPin = '715204';

void main() {
  late VaultCrypto crypto;
  late Directory dir;
  late DateTime clock;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cortege_attempts');
    clock = DateTime.utc(2026, 10, 22, 12);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  VaultStore newStore([MemoryHardwareSecretStore? hardware]) => VaultStore(
        crypto: crypto,
        hardware: hardware ?? MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
        now: () => clock,
      );

  group('l\'attente après des essais ratés', () {
    test('cinq essais libres, puis une attente qui grandit', () {
      final delays = [for (var i = 1; i <= 10; i++) AttemptLimiter.delayAfter(i)];
      expect(delays, [
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
        const Duration(seconds: 30),
        const Duration(minutes: 1),
        const Duration(minutes: 5),
        const Duration(minutes: 15),
        const Duration(hours: 1),
        const Duration(hours: 1),
      ]);
    });

    test('le compte survit à un redémarrage et se remet à zéro avec un bon code', () async {
      final file = File('${dir.path}/t.bin');
      var limiter = AttemptLimiter(file: file, now: () => clock);
      for (var i = 0; i < 4; i++) {
        await limiter.recordAttempt();
      }
      expect(await limiter.remaining(), Duration.zero);

      await limiter.recordAttempt();
      expect(await limiter.remaining(), const Duration(seconds: 30));

      // L'appli est fermée puis rouverte : l'attente est toujours là.
      limiter = AttemptLimiter(file: file, now: () => clock);
      clock = clock.add(const Duration(seconds: 10));
      expect(await limiter.remaining(), const Duration(seconds: 20));
      clock = clock.add(const Duration(seconds: 20));
      expect(await limiter.remaining(), Duration.zero);

      await limiter.recordAttempt();
      expect(await limiter.remaining(), const Duration(minutes: 1));

      await limiter.reset();
      expect(await limiter.remaining(), Duration.zero);
      expect(file.existsSync(), isFalse);
      await limiter.recordAttempt();
      expect(await limiter.remaining(), Duration.zero, reason: 'on repart de zéro');
    });

    test('reculer l\'horloge ne raccourcit pas l\'attente et ne la rallonge pas', () async {
      final limiter = AttemptLimiter(file: File('${dir.path}/t.bin'), now: () => clock);
      for (var i = 0; i < 5; i++) {
        await limiter.recordAttempt();
      }

      clock = clock.subtract(const Duration(days: 2));

      expect(await limiter.remaining(), const Duration(seconds: 30));
    });

    test('un fichier absent, vide ou abîmé ne bloque personne', () async {
      final file = File('${dir.path}/t.bin');
      final limiter = AttemptLimiter(file: file, now: () => clock);
      expect(await limiter.remaining(), Duration.zero);

      file.writeAsBytesSync([1, 2, 3]);
      expect(await limiter.remaining(), Duration.zero);
    });
  });

  group('sur le coffre', () {
    test('après cinq essais ratés, même le bon code attend', () async {
      final store = newStore();
      (await store.create(pin: realPin, duressPin: duressPin)).lock();

      for (var i = 0; i < 5; i++) {
        expect(await store.unlock('000999'), isNull);
      }

      await expectLater(
        store.unlock(realPin),
        throwsA(isA<LockedOut>().having((e) => e.remaining, 'attente', const Duration(seconds: 30))),
      );
      await expectLater(store.unlock(duressPin), throwsA(isA<LockedOut>()));
      expect(await store.lockoutRemaining(), const Duration(seconds: 30));

      clock = clock.add(const Duration(seconds: 31));
      final session = await store.unlock(realPin);
      expect(session, isNotNull);
      session!.lock();
      expect(await store.lockoutRemaining(), Duration.zero);
    });

    test('un échec de plus après l\'attente double presque l\'attente, un bon code la remet à zéro', () async {
      final store = newStore();
      (await store.create(pin: realPin)).lock();
      for (var i = 0; i < 5; i++) {
        await store.unlock('000999');
      }
      clock = clock.add(const Duration(seconds: 31));

      expect(await store.unlock('000999'), isNull);
      expect(await store.lockoutRemaining(), const Duration(minutes: 1));

      clock = clock.add(const Duration(minutes: 1, seconds: 1));
      (await store.unlock(realPin))!.lock();
      for (var i = 0; i < 4; i++) {
        expect(await store.unlock('000999'), isNull, reason: 'cinq essais libres de nouveau');
      }
      expect(await store.lockoutRemaining(), Duration.zero);
    });

    test('le code de contrainte remet aussi le compte à zéro, sans rien dire de plus', () async {
      final store = newStore();
      (await store.create(pin: realPin, duressPin: duressPin)).lock();
      for (var i = 0; i < 4; i++) {
        await store.unlock('000999');
      }

      final decoy = await store.unlock(duressPin);

      expect(decoy, isNotNull);
      decoy!.lock();
      for (var i = 0; i < 4; i++) {
        expect(await store.unlock('000999'), isNull);
      }
      expect(await store.lockoutRemaining(), Duration.zero);
    });

    test('un téléphone dont les secrets ont disparu n\'est pas compté comme un essai raté', () async {
      final hardware = MemoryHardwareSecretStore();
      final store = newStore(hardware);
      (await store.create(pin: realPin)).lock();
      await hardware.eraseAll();

      for (var i = 0; i < 8; i++) {
        await expectLater(store.unlock(realPin), throwsA(isA<VaultUnrecoverable>()));
      }
      expect(await store.lockoutRemaining(), Duration.zero);
    });

    test('tout effacer et recréer remet l\'attente à zéro', () async {
      final store = newStore();
      (await store.create(pin: realPin)).lock();
      for (var i = 0; i < 5; i++) {
        await store.unlock('000999');
      }
      expect(await store.lockoutRemaining(), isNot(Duration.zero));

      await store.wipe();

      expect(await store.lockoutRemaining(), Duration.zero);
    });
  });

  group('à l\'écran de code', () {
    Future<AppController> openController(WidgetTester tester) async {
      final controller = AppController(store: newStore());
      await tester.runAsync(() async {
        await controller.start();
        await controller.setUp(pin: realPin);
      });
      controller.lock();
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }

    /// Tape un code puis attend que l'écran ait réagi : message d'erreur, attente
    /// imposée, ou coffre ouvert. Quand le clavier est figé, rien ne vient et on
    /// attend un peu pour s'en assurer.
    Future<void> enter(WidgetTester tester, String pin, AppController controller) async {
      for (final digit in pin.split('')) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      await tester.tap(find.text('OK'));
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
        if (find.text('Code incorrect.').evaluate().isNotEmpty ||
            find.textContaining('Trop d\'essais').evaluate().isNotEmpty ||
            controller.phase == AppPhase.unlocked) {
          break;
        }
      }
    }

    void bigScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('le texte de l\'attente est lisible', (tester) async {
      expect(waitText(const Duration(seconds: 30)), '30 s');
      expect(waitText(const Duration(milliseconds: 29400)), '30 s');
      expect(waitText(const Duration(minutes: 1)), '1 min');
      expect(waitText(const Duration(minutes: 4, seconds: 12)), '4 min 12 s');
      expect(waitText(const Duration(minutes: 15)), '15 min');
      expect(waitText(const Duration(hours: 1)), '1 h');
    });

    testWidgets('après cinq codes faux, le clavier se fige avec un décompte, puis repart', (tester) async {
      bigScreen(tester);
      final controller = await openController(tester);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: LockScreen(controller: controller)));
      await tester.pump();

      for (var i = 0; i < 4; i++) {
        await enter(tester, '000999', controller);
        expect(find.text('Code incorrect.'), findsOneWidget);
      }
      await enter(tester, '000999', controller);
      await settle(tester);

      expect(find.textContaining('Trop d\'essais. Réessaie dans 30 s.'), findsOneWidget);
      expect(find.text('Code incorrect.'), findsNothing);

      // Le clavier ne répond plus : le bon code, tapé pendant l'attente, n'ouvre rien.
      await enter(tester, realPin, controller);
      await settle(tester);
      expect(controller.phase, AppPhase.locked);
      expect(find.textContaining('Trop d\'essais'), findsOneWidget);

      // Le décompte avance d'une seconde à chaque seconde.
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Réessaie dans 29 s'), findsOneWidget);

      // L'attente finie, le clavier repart et le bon code ouvre.
      clock = clock.add(const Duration(seconds: 40));
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(find.textContaining('Trop d\'essais'), findsNothing);
      await enter(tester, realPin, controller);
      expect(controller.phase, AppPhase.unlocked);
      // Le minuteur d'effacement de l'appli ouverte ne doit pas survivre au test.
      controller.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
