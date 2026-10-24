import 'dart:async';
import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/mesh/names.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/memory_hardware.dart';
import 'support/rig.dart';

Future<void> settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Une position qui ne vient jamais : GPS qui n'accroche pas, demande
/// d'autorisation sans réponse.
class _NeverLocation implements LocationProvider {
  @override
  Future<GeoPoint?> current({bool accurate = false}) => Completer<GeoPoint?>().future;

  @override
  Stream<GeoPoint> updates() => const Stream.empty();
}

/// Les défauts trouvés à la revue du code, chacun avec son test.
void main() {
  late VaultCrypto vaultCrypto;
  late FakeAir air;
  late DateTime clock;
  late RigFactory rigs;

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
    rigs = RigFactory(vaultCrypto, air, () => clock);
  });

  tearDown(() => rigs.close());

  Future<String> pair(Rig a, Rig b) async {
    final invite = await a.mesh.buddies.create();
    final idA = a.mesh.buddies.infos.single.id;
    final joined = await b.mesh.buddies.accept(BuddyInvite.decode(invite.encode()));
    final back = b.mesh.buddies.inviteFor(joined.buddyId);
    await a.mesh.buddies.accept(BuddyInvite.decode(back.encode()));
    return idA;
  }

  group('pseudos', () {
    // Les caractères piégés sont construits ici plutôt qu'écrits dans le fichier :
    // un fichier source qui en contiendrait serait lui-même trompeur.
    final reverse = String.fromCharCode(0x202e);
    final isolate = String.fromCharCode(0x2066);
    final popIsolate = String.fromCharCode(0x2069);
    final zeroWidth = String.fromCharCode(0x200b);
    final wordJoiner = String.fromCharCode(0x2060);

    test('les caractères qui retournent le texte ou se cachent sont retirés', () {
      expect(cleanName('Alex'), 'Alex');
      expect(cleanName('Al${reverse}ex'), 'Alex');
      expect(cleanName('A${zeroWidth}lex$wordJoiner'), 'Alex');
      expect(cleanName('${isolate}Alex$popIsolate'), 'Alex');
      expect(cleanName('Al\nex\t'), 'Alex');
      expect(cleanName('Zoé 🙂'), 'Zoé 🙂');
    });

    test('un pseudo qui ne contient que du caché devient un point d\'interrogation', () {
      expect(cleanName('$reverse$zeroWidth'), '?');
      expect(cleanName(''), '', reason: 'un canal sans pseudo reste sans pseudo');
    });

    test('les codes scannés sont nettoyés eux aussi', () async {
      final alex = await rigs.create('Alex');
      alex.session.state.displayName = 'Al${reverse}ex';
      final invite = await alex.mesh.buddies.create();
      expect(BuddyInvite.decode(invite.encode()).name, 'Alex');

      final group = GroupInvite(
        name: 'Pla${reverse}ce',
        groupKey: vaultCrypto.randomBytes(32),
        eventSecret: vaultCrypto.randomBytes(32),
      );
      expect(GroupInvite.decode(group.encode()).name, 'Place');
    });
  });

  group('coffre à taille fixe', () {
    test('un groupe très bavard ne remplit pas le coffre : les plus anciens partent', () async {
      final alex = await rigs.create('Alex');
      await alex.mesh.createGroup('Place');
      final id = alex.mesh.groups.single.id;

      for (var i = 0; i < MeshController.maxStoredMessages + 40; i++) {
        clock = clock.add(const Duration(seconds: 1));
        await alex.mesh.sendMessage(id, 'message numéro $i avec un texte assez long pour peser');
      }

      final texts = alex.mesh.messagesOf(id).map((m) => m.text).toList();
      expect(texts, hasLength(MeshController.maxStoredMessages));
      expect(texts.last, contains('numéro ${MeshController.maxStoredMessages + 39} '));
      expect(texts.any((t) => t.contains('numéro 0 ')), isFalse);

      // Et le coffre s'écrit toujours : on peut le rouvrir.
      await alex.session.save();
      final reopened = await rigs.reopen(alex);
      expect(reopened.mesh.messagesOf(id), hasLength(MeshController.maxStoredMessages));
    });
  });

  group('chaîne de clés du binôme', () {
    test('après une réouverture, nos messages passent même si la dernière écriture est perdue', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final id = await pair(alex, blan);
      final record = alex.session.state.buddies.single;

      // Ce que le coffre contenait avant trois envois...
      final savedKey = List<int>.of(record.sendChainKey);
      final savedIndex = record.sendIndex;
      for (var i = 0; i < 3; i++) {
        await alex.mesh.buddies.checkIn(id);
      }
      await settle();
      expect(blan.mesh.buddies.infos.single.others.single.lastHeard, isNotNull);

      // ... alors que Blan, lui, a déjà avancé. On simule l'appli tuée avant que
      // ces trois écritures soient finies : le coffre revient en arrière.
      record.sendChainKey.setAll(0, savedKey);
      record.sendIndex = savedIndex;
      await alex.session.save();
      await settle();

      final reopened = await rigs.reopen(alex);
      clock = clock.add(const Duration(minutes: 1));
      await reopened.mesh.buddies.checkIn(reopened.mesh.buddies.infos.single.id);
      await settle();

      expect(
        blan.mesh.buddies.infos.single.others.single.lastHeard,
        clock,
        reason: 'Blan lit le nouveau message grâce au saut de numéros',
      );
    });
  });

  group('silence', () {
    test('quand c\'est notre Bluetooth qui est coupé, personne n\'est déclaré muet', () async {
      final alex = await rigs.create(
        'Alex',
        retryInterval: const Duration(milliseconds: 40),
      );
      final blan = await rigs.create('Blan');
      await pair(alex, blan);
      await settle();

      alex.transport.unavailable = true;
      alex.transport.failNow('Bluetooth éteint');
      await settle();
      clock = clock.add(const Duration(minutes: 30));
      alex.mesh.buddies.stopTimers();

      expect(alex.mesh.buddies.infos.single.others.single.silent, isFalse);

      // La radio revient : on laisse à tout le monde le temps de se faire entendre.
      alex.transport.unavailable = false;
      await settle(200);
      expect(alex.mesh.buddies.infos.single.others.single.silent, isFalse);

      clock = clock.add(const Duration(minutes: 30));
      expect(alex.mesh.buddies.infos.single.others.single.silent, isTrue);
    });
  });

  group('effacement automatique', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('cortege_audit'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('un événement qui prend fin tout seul est enregistré et signalé', () async {
      final store = VaultStore(
        crypto: vaultCrypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      );
      final session = await store.create(pin: '483920');
      // Un secret d'événement resté sans groupe ni binôme.
      session.state.eventSecret = vaultCrypto.randomBytes(32);
      session.state.medicPublicKey = vaultCrypto.randomBytes(32);
      await session.save();

      var told = 0;
      final eraser = AutoEraser(
        session,
        now: () => DateTime.now().add(const Duration(days: 2)),
        onGroupsRemoved: () => told++,
      );
      expect(await eraser.sweepNow(), 1);

      expect(told, 1, reason: 'la radio doit en être informée');
      session.lock();
      final reopened = await store.unlock('483920');
      expect(reopened!.state.eventSecret, isNull);
      expect(reopened.state.medicPublicKey, isNull);
      reopened.lock();
    });
  });

  group('alerte', () {
    const here = GeoPoint(48.857, 2.351, 10);

    test('sans position au bout de quelques secondes, l\'alerte part quand même', () async {
      final medic = await rigs.create('Mel');
      final reporter = await rigs.create('Remi', at: here);
      await medic.mesh.medic.createChannel();
      final invite = await medic.mesh.createGroup('Place');
      await reporter.mesh.joinGroup(invite);
      reporter.mesh.medic.location = _NeverLocation();

      final sent = await reporter.mesh.medic
          .report(AlertKind.injury)
          .timeout(const Duration(seconds: 12));
      await settle();

      expect(sent.hadPosition, isFalse);
      expect(medic.mesh.medic.alertsForMedic, hasLength(1));
      expect(medic.mesh.medic.alertsForMedic.single.coarse, isNull);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('signaler, retirer, signaler à nouveau tout de suite ne plante pas', () async {
      final medic = await rigs.create('Mel');
      final reporter = await rigs.create('Remi', at: here);
      await medic.mesh.medic.createChannel();
      final invite = await medic.mesh.createGroup('Place');
      await reporter.mesh.joinGroup(invite);

      final first = await reporter.mesh.medic.report(AlertKind.faint);
      reporter.mesh.medic.cancel(first.id);
      final second = await reporter.mesh.medic.report(AlertKind.faint);

      expect(second.id, isNot(first.id));
      expect(reporter.mesh.medic.sentAlerts, hasLength(1));
    });
  });
}
