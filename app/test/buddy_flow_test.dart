import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/buddy_service.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/rig.dart';

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

  /// A crée le binôme, B le rejoint puis A scanne le code de retour de B.
  Future<String> pair(Rig a, Rig b) async {
    final invite = await a.mesh.buddies.create();
    final idA = a.mesh.buddies.infos.single.id;
    final joined = await b.mesh.buddies.accept(BuddyInvite.decode(invite.encode()));
    expect(joined.outcome, BuddyScanOutcome.joined);
    final back = b.mesh.buddies.inviteFor(joined.buddyId);
    final added = await a.mesh.buddies.accept(BuddyInvite.decode(back.encode()));
    expect(added.outcome, BuddyScanOutcome.added);
    return idA;
  }

  group('appairage', () {
    test('deux proches, un scan dans chaque sens', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');

      await pair(alex, blan);

      expect(alex.mesh.buddies.infos.single.others.map((p) => p.name), ['Blan']);
      expect(blan.mesh.buddies.infos.single.others.map((p) => p.name), ['Alex']);
      expect(alex.mesh.status, MeshStatus.running);
      expect(blan.mesh.status, MeshStatus.running);
      expect(alex.session.state.eventSecret, blan.session.state.eventSecret);
    });

    test('il faut un pseudo pour créer ou rejoindre', () async {
      final sans = await rigs.create('Sans', named: false);
      expect(() => sans.mesh.buddies.create(), throwsA(isA<NeedsDisplayNameException>()));

      final alex = await rigs.create('Alex');
      final invite = await alex.mesh.buddies.create();
      expect(
        () => sans.mesh.buddies.accept(BuddyInvite.decode(invite.encode())),
        throwsA(isA<NeedsDisplayNameException>()),
      );
    });

    test('scanner son propre code ou deux fois le même ne change rien', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final own = await alex.mesh.buddies.create();
      final id = alex.mesh.buddies.infos.single.id;

      final self = await alex.mesh.buddies.accept(BuddyInvite.decode(own.encode()));
      expect(self.outcome, BuddyScanOutcome.ownCode);

      final joined = await blan.mesh.buddies.accept(BuddyInvite.decode(own.encode()));
      final back = BuddyInvite.decode(blan.mesh.buddies.inviteFor(joined.buddyId).encode());
      await alex.mesh.buddies.accept(back);
      final again = await alex.mesh.buddies.accept(back);

      expect(again.outcome, BuddyScanOutcome.alreadyKnown);
      expect(alex.mesh.buddies.infos.single.others, hasLength(1));
      expect(alex.mesh.buddies.infos.single.id, id);
    });

    test('un code d\'un autre événement est refusé', () async {
      final alex = await rigs.create('Alex');
      final other = await rigs.create('Autre');
      await alex.mesh.createGroup('Équipe');
      final foreign = await other.mesh.buddies.create();

      expect(
        () => alex.mesh.buddies.accept(BuddyInvite.decode(foreign.encode())),
        throwsA(isA<DifferentEventException>()),
      );
    });

    test('à trois : le troisième ne scanne qu\'un proche, les autres le connaissent', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final cleo = await rigs.create('Cléo');
      await pair(alex, blan);

      // Cléo et Alex se scannent. Blan et Cléo ne se scannent jamais.
      final inviteA = alex.mesh.buddies.inviteFor(alex.mesh.buddies.infos.single.id);
      final joined = await cleo.mesh.buddies.accept(BuddyInvite.decode(inviteA.encode()));
      final back = cleo.mesh.buddies.inviteFor(joined.buddyId);
      await alex.mesh.buddies.accept(BuddyInvite.decode(back.encode()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        blan.mesh.buddies.infos.single.others.map((p) => p.name).toSet(),
        {'Alex', 'Cléo'},
        reason: 'Blan apprend Cléo par Alex',
      );
      expect(
        cleo.mesh.buddies.infos.single.others.map((p) => p.name).toSet(),
        {'Alex', 'Blan'},
        reason: 'Cléo apprend Blan par Alex',
      );

      // Et ils se lisent : un check-in de Cléo arrive chez Blan.
      await cleo.mesh.buddies.checkIn(cleo.mesh.buddies.infos.single.id);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final cleoForBlan =
          blan.mesh.buddies.infos.single.others.firstWhere((p) => p.name == 'Cléo');
      expect(cleoForBlan.lastHeard, isNotNull);
    });

    test('un cinquième est refusé', () async {
      final people = [for (var i = 0; i < 5; i++) await rigs.create('P$i')];
      await pair(people[0], people[1]);
      for (final index in [2, 3]) {
        final host = people[0].mesh.buddies;
        final invite = host.inviteFor(host.infos.single.id);
        final joined = await people[index].mesh.buddies.accept(BuddyInvite.decode(invite.encode()));
        final back = people[index].mesh.buddies.inviteFor(joined.buddyId);
        await host.accept(BuddyInvite.decode(back.encode()));
      }
      expect(people[0].mesh.buddies.infos.single.others, hasLength(3));

      final host = people[0].mesh.buddies;
      final invite = host.inviteFor(host.infos.single.id);
      final late = await people[4].mesh.buddies.accept(BuddyInvite.decode(invite.encode()));
      final back = people[4].mesh.buddies.inviteFor(late.buddyId);
      expect(
        () => host.accept(BuddyInvite.decode(back.encode())),
        throwsA(isA<BuddyFullException>()),
      );
    });

    test('quitter un binôme efface ses clés et éteint la radio', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      await pair(alex, blan);

      await alex.mesh.buddies.leave(alex.mesh.buddies.infos.single.id);

      expect(alex.mesh.buddies.infos, isEmpty);
      expect(alex.session.state.buddies, isEmpty);
      expect(
        alex.session.state.eventSecret,
        isNull,
        reason: "plus de groupe ni de binôme : l'événement est fini",
      );
      expect(alex.mesh.status, MeshStatus.stopped);
    });
  });

  group('check-in et silence', () {
    test('un check-in arrive et marque la personne comme présente', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final id = await pair(alex, blan);

      await alex.mesh.buddies.checkIn(id);

      final person = blan.mesh.buddies.infos.single.others.single;
      expect(person.name, 'Alex');
      expect(person.lastHeard, clock);
      expect(person.silent, isFalse);
    });

    test('check-ins automatiques à l\'intervalle choisi', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      alex.session.state.checkInEvery = const Duration(milliseconds: 80);
      blan.session.state.checkInEvery = const Duration(milliseconds: 80);
      await pair(alex, blan);
      alex.mesh.refreshSettings();
      blan.mesh.refreshSettings();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(alex.mesh.buddies.infos.single.others.single.lastHeard, isNotNull);
      expect(blan.mesh.buddies.infos.single.others.single.lastHeard, isNotNull);
      expect(blan.session.state.buddies.single.members.single.nextIndex, greaterThan(2));
    });

    test('quelqu\'un qui se tait déclenche une alerte une seule fois, puis revient', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final id = await pair(alex, blan);
      await alex.mesh.buddies.checkIn(id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final events = <BuddyAlert>[];
      blan.mesh.buddies.alerts.listen(events.add);

      // Plus rien d'Alex (son téléphone ne répond plus) pendant bien plus de
      // deux intervalles de 5 minutes.
      alex.mesh.buddies.stopTimers();
      clock = clock.add(const Duration(minutes: 25));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(blan.mesh.buddies.infos.single.hasSilent, isTrue);
      expect(events.where((e) => e.silent), hasLength(1), reason: 'prévenu une fois, pas en boucle');
      expect(blan.signal.urgentCount, 1);

      // Alex redonne signe de vie.
      await alex.mesh.buddies.checkIn(id);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(blan.mesh.buddies.infos.single.hasSilent, isFalse);
      expect(events.last.silent, isFalse);
    });

    test('pas d\'alerte tant que le délai n\'est pas dépassé', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final id = await pair(alex, blan);
      await alex.mesh.buddies.checkIn(id);

      clock = clock.add(const Duration(minutes: 9));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(blan.mesh.buddies.infos.single.hasSilent, isFalse);
      expect(blan.signal.urgentCount, 0);
    });

    test('quelqu\'un qui ne donne aucun signe depuis l\'appairage finit par être signalé', () async {
      // Alex n'envoie aucun check-in automatique après l'appairage.
      final alex = await rigs.create('Alex', firstCheckInDelay: const Duration(hours: 1));
      final blan = await rigs.create('Blan');
      await pair(alex, blan);

      clock = clock.add(const Duration(minutes: 30));

      expect(blan.mesh.buddies.infos.single.others.single.silent, isTrue);
    });
  });

  group('verrouillage et effacement', () {
    test('le binôme et sa chaîne de clés survivent à un verrouillage complet', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      final id = await pair(alex, blan);
      await alex.mesh.buddies.checkIn(id);
      await alex.mesh.buddies.checkIn(id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final blanAgain = await rigs.reopen(blan);

      expect(blanAgain.mesh.buddies.infos.single.others.single.name, 'Alex');
      // La chaîne a été rechargée à la bonne position : un nouveau message passe.
      await alex.mesh.buddies.checkIn(id);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(blanAgain.mesh.buddies.infos.single.others.single.lastHeard, isNotNull);
    });

    test('un binôme sans activité pendant la durée d\'effacement disparaît avec l\'événement', () async {
      final alex = await rigs.create('Alex');
      final blan = await rigs.create('Blan');
      await pair(alex, blan);
      alex.mesh.buddies.stopTimers();

      clock = clock.add(const Duration(hours: 25));
      final eraser = AutoEraser(
        alex.session,
        now: () => clock,
        onGroupsRemoved: () => alex.mesh.reloadGroups(),
      );
      await eraser.sweepNow();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(alex.session.state.buddies, isEmpty);
      expect(alex.session.state.eventSecret, isNull);
      expect(alex.mesh.status, MeshStatus.stopped);
    });

    test('le code porte la clé des medics quand on la connaît', () async {
      final alex = await rigs.create('Alex');
      await alex.mesh.medic.createChannel();
      await alex.mesh.buddies.create();
      final invite = alex.mesh.buddies.inviteFor(alex.mesh.buddies.infos.single.id);

      final decoded = BuddyInvite.decode(invite.encode());
      expect(decoded.medicPublicKey, alex.session.state.medicPublicKey);

      final blan = await rigs.create('Blan');
      await blan.mesh.buddies.accept(decoded);
      expect(blan.mesh.medic.hasChannel, isTrue);
      expect(blan.mesh.medic.isMedic, isFalse, reason: 'il peut alerter, pas lire les alertes');
    });
  });
}
