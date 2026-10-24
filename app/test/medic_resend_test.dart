import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/medic_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';
import 'support/rig.dart';

Future<void> settle([int milliseconds = 80]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Le maillage n'a ni stockage ni accusé de réception : une alerte, une réponse
/// ou une position envoyées pendant que l'autre est hors de portée seraient
/// perdues. On les rejoue donc, et on vérifie que les répétitions ne
/// multiplient ni les alertes ni les vibrations.
void main() {
  late VaultCrypto vaultCrypto;
  late FakeAir air;
  late DateTime clock;
  late RigFactory rigs;

  const reporterAt = GeoPoint(48.857133, 2.351357, 12);
  const medicAt = GeoPoint(48.8602, 2.3470, 8);
  final quick = List.filled(12, const Duration(milliseconds: 30));

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
  });

  setUp(() {
    air = FakeAir();
    clock = DateTime.utc(2026, 10, 18, 12);
    rigs = RigFactory(vaultCrypto, air, () => clock);
  });

  tearDown(() => rigs.close());

  Future<({Rig medic, Rig reporter})> scene() async {
    final medic = await rigs.create(
      'Mel',
      at: medicAt,
      retryInterval: const Duration(milliseconds: 30),
      medicResendDelays: quick,
    );
    final reporter = await rigs.create(
      'Remi',
      at: reporterAt,
      retryInterval: const Duration(milliseconds: 30),
      medicResendDelays: quick,
    );
    await medic.mesh.medic.createChannel();
    final invite = await medic.mesh.createGroup('Place');
    await reporter.mesh.joinGroup(invite);
    return (medic: medic, reporter: reporter);
  }

  Future<void> goOffAir(Rig rig) async {
    rig.transport.unavailable = true;
    rig.transport.failNow('Bluetooth éteint');
    await settle();
  }

  Future<void> backOnAir(Rig rig, [int wait = 300]) async {
    rig.transport.unavailable = false;
    await settle(wait);
  }

  test('une alerte lancée hors de portée arrive quand le medic revient, une seule fois', () async {
    final s = await scene();
    await goOffAir(s.medic);

    await s.reporter.mesh.medic.report(AlertKind.injury);
    await settle(120);
    expect(s.medic.mesh.medic.alertsForMedic, isEmpty);

    await backOnAir(s.medic);

    expect(s.medic.mesh.medic.alertsForMedic, hasLength(1));
    expect(s.medic.signal.urgentCount, 1, reason: 'les renvois ne font pas revibrer');
  });

  test('le renvoi de l\'alerte s\'arrête dès qu\'un medic répond', () async {
    final s = await scene();
    await s.reporter.mesh.medic.report(AlertKind.faint);
    await settle();
    final alert = s.medic.mesh.medic.alertsForMedic.single;
    await s.medic.mesh.medic.respond(alert.id, medicName: 'Mel');
    await settle();
    expect(s.reporter.mesh.medic.sentAlerts.single.responders, hasLength(1));

    final sent = s.reporter.mesh.stats.sent;
    await settle(250);
    expect(s.reporter.mesh.stats.sent, sent, reason: 'plus de renvoi après la réponse');
  });

  test('une réponse envoyée pendant que la personne est hors de portée la rattrape', () async {
    final s = await scene();
    await s.reporter.mesh.medic.report(AlertKind.injury);
    await settle();
    final alert = s.medic.mesh.medic.alertsForMedic.single;

    await goOffAir(s.reporter);
    await s.medic.mesh.medic.respond(alert.id, medicName: 'Mel');
    await settle(60);
    expect(s.reporter.mesh.medic.sentAlerts.single.responders, isEmpty);

    await backOnAir(s.reporter);

    final responders = s.reporter.mesh.medic.sentAlerts.single.responders;
    expect(responders, hasLength(1));
    expect(responders.single.name, 'Mel');
    expect(s.reporter.signal.noticeCount, 1, reason: 'une seule notification pour la réponse');
  });

  test('la position précise est rejouée sans prévenir le medic à chaque fois', () async {
    final s = await scene();
    await s.reporter.mesh.medic.report(AlertKind.injury);
    await settle();
    final alert = s.medic.mesh.medic.alertsForMedic.single;
    await s.medic.mesh.medic.respond(alert.id, medicName: 'Mel');
    await settle();
    final sentAlert = s.reporter.mesh.medic.sentAlerts.single;

    await goOffAir(s.medic);
    final shared = await s.reporter.mesh.medic.sharePosition(sentAlert.id, sentAlert.responders.single);
    expect(shared, isTrue);
    await settle(60);
    expect(s.medic.mesh.medic.alertsForMedic.single.precise, isNull);

    await backOnAir(s.medic, 400);

    final precise = s.medic.mesh.medic.alertsForMedic.single.precise;
    expect(precise, isNotNull);
    expect(precise!.lat, closeTo(reporterAt.lat, 0.00001));
    expect(s.medic.signal.noticeCount, 1, reason: 'la position rejouée ne revibre pas');
  });

  test('retirer l\'alerte arrête les renvois', () async {
    final s = await scene();
    await goOffAir(s.medic);
    final sent = await s.reporter.mesh.medic.report(AlertKind.gas);
    s.reporter.mesh.medic.cancel(sent.id);
    final before = s.reporter.mesh.stats.sent;
    await settle(250);
    expect(s.reporter.mesh.stats.sent, before);
  });
}
