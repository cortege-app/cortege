import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/buddy_service.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/rig.dart';

Future<void> settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// La clé publique du canal des medics passe d'un proche à l'autre dans le
/// binôme, sans qu'il faille refaire un groupe. Elle n'ouvre rien : elle permet
/// seulement d'écrire une alerte.
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

  test('un medic crée le canal : ses proches du binôme le connaissent aussitôt', () async {
    final alex = await rigs.create('Alex');
    final mel = await rigs.create('Mel');
    await pair(alex, mel);
    expect(alex.mesh.medic.hasChannel, isFalse);

    await mel.mesh.medic.createChannel();
    await settle();

    expect(alex.mesh.medic.hasChannel, isTrue);
    expect(alex.mesh.medic.isMedic, isFalse, reason: 'il peut écrire, pas lire');
    expect(alex.session.state.medicPublicKey, mel.session.state.medicPublicKey);
    expect(alex.session.state.medicSecretKey, isNull);

    await alex.mesh.medic.report(AlertKind.injury);
    await settle();
    expect(mel.mesh.medic.alertsForMedic, hasLength(1));
  });

  test('rescanner le code d\'un proche déjà dans le binôme apprend la clé', () async {
    final alex = await rigs.create('Alex');
    final mel = await rigs.create('Mel');
    await pair(alex, mel);

    alex.transport.unavailable = true;
    alex.transport.failNow('Bluetooth éteint');
    await settle();
    await mel.mesh.medic.createChannel();
    await settle();
    expect(alex.mesh.medic.hasChannel, isFalse, reason: 'hors de portée, il n\'a rien reçu');

    final code = mel.mesh.buddies.inviteFor(mel.mesh.buddies.infos.single.id);
    final result = await alex.mesh.buddies.accept(BuddyInvite.decode(code.encode()));

    expect(result.outcome, BuddyScanOutcome.alreadyKnown);
    expect(alex.mesh.medic.hasChannel, isTrue);
  });

  test('une clé déjà connue n\'est jamais remplacée par celle d\'un proche', () async {
    final alex = await rigs.create('Alex');
    final mel = await rigs.create('Mel');
    await alex.mesh.medic.createChannel();
    final alexKey = List<int>.from(alex.session.state.medicPublicKey!);
    await pair(alex, mel);

    await mel.mesh.medic.createChannel();
    await settle();

    expect(alex.session.state.medicPublicKey, alexKey);
  });
}
