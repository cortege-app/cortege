import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/memory_hardware.dart';

class Phone {
  Phone(this.name, this.store, this.mesh, this.session, this.transport, this.pin);

  final String name;
  final VaultStore store;
  MeshController mesh;
  VaultSession session;
  final FakeTransport transport;
  final String pin;
}

void main() {
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  late FakeAir air;
  late DateTime clock;
  final dirs = <Directory>[];

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
  });

  tearDown(() async {
    // Les enregistrements partent en arrière-plan : on laisse les écritures
    // finir avant de supprimer les dossiers.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final dir in dirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    dirs.clear();
  });

  Future<Phone> phone(
    String name, {
    String pin = '483920',
    bool named = true,
    Duration retryInterval = const Duration(minutes: 5),
  }) async {
    final dir = Directory.systemTemp.createTempSync('cortege_mesh_$name');
    dirs.add(dir);
    final store = VaultStore(
      crypto: vaultCrypto,
      hardware: MemoryHardwareSecretStore(),
      directory: dir,
      kdf: KdfParams.cheapForTests,
    );
    final session = await store.create(pin: pin);
    final transport = FakeTransport(air, name);
    final mesh = MeshController(
      crypto: crypto,
      session: session,
      transport: transport,
      now: () => clock,
      jitter: false,
      retryInterval: retryInterval,
    );
    await mesh.start();
    if (named) await mesh.setDisplayName(name);
    return Phone(name, store, mesh, session, transport, pin);
  }

  Future<String> join(Phone phone, GroupInvite invite) =>
      phone.mesh.joinGroup(GroupInvite.decode(invite.encode()));

  group('groupes', () {
    test('créer un groupe ouvre un événement et allume la radio', () async {
      final alex = await phone('Alex');
      expect(alex.mesh.groups, isEmpty);
      expect(alex.mesh.status, MeshStatus.stopped);

      final invite = await alex.mesh.createGroup('Équipe');

      expect(alex.mesh.groups.single.name, 'Équipe');
      expect(alex.session.state.eventSecret, invite.eventSecret);
      expect(alex.mesh.status, MeshStatus.running);
      expect(alex.transport.running, isTrue);
    });

    test('rejoindre le groupe d\'un QR', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');

      await join(blan, invite);

      expect(blan.mesh.groups.single.name, 'Équipe');
      expect(blan.session.state.eventSecret, invite.eventSecret);
      expect(blan.mesh.status, MeshStatus.running);
    });

    test('rejoindre deux fois le même groupe ne le duplique pas', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      final first = await join(blan, invite);
      final second = await join(blan, invite);

      expect(second, first);
      expect(blan.mesh.groups, hasLength(1));
      expect(blan.session.state.groups, hasLength(1));
    });

    test('un QR d\'un autre événement est refusé', () async {
      final alex = await phone('Alex');
      final other = await phone('Autre');
      await alex.mesh.createGroup('Équipe');
      final foreign = await other.mesh.createGroup('Ailleurs');

      expect(
        () => alex.mesh.joinGroup(foreign),
        throwsA(isA<DifferentEventException>()),
      );
      expect(alex.mesh.groups, hasLength(1));
    });

    test('un deuxième groupe reste dans le même événement', () async {
      final alex = await phone('Alex');
      final first = await alex.mesh.createGroup('Équipe');
      final second = await alex.mesh.createGroup('Médics');

      expect(second.eventSecret, first.eventSecret);
      expect(second.groupKey, isNot(first.groupKey));
      expect(alex.mesh.groups, hasLength(2));
      expect(alex.transport.startCount, 1, reason: 'la radio ne redémarre pas');
    });

    test('nom de groupe vide refusé', () async {
      final alex = await phone('Alex');
      expect(() => alex.mesh.createGroup('   '), throwsFormatException);
    });

    test('quitter le dernier groupe efface les clés et éteint la radio', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final id = alex.mesh.groups.single.id;
      await alex.mesh.sendMessage(id, 'bonjour');

      await alex.mesh.leaveGroup(id);

      expect(alex.mesh.groups, isEmpty);
      expect(alex.session.state.groups, isEmpty);
      expect(alex.session.state.eventSecret, isNull);
      expect(alex.session.state.records, isEmpty, reason: 'les messages partent avec le groupe');
      expect(alex.mesh.status, MeshStatus.stopped);
      expect(alex.transport.running, isFalse);
      expect(invite.name, 'Équipe');
    });
  });

  group('messages', () {
    test('de l\'un à l\'autre, dans les deux sens', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      await join(blan, invite);
      final alexGroup = alex.mesh.groups.single.id;
      final blanGroup = blan.mesh.groups.single.id;
      expect(alexGroup, blanGroup, reason: 'même clé, même identifiant local');

      await alex.mesh.sendMessage(alexGroup, 'on est devant la gare');
      await blan.mesh.sendMessage(blanGroup, 'bien reçu');

      final atAlex = alex.mesh.messagesOf(alexGroup);
      final atBlan = blan.mesh.messagesOf(blanGroup);
      expect(atAlex.map((m) => m.text), ['on est devant la gare', 'bien reçu']);
      expect(atBlan.map((m) => m.text), ['on est devant la gare', 'bien reçu']);
      expect(atAlex.map((m) => m.mine), [true, false]);
      expect(atBlan.map((m) => m.mine), [false, true]);
      expect(atBlan.first.senderName, 'Alex');
      expect(atBlan.first.senderTag, hasLength(6));
    });

    test('un message n\'est stocké qu\'une fois, même reçu par deux voisins', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      final cleo = await phone('Cléo');
      await join(blan, invite);
      await join(cleo, invite);
      final id = alex.mesh.groups.single.id;

      await alex.mesh.sendMessage(id, 'à tous');

      expect(cleo.mesh.messagesOf(id), hasLength(1));
      expect(blan.mesh.messagesOf(id), hasLength(1));
      expect(alex.mesh.messagesOf(id), hasLength(1));
    });

    test('un autre événement ne reçoit rien', () async {
      final alex = await phone('Alex');
      await alex.mesh.createGroup('Équipe');
      final voisin = await phone('Voisin');
      await voisin.mesh.createGroup('Autre événement');

      await alex.mesh.sendMessage(alex.mesh.groups.single.id, 'privé');

      expect(voisin.mesh.messagesOf(voisin.mesh.groups.single.id), isEmpty);
      expect(voisin.mesh.stats.received, 0, reason: 'ils ne se voient même pas');
    });

    test('un autre groupe du même événement relaie sans lire', () async {
      final alex = await phone('Alex');
      final inviteA = await alex.mesh.createGroup('Équipe');
      final relais = await phone('Relais');
      final inviteR = await relais.mesh.joinGroup(
        GroupInvite(
          name: 'Autre groupe',
          groupKey: crypto.randomBytes(32),
          eventSecret: inviteA.eventSecret,
        ),
      );
      expect(inviteR, isNotEmpty);

      await alex.mesh.sendMessage(alex.mesh.groups.single.id, 'pas pour toi');

      expect(relais.mesh.messagesOf(relais.mesh.groups.single.id), isEmpty);
      expect(relais.mesh.stats.received, 1);
    });

    test('il faut un pseudo pour écrire', () async {
      final alex = await phone('Alex', named: false);
      await alex.mesh.createGroup('Équipe');
      expect(
        () => alex.mesh.sendMessage(alex.mesh.groups.single.id, 'salut'),
        throwsA(isA<NeedsDisplayNameException>()),
      );
      await alex.mesh.setDisplayName('Alex');
      await alex.mesh.sendMessage(alex.mesh.groups.single.id, 'salut');
      expect(alex.mesh.messagesOf(alex.mesh.groups.single.id), hasLength(1));
    });

    test('pseudo vide ou trop long refusé', () async {
      final alex = await phone('Alex');
      expect(() => alex.mesh.setDisplayName('  '), throwsArgumentError);
      expect(() => alex.mesh.setDisplayName('x' * 25), throwsArgumentError);
    });
  });

  group('radio', () {
    test('Bluetooth éteint : le maillage le dit et redémarre sur demande', () async {
      final alex = await phone('Alex');
      alex.transport.unavailable = true;
      await alex.mesh.createGroup('Équipe');

      expect(alex.mesh.status, MeshStatus.unavailable);
      expect(alex.mesh.statusDetail, 'Bluetooth éteint');

      alex.transport.unavailable = false;
      await alex.mesh.retryTransport();
      expect(alex.mesh.status, MeshStatus.running);
    });

    test('Bluetooth rallumé : le maillage redémarre tout seul', () async {
      final alex = await phone('Alex', retryInterval: const Duration(milliseconds: 40));
      alex.transport.unavailable = true;
      await alex.mesh.createGroup('Équipe');
      expect(alex.mesh.status, MeshStatus.unavailable);

      alex.transport.unavailable = false;
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(alex.mesh.status, MeshStatus.running);
      alex.mesh.stop();
    });

    test('une permission refusée n\'est pas redemandée en boucle', () async {
      final alex = await phone('Alex', retryInterval: const Duration(milliseconds: 40));
      alex.transport
        ..unavailable = true
        ..retryable = false;
      await alex.mesh.createGroup('Équipe');
      alex.transport.unavailable = false;

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(alex.mesh.status, MeshStatus.unavailable);
      expect(alex.transport.startCount, 0);
      await alex.mesh.retryTransport();
      expect(alex.mesh.status, MeshStatus.running);
      alex.mesh.stop();
    });

    test('verrouiller arrête la relance automatique', () async {
      final alex = await phone('Alex', retryInterval: const Duration(milliseconds: 40));
      alex.transport.unavailable = true;
      await alex.mesh.createGroup('Équipe');
      alex.mesh.stop();
      alex.transport.unavailable = false;

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(alex.transport.startCount, 0);
    });

    test('le nombre de voisins suit les connexions', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      expect(alex.mesh.neighborCount, 0);
      final blan = await phone('Blan');
      await join(blan, invite);
      expect(alex.mesh.neighborCount, 1);
      expect(blan.mesh.neighborCount, 1);

      await blan.mesh.leaveGroup(blan.mesh.groups.single.id);
      expect(alex.mesh.neighborCount, 0);
    });
  });

  group('verrouillage et réouverture', () {
    test('groupes, clés et messages reviennent après verrouillage', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      await join(blan, invite);
      final id = alex.mesh.groups.single.id;
      await alex.mesh.sendMessage(id, 'avant le verrouillage');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      alex.mesh.stop();
      alex.session.lock();
      expect(alex.transport.running, isFalse);

      final reopened = (await alex.store.unlock(alex.pin))!;
      final mesh = MeshController(
        crypto: crypto,
        session: reopened,
        transport: alex.transport,
        now: () => clock,
        jitter: false,
      );
      await mesh.start();

      expect(mesh.groups.single.name, 'Équipe');
      expect(mesh.messagesOf(id).map((m) => m.text), ['avant le verrouillage']);
      expect(mesh.displayName, 'Alex');
      // Les clés rechargées fonctionnent : un message de Blan arrive.
      await blan.mesh.sendMessage(blan.mesh.groups.single.id, 'après');
      expect(mesh.messagesOf(id).map((m) => m.text), ['avant le verrouillage', 'après']);
      mesh.stop();
    });

    test('verrouillé, le téléphone ne reçoit ni ne relaie plus rien', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      await join(blan, invite);

      alex.mesh.stop();

      await blan.mesh.sendMessage(blan.mesh.groups.single.id, 'personne ne répond');
      expect(alex.mesh.stats.received, 0);
      expect(blan.mesh.neighborCount, 0);
    });

    test('un coffre leurre n\'a ni groupe ni radio', () async {
      final dir = Directory.systemTemp.createTempSync('cortege_decoy');
      dirs.add(dir);
      final store = VaultStore(
        crypto: vaultCrypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      );
      (await store.create(pin: '483920', duressPin: '715204')).lock();
      final decoy = (await store.unlock('715204'))!;
      final transport = FakeTransport(air, 'leurre');
      final mesh = MeshController(
        crypto: crypto,
        session: decoy,
        transport: transport,
        now: () => clock,
        jitter: false,
      );
      await mesh.start();

      expect(mesh.groups, isEmpty);
      expect(transport.running, isFalse);
      mesh.stop();
    });
  });

  group('effacement automatique', () {
    test('messages, groupes, clés et secret d\'événement partent après la durée', () async {
      final alex = await phone('Alex');
      final invite = await alex.mesh.createGroup('Équipe');
      final blan = await phone('Blan');
      await join(blan, invite);
      final id = alex.mesh.groups.single.id;
      await alex.mesh.sendMessage(id, 'éphémère');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final eraser = AutoEraser(
        alex.session,
        now: () => clock,
        onGroupsRemoved: () => alex.mesh.reloadGroups(),
      );

      clock = clock.add(const Duration(hours: 23));
      expect(await eraser.sweepNow(), 0);
      expect(alex.mesh.messagesOf(id), hasLength(1));

      clock = clock.add(const Duration(hours: 2));
      expect(await eraser.sweepNow(), greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(alex.session.state.records, isEmpty);
      expect(alex.session.state.groups, isEmpty);
      expect(alex.session.state.eventSecret, isNull);
      expect(alex.mesh.groups, isEmpty);
      expect(alex.mesh.status, MeshStatus.stopped);
      expect(alex.transport.running, isFalse);
    });

    test('un groupe actif n\'est pas effacé', () async {
      final alex = await phone('Alex');
      await alex.mesh.createGroup('Équipe');
      final id = alex.mesh.groups.single.id;
      final eraser = AutoEraser(alex.session, now: () => clock);

      for (var hour = 0; hour < 5; hour++) {
        clock = clock.add(const Duration(hours: 10));
        await alex.mesh.sendMessage(id, 'toujours là $hour');
        await eraser.sweepNow();
      }
      // 50 heures plus tard : le groupe a vécu parce qu'on y écrit.
      expect(alex.session.state.groups, hasLength(1));
      expect(alex.session.state.eventSecret, isNotNull);
    });

    test('les groupes effacés ne sont plus rechargés à la réouverture', () async {
      final alex = await phone('Alex');
      await alex.mesh.createGroup('Équipe');
      alex.mesh.stop();
      clock = clock.add(const Duration(hours: 30));
      await AutoEraser(alex.session, now: () => clock).sweepNow();
      alex.session.lock();

      final reopened = (await alex.store.unlock(alex.pin))!;
      final mesh = MeshController(
        crypto: crypto,
        session: reopened,
        transport: alex.transport,
        now: () => clock,
        jitter: false,
      );
      await mesh.start();
      expect(mesh.groups, isEmpty);
      expect(reopened.state.eventSecret, isNull);
      mesh.stop();
    });
  });
}
