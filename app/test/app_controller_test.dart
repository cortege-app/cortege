import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/memory_hardware.dart';

const pin = '483920';
const duress = '715204';

class Rig {
  Rig(this.controller, this.transport);

  final AppController controller;
  final FakeTransport transport;

  MeshController get mesh => controller.mesh!;
  VaultState get state => controller.session!.state;
}

void main() {
  late VaultCrypto vaultCrypto;
  late FakeAir air;
  late DateTime clock;
  final dirs = <Directory>[];
  final controllers = <AppController>[];

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final dir in dirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    dirs.clear();
  });

  Future<Rig> rig(String name, {bool withDuress = false}) async {
    final dir = Directory.systemTemp.createTempSync('cortege_app_$name');
    dirs.add(dir);
    final transport = FakeTransport(air, name);
    final controller = AppController(
      store: VaultStore(
        crypto: vaultCrypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      ),
      now: () => clock,
      meshFactory: (session) => MeshController(
        crypto: MeshCrypto(vaultCrypto),
        session: session,
        transport: transport,
        now: () => clock,
        jitter: false,
      ),
    );
    controllers.add(controller);
    await controller.start();
    await controller.setUp(pin: pin, duressPin: withDuress ? duress : null);
    await Future<void>.delayed(Duration.zero);
    await controller.mesh!.setDisplayName(name);
    return Rig(controller, transport);
  }

  group('premier niveau : l\'écran de code', () {
    test('le coffre et la radio restent en mémoire derrière l\'écran de code', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      expect(alex.transport.running, isTrue);

      alex.controller.lockScreen();

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.controller.runningBehindLock, isTrue);
      expect(alex.controller.session, isNotNull);
      expect(alex.transport.running, isTrue, reason: 'la radio ne doit pas s\'arrêter');
      expect(alex.mesh.status, MeshStatus.running);
    });

    test('le bon code rouvre le même coffre sans couper la radio', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      final session = alex.controller.session;
      final mesh = alex.controller.mesh;
      final starts = alex.transport.startCount;
      alex.controller.lockScreen();

      expect(await alex.controller.unlock(pin), isTrue);

      expect(alex.controller.phase, AppPhase.unlocked);
      expect(identical(alex.controller.session, session), isTrue);
      expect(identical(alex.controller.mesh, mesh), isTrue);
      expect(alex.transport.startCount, starts, reason: 'la radio n\'a pas redémarré');
      expect(alex.transport.running, isTrue);
    });

    test('un mauvais code ne ferme rien', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.controller.lockScreen();

      expect(await alex.controller.unlock('000999'), isFalse);

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.controller.runningBehindLock, isTrue);
      expect(alex.transport.running, isTrue);
    });

    test('derrière l\'écran de code, le code de contrainte ferme le vrai coffre et ouvre le leurre', () async {
      final alex = await rig('Alex', withDuress: true);
      await alex.mesh.createGroup('Équipe');
      expect(alex.state.role, VaultRole.real);
      alex.controller.lockScreen();

      expect(await alex.controller.unlock(duress), isTrue);

      expect(alex.controller.phase, AppPhase.unlocked);
      expect(alex.state.role, VaultRole.decoy);
      expect(alex.state.groups, isEmpty, reason: 'le leurre ne contient rien');
      expect(alex.transport.running, isFalse, reason: 'le vrai maillage est fermé');
      expect(alex.mesh.groups, isEmpty);
    });

    test('un message reçu derrière l\'écran de code est enregistré', () async {
      final alex = await rig('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await rig('Blan');
      await blan.mesh.joinGroup(invite);
      final id = alex.mesh.groups.single.id;

      alex.controller.lockScreen();
      await blan.mesh.sendMessage(blan.mesh.groups.single.id, 'tu me reçois ?');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.state.records.where((r) => r.kind == MeshController.kind), hasLength(1));
      expect(await alex.controller.unlock(pin), isTrue);
      expect(alex.mesh.messagesOf(id).map((m) => m.text), ['tu me reçois ?']);
    });

    test('on peut répondre depuis un téléphone verrouillé puis déverrouillé', () async {
      final alex = await rig('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await rig('Blan');
      await blan.mesh.joinGroup(invite);
      alex.controller.lockScreen();
      await alex.controller.unlock(pin);

      await alex.mesh.sendMessage(alex.mesh.groups.single.id, 'de retour');

      expect(blan.mesh.messagesOf(blan.mesh.groups.single.id).map((m) => m.text), ['de retour']);
    });
  });

  group('second niveau : la fermeture complète', () {
    test('après la durée choisie, la clé est détruite et la radio s\'arrête', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.state.closeAfter = const Duration(milliseconds: 60);
      alex.controller.lockScreen();
      expect(alex.transport.running, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.controller.session, isNull);
      expect(alex.controller.runningBehindLock, isFalse);
      expect(alex.transport.running, isFalse);
      // Rouvrir demande de refaire tout le chemin : c'est un autre coffre ouvert.
      expect(await alex.controller.unlock(pin), isTrue);
      expect(alex.controller.session, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alex.mesh.groups.single.name, 'Équipe', reason: 'les groupes sont dans le coffre');
      expect(alex.transport.running, isTrue, reason: 'le maillage redémarre avec le coffre');
    });

    test('durée nulle : l\'écran de code ferme tout tout de suite', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.state.closeAfter = Duration.zero;

      alex.controller.lockScreen();

      expect(alex.controller.session, isNull);
      expect(alex.transport.running, isFalse);
    });

    test('« tout verrouiller » ferme tout sans attendre', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');

      alex.controller.lock();

      expect(alex.controller.session, isNull);
      expect(alex.controller.mesh, isNull);
      expect(alex.transport.running, isFalse);
    });

    test('verrouillage complet en cours de route : le minuteur ne rouvre rien', () async {
      final alex = await rig('Alex');
      alex.state.closeAfter = const Duration(milliseconds: 60);
      alex.controller.lockScreen();
      alex.controller.lock();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(alex.controller.session, isNull);
      expect(alex.controller.phase, AppPhase.locked);
    });
  });

  group('en quittant et en revenant dans l\'appli', () {
    test('revenir avant le délai : rien ne se verrouille', () async {
      final alex = await rig('Alex');
      alex.controller.didEnterBackground();
      clock = clock.add(const Duration(seconds: 10));
      alex.controller.didReturnToForeground();
      expect(alex.controller.phase, AppPhase.unlocked);
    });

    test('quitter plus longtemps que le délai : l\'écran de code, le maillage continue', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.controller.didEnterBackground();
      clock = clock.add(const Duration(minutes: 2));
      alex.controller.didReturnToForeground();

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.controller.runningBehindLock, isTrue);
      expect(alex.transport.running, isTrue);
    });

    test('l\'écran de code arrive tout seul en arrière-plan, sans qu\'on revienne', () async {
      final alex = await rig('Alex');
      alex.state.lockAfter = const Duration(milliseconds: 50);
      alex.controller.didEnterBackground();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(alex.controller.phase, AppPhase.locked);
      expect(alex.controller.runningBehindLock, isTrue);
    });

    test('revenir après la durée en mémoire : verrouillage complet, même si le minuteur a dormi', () async {
      final alex = await rig('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.controller.lockScreen();
      expect(alex.controller.runningBehindLock, isTrue);

      clock = clock.add(const Duration(hours: 2));
      alex.controller.didReturnToForeground();

      expect(alex.controller.session, isNull);
      expect(alex.transport.running, isFalse);
    });
  });

  group('réglages', () {
    test('les deux durées sont gardées dans le coffre', () async {
      final alex = await rig('Alex');
      await alex.controller.setLockAfter(const Duration(minutes: 5));
      await alex.controller.setCloseAfter(const Duration(hours: 4));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      alex.controller.lock();

      expect(await alex.controller.unlock(pin), isTrue);
      expect(alex.state.lockAfter, const Duration(minutes: 5));
      expect(alex.state.closeAfter, const Duration(hours: 4));
    });

    test('par défaut : écran de code après 30 secondes, une heure en mémoire', () async {
      final alex = await rig('Alex');
      expect(alex.state.lockAfter, const Duration(seconds: 30));
      expect(alex.state.closeAfter, const Duration(hours: 1));
    });
  });
}
