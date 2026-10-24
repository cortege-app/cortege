import 'dart:convert';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/medic_invite.dart';
import 'package:cortege/mesh/medic_service.dart';
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

  const reporterAt = GeoPoint(48.857133, 2.351357, 12);
  const medicAt = GeoPoint(48.8602, 2.3470, 8);

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
    rigs = RigFactory(vaultCrypto, air, () => clock);
  });

  tearDown(() => rigs.close());

  /// Un événement avec un medic (qui a créé le canal et un groupe), un
  /// signaleur et un voisin qui ne fait que relayer, tous dans le même groupe.
  Future<({Rig medic, Rig reporter, Rig bystander})> scene() async {
    final medic = await rigs.create('Mel', at: medicAt);
    final reporter = await rigs.create('Rémi', at: reporterAt);
    final bystander = await rigs.create('Zoé');
    await medic.mesh.medic.createChannel();
    final invite = await medic.mesh.createGroup('Place');
    await reporter.mesh.joinGroup(invite);
    await bystander.mesh.joinGroup(invite);
    return (medic: medic, reporter: reporter, bystander: bystander);
  }

  group('le canal des medics', () {
    test('un medic crée le canal, un autre le rejoint par QR', () async {
      final mel = await rigs.create('Mel');
      final invite = await mel.mesh.medic.createChannel();
      expect(mel.mesh.medic.isMedic, isTrue);
      expect(mel.mesh.medic.hasChannel, isTrue);
      expect(mel.mesh.status, MeshStatus.running, reason: 'un medic seul écoute déjà');

      final noa = await rigs.create('Noa');
      await noa.mesh.medic.join(MedicInvite.decode(invite.encode()));
      expect(noa.mesh.medic.isMedic, isTrue);
      expect(noa.session.state.eventSecret, mel.session.state.eventSecret);
    });

    test('l\'invitation de groupe donne la clé publique, pas la clé secrète', () async {
      final s = await scene();
      expect(s.reporter.mesh.medic.hasChannel, isTrue);
      expect(s.reporter.mesh.medic.isMedic, isFalse);
      expect(s.reporter.session.state.medicSecretKey, isNull);
      expect(s.bystander.session.state.medicSecretKey, isNull);
    });

    test('un code de medic d\'un autre événement est refusé', () async {
      final mel = await rigs.create('Mel');
      final other = await rigs.create('Autre');
      await mel.mesh.createGroup('Équipe');
      final foreign = await other.mesh.medic.createChannel();
      expect(
        () => mel.mesh.medic.join(MedicInvite.decode(foreign.encode())),
        throwsA(isA<DifferentEventException>()),
      );
    });

    test('quitter le canal oublie les clés', () async {
      final mel = await rigs.create('Mel');
      await mel.mesh.medic.createChannel();
      await mel.mesh.medic.leave();
      expect(mel.mesh.medic.hasChannel, isFalse);
      expect(mel.session.state.medicSecretKey, isNull);
    });

    test('désactiver le rôle arrête la lecture des alertes', () async {
      final s = await scene();
      await s.medic.mesh.medic.setActive(false);
      await s.reporter.mesh.medic.report(AlertKind.injury);
      expect(s.medic.mesh.medic.alertsForMedic, isEmpty);

      await s.medic.mesh.medic.setActive(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      clock = clock.add(const Duration(minutes: 1));
      await s.reporter.mesh.medic.report(AlertKind.faint);
      expect(s.medic.mesh.medic.alertsForMedic.map((a) => a.kind), [AlertKind.faint]);
    });
  });

  group('signaler un blessé', () {
    test('l\'alerte arrive aux medics, avec une position floue', () async {
      final s = await scene();

      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);

      final alerts = s.medic.mesh.medic.alertsForMedic;
      expect(alerts, hasLength(1));
      expect(alerts.single.kind, AlertKind.injury);
      expect(alerts.single.id, sent.id);
      final coarse = alerts.single.coarse!;
      expect((coarse.lat / coarseStepDegrees - (coarse.lat / coarseStepDegrees).round()).abs(), lessThan(1e-6));
      expect((coarse.lat - reporterAt.lat).abs(), lessThanOrEqualTo(0.0011));
      expect((coarse.lon - reporterAt.lon).abs(), lessThanOrEqualTo(0.0011));
      expect(coarse, isNot(reporterAt), reason: 'jamais la position exacte');
      expect(s.medic.signal.urgentCount, 1);
      expect(s.reporter.mesh.medic.sentAlerts.single.hadPosition, isTrue);
    });

    test('un voisin qui n\'est pas medic relaie sans rien lire', () async {
      final s = await scene();
      await s.reporter.mesh.medic.report(AlertKind.gas);

      expect(s.bystander.mesh.medic.alertsForMedic, isEmpty);
      expect(s.bystander.signal.urgentCount, 0);
      expect(s.bystander.mesh.stats.relayed, greaterThan(0));
    });

    test('sans position, l\'alerte part quand même', () async {
      final s = await scene();
      s.reporter.location.point = null;

      await s.reporter.mesh.medic.report(AlertKind.faint);

      final alert = s.medic.mesh.medic.alertsForMedic.single;
      expect(alert.coarse, isNull);
      expect(s.reporter.mesh.medic.sentAlerts.single.hadPosition, isFalse);
    });

    test('sans canal des medics connu, on le dit', () async {
      final seul = await rigs.create('Seul');
      await seul.mesh.createGroup('Sans medic');
      expect(
        () => seul.mesh.medic.report(AlertKind.injury),
        throwsA(isA<NoMedicChannelException>()),
      );
    });

    test('un double appui ne lance qu\'une alerte', () async {
      final s = await scene();
      final first = await s.reporter.mesh.medic.report(AlertKind.injury);
      final second = await s.reporter.mesh.medic.report(AlertKind.injury);

      expect(second.id, first.id);
      expect(s.medic.mesh.medic.alertsForMedic, hasLength(1));
    });

    test('plusieurs medics reçoivent la même alerte', () async {
      final s = await scene();
      final noa = await rigs.create('Noa');
      final invite = s.medic.mesh.medic.invite()!;
      await noa.mesh.medic.join(MedicInvite.decode(invite.encode()));
      await noa.mesh.joinGroup(s.medic.mesh.inviteFor(s.medic.mesh.groups.single.id));

      await s.reporter.mesh.medic.report(AlertKind.injury);

      expect(s.medic.mesh.medic.alertsForMedic, hasLength(1));
      expect(noa.mesh.medic.alertsForMedic, hasLength(1));
    });

    test('on peut retirer une alerte lancée par erreur', () async {
      final s = await scene();
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);
      s.reporter.mesh.medic.cancel(sent.id);

      expect(s.reporter.mesh.medic.sentAlerts, isEmpty);
      // Le medic répond quand même : la personne n'écoute plus, rien ne revient.
      await s.medic.mesh.medic.respond(sent.id, medicName: 'Mel');
      expect(s.reporter.mesh.medic.sentAlerts, isEmpty);
    });
  });

  group('répondre et partager la position précise', () {
    test('le medic répond, la personne voit son nom', () async {
      final s = await scene();
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);

      await s.medic.mesh.medic.respond(sent.id, medicName: 'Mel');

      final mine = s.reporter.mesh.medic.sentAlerts.single;
      expect(mine.responders.map((r) => r.name), ['Mel']);
      expect(s.reporter.signal.noticeCount, 1);
      expect(s.medic.mesh.medic.alertsForMedic.single.answered, isTrue);
    });

    test('la position précise ne va qu\'au medic choisi', () async {
      final s = await scene();
      final noa = await rigs.create('Noa');
      final invite = s.medic.mesh.medic.invite()!;
      await noa.mesh.medic.join(MedicInvite.decode(invite.encode()));
      await noa.mesh.joinGroup(s.medic.mesh.inviteFor(s.medic.mesh.groups.single.id));
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);
      await s.medic.mesh.medic.respond(sent.id, medicName: 'Mel');

      final responder = s.reporter.mesh.medic.sentAlerts.single.responders.single;
      expect(await s.reporter.mesh.medic.sharePosition(sent.id, responder), isTrue);

      final precise = s.medic.mesh.medic.alertsForMedic.single.precise!;
      expect((precise.lat - reporterAt.lat).abs(), lessThan(1e-6));
      expect((precise.lon - reporterAt.lon).abs(), lessThan(1e-6));
      expect(responder.positionShared, isTrue);
      expect(noa.mesh.medic.alertsForMedic.single.precise, isNull,
          reason: 'Noa n\'a pas répondu, elle ne voit pas la position précise');
    });

    test('sans position disponible, rien n\'est partagé', () async {
      final s = await scene();
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);
      await s.medic.mesh.medic.respond(sent.id, medicName: 'Mel');
      s.reporter.location.point = null;

      final responder = s.reporter.mesh.medic.sentAlerts.single.responders.single;
      expect(await s.reporter.mesh.medic.sharePosition(sent.id, responder), isFalse);
      expect(s.medic.mesh.medic.alertsForMedic.single.precise, isNull);
    });

    test('la distance et le sens se calculent depuis la position du medic', () async {
      final s = await scene();
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);
      final alert = s.medic.mesh.medic.alertsForMedic.single;
      expect(alert.id, sent.id);

      final text = describeOffset(medicAt, alert.coarse!);
      expect(text, anyOf(contains('m vers le'), contains('km vers le'), 'tout près'));
    });
  });

  group('vie privée', () {
    test('aucune position n\'est écrite dans le coffre', () async {
      final s = await scene();
      final sent = await s.reporter.mesh.medic.report(AlertKind.injury);
      await s.medic.mesh.medic.respond(sent.id, medicName: 'Mel');
      await s.reporter.mesh.medic.sharePosition(
        sent.id,
        s.reporter.mesh.medic.sentAlerts.single.responders.single,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      for (final rig in [s.medic, s.reporter, s.bystander]) {
        final json = jsonEncode(rig.session.state.toJson());
        expect(json.contains('857133'), isFalse, reason: '${rig.name} : latitude exacte');
        expect(json.contains('351357'), isFalse, reason: '${rig.name} : longitude exacte');
        expect(json.contains('48.858'), isFalse, reason: '${rig.name} : latitude floue');
      }
    });

    test('les alertes disparaissent au verrouillage complet', () async {
      final s = await scene();
      await s.reporter.mesh.medic.report(AlertKind.injury);
      expect(s.medic.mesh.medic.alertsForMedic, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final reopened = await rigs.reopen(s.medic);

      expect(reopened.mesh.medic.alertsForMedic, isEmpty);
      expect(reopened.mesh.medic.isMedic, isTrue, reason: 'le rôle, lui, est gardé dans le coffre');
    });

    test('les alertes trop anciennes sont oubliées', () async {
      final s = await scene();
      await s.reporter.mesh.medic.report(AlertKind.injury);

      clock = clock.add(const Duration(hours: 3));

      expect(s.medic.mesh.medic.alertsForMedic, isEmpty);
      expect(s.reporter.mesh.medic.sentAlerts, isEmpty);
    });

    test('les clés du canal partent avec l\'événement, après la durée d\'effacement', () async {
      final mel = await rigs.create('Mel');
      await mel.mesh.medic.createChannel();
      final eraser = AutoEraser(
        mel.session,
        now: () => clock,
        onGroupsRemoved: () => mel.mesh.reloadGroups(),
      );

      clock = clock.add(const Duration(hours: 23));
      await eraser.sweepNow();
      expect(mel.mesh.medic.hasChannel, isTrue, reason: 'pas encore 24 heures');

      clock = clock.add(const Duration(hours: 2));
      await eraser.sweepNow();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(mel.session.state.medicPublicKey, isNull);
      expect(mel.session.state.medicSecretKey, isNull);
      expect(mel.session.state.eventSecret, isNull);
    });

    test('un medic qui n\'a pas de groupe garde son canal tant qu\'il sert', () async {
      final mel = await rigs.create('Mel');
      await mel.mesh.medic.createChannel();
      final eraser = AutoEraser(mel.session, now: () => clock);

      clock = clock.add(const Duration(hours: 10));
      await eraser.sweepNow();

      expect(mel.mesh.medic.isMedic, isTrue);
    });
  });
}
