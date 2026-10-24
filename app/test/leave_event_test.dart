import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/rig.dart';

Future<void> settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Un téléphone n'est que dans un événement à la fois. Pour en rejoindre un
/// autre, on quitte l'actuel d'un geste, avec tout ce qui s'y rattache.
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

  test('quitter l\'événement vide groupes, messages, binômes et canal des medics', () async {
    final alex = await rigs.create('Alex');
    final blan = await rigs.create('Blan');
    final invite = await alex.mesh.createGroup('Place');
    await blan.mesh.joinGroup(invite);
    await alex.mesh.sendMessage(alex.mesh.groups.single.id, 'bonjour');
    await alex.mesh.buddies.create();
    await alex.mesh.medic.createChannel();
    await settle();
    expect(alex.mesh.status, MeshStatus.running);

    await alex.mesh.leaveEvent();

    expect(alex.mesh.groups, isEmpty);
    expect(alex.mesh.buddies.infos, isEmpty);
    expect(alex.mesh.medic.hasChannel, isFalse);
    expect(alex.mesh.medic.isMedic, isFalse);
    expect(alex.session.state.eventSecret, isNull);
    expect(alex.session.state.groups, isEmpty);
    expect(alex.session.state.buddies, isEmpty);
    expect(alex.session.state.records.where((r) => r.kind == MeshController.kind), isEmpty);
    expect(alex.mesh.status, MeshStatus.stopped, reason: 'plus d\'événement, plus de radio');
    expect(alex.mesh.neighborCount, 0);
    expect(alex.session.state.displayName, 'Alex', reason: 'le pseudo reste');
  });

  test('après avoir quitté, on peut rejoindre un autre événement', () async {
    final alex = await rigs.create('Alex');
    final blan = await rigs.create('Blan');
    final other = await rigs.create('Cleo');
    await alex.mesh.createGroup('Place');
    final binome = await other.mesh.buddies.create();

    expect(
      () => alex.mesh.buddies.accept(BuddyInvite.decode(binome.encode())),
      throwsA(isA<DifferentEventException>()),
    );

    await alex.mesh.leaveEvent();
    final result = await alex.mesh.buddies.accept(BuddyInvite.decode(binome.encode()));

    expect(result.outcome.name, 'joined');
    expect(alex.session.state.eventSecret, other.session.state.eventSecret);
    expect(blan.session.state.eventSecret, isNull);
    await settle();
    expect(alex.mesh.status, MeshStatus.running);
  });

  test('les minuteries du binôme et les alertes n\'y survivent pas', () async {
    final alex = await rigs.create('Alex');
    await alex.mesh.medic.createChannel();
    await alex.mesh.medic.report(AlertKind.injury);
    expect(alex.mesh.medic.sentAlerts, hasLength(1));

    await alex.mesh.leaveEvent();

    expect(alex.mesh.medic.sentAlerts, isEmpty);
    expect(alex.mesh.medic.alertsForMedic, isEmpty);
  });

  test('quitter le dernier binôme termine l\'événement et oublie la clé des medics', () async {
    final alex = await rigs.create('Alex');
    final mel = await rigs.create('Mel');
    final invite = await alex.mesh.buddies.create();
    final joined = await mel.mesh.buddies.accept(invite);
    await alex.mesh.buddies.accept(mel.mesh.buddies.inviteFor(joined.buddyId));
    await mel.mesh.medic.createChannel();
    await settle();
    expect(alex.mesh.medic.hasChannel, isTrue);

    await alex.mesh.buddies.leave(alex.mesh.buddies.infos.single.id);

    expect(alex.mesh.buddies.infos, isEmpty);
    expect(alex.session.state.eventSecret, isNull);
    expect(alex.mesh.medic.hasChannel, isFalse, reason: 'plus de boutons à signaler');
    expect(alex.mesh.status, MeshStatus.stopped);
  });

  test('avec un groupe restant, quitter le binôme garde l\'événement', () async {
    final alex = await rigs.create('Alex');
    await alex.mesh.createGroup('Place');
    await alex.mesh.buddies.create();

    await alex.mesh.buddies.leave(alex.mesh.buddies.infos.single.id);

    expect(alex.session.state.eventSecret, isNotNull);
    expect(alex.mesh.status, MeshStatus.running);
  });
}
