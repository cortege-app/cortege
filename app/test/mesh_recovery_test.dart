import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/rig.dart';

Future<void> settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

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

  group('Bluetooth coupé en cours d\'usage', () {
    test('la radio le signale, puis repart toute seule quand il revient', () async {
      final alex = await rigs.create('Alex', retryInterval: const Duration(milliseconds: 40));
      final blan = await rigs.create('Blan');
      final invite = await alex.mesh.createGroup('Place');
      await blan.mesh.joinGroup(invite);
      expect(alex.mesh.neighborCount, 1);

      alex.transport.unavailable = true;
      alex.transport.failNow('Bluetooth éteint');
      await settle();

      expect(alex.mesh.status, MeshStatus.unavailable);
      expect(alex.mesh.statusDetail, 'Bluetooth éteint');
      expect(alex.mesh.neighborCount, 0, reason: 'les liens de la radio morte ne comptent plus');
      expect(blan.mesh.neighborCount, 0);

      alex.transport.unavailable = false;
      await settle(200);

      expect(alex.mesh.status, MeshStatus.running);
      expect(alex.mesh.neighborCount, 1);
      expect(blan.mesh.neighborCount, 1);

      await blan.mesh.sendMessage(blan.mesh.groups.single.id, 'tu me reçois ?');
      await settle();
      expect(
        alex.mesh.messagesOf(alex.mesh.groups.single.id).map((m) => m.text),
        contains('tu me reçois ?'),
      );
    });

    test('une permission retirée n\'est pas redemandée en boucle', () async {
      final alex = await rigs.create('Alex', retryInterval: const Duration(milliseconds: 40));
      await alex.mesh.createGroup('Place');
      final starts = alex.transport.startCount;

      alex.transport.failNow('Permission Bluetooth refusée', retryable: false);
      await settle(200);

      expect(alex.mesh.status, MeshStatus.unavailable);
      expect(alex.transport.startCount, starts);
    });

    test('les minuteries du binôme repartent avec la radio', () async {
      final alex = await rigs.create('Alex', retryInterval: const Duration(milliseconds: 40));
      final blan = await rigs.create('Blan');
      final invite = await alex.mesh.buddies.create();
      final joined = await blan.mesh.buddies.accept(invite);
      await alex.mesh.buddies.accept(blan.mesh.buddies.inviteFor(joined.buddyId));
      await settle();

      alex.transport.failNow('Bluetooth éteint');
      await settle(200);
      expect(alex.mesh.status, MeshStatus.running);

      final before = blan.mesh.buddies.infos.single.others.single.lastHeard;
      clock = clock.add(const Duration(minutes: 1));
      await alex.mesh.buddies.checkIn(alex.mesh.buddies.infos.single.id);
      await settle();
      final after = blan.mesh.buddies.infos.single.others.single.lastHeard;
      expect(after, isNot(before));
    });
  });
}
