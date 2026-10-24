import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/event_file.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:cortege/organizer/organizer_service.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  late Directory dir;
  late VaultSession session;
  late DateTime clock;
  late OrganizerService service;
  late MapReference reference;
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
    reference = MapReference(
      hash: _hex(await crypto.hashFile(fixture)),
      size: fixture.lengthSync(),
      name: 'paris.pmtiles',
    );
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cortege_event');
    clock = DateTime.utc(2026, 10, 20, 12);
    session = await VaultStore(
      crypto: vaultCrypto,
      hardware: MemoryHardwareSecretStore(),
      directory: dir,
      kdf: KdfParams.cheapForTests,
    ).create(pin: '483920');
    service = OrganizerService(
      session: session,
      crypto: crypto,
      mapsDirectory: Directory('${dir.path}/maps'),
      now: () => clock,
    );
  });

  tearDown(() {
    service.dispose();
    session.lock();
    dir.deleteSync(recursive: true);
  });

  Matcher rejected(PacketProblem problem) =>
      throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', problem));

  ({Uint8List publicKey, String Function({DateTime? issued, MapReference? map, String by, String name}) sign})
      organizer() {
    final pair = crypto.newSigningKeyPair();
    return (
      publicKey: pair.publicKey,
      sign: ({issued, map, by = 'Collectif Eau', name = 'Marche du 21 octobre'}) => OrganizerPacket.sign(
            crypto: crypto,
            publicKey: pair.publicKey,
            secretKey: pair.secretKey,
            payload: OrganizerPayload(
              name: name,
              issued: issued ?? clock.subtract(const Duration(hours: 1)),
              expires: clock.add(const Duration(hours: 12)),
              route: const [(48.8566, 2.3522), (48.8600, 2.3600)],
              points: const [OrganizerPoint(kind: PointKind.water, name: 'Fontaine', lat: 48.857, lon: 2.353)],
              map: map,
              organizerName: by,
            ),
          ),
    );
  }

  File packetFile(String text, [String name = 'paquet.cortege']) =>
      File('${dir.path}/$name')..writeAsStringSync(text);

  Future<File> bundleFile(String text, {File? map, String name = 'evenement.cortege'}) async {
    final target = File('${dir.path}/$name');
    await EventFile.write(packet: text, map: map ?? fixture, target: target);
    return target;
  }

  test('un organisateur de confiance : le fichier unique donne l\'événement et sa carte', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final file = await bundleFile(org.sign(map: reference));

    final incoming = await service.inspect(file);
    expect(incoming.trusted, isTrue);
    expect(incoming.knownName, 'Collectif Eau');
    expect(incoming.packetIsNew, isTrue);
    expect(incoming.mapWanted, isTrue);
    expect(incoming.hasMap, isTrue);

    final result = await service.importEvent(incoming);

    expect(result.packetAdded, isTrue);
    expect(result.mapProblem, isNull);
    expect(result.map!.hash, reference.hash);
    expect(service.packets.single.payload.name, 'Marche du 21 octobre');
    final archive = (await service.openMap())!;
    addTearDown(archive.close);
    expect(archive.header.maxZoom, greaterThan(0));
  });

  test('un organisateur inconnu n\'entre qu\'avec un accord explicite', () async {
    final org = organizer();
    final file = await bundleFile(org.sign(map: reference));

    final incoming = await service.inspect(file);
    expect(incoming.trusted, isFalse);
    expect(incoming.packet!.payload.organizerName, 'Collectif Eau');

    await expectLater(service.importEvent(incoming), rejected(PacketProblem.unknownOrganizer));
    expect(service.organizers, isEmpty);
    expect(service.packets, isEmpty);
    expect(service.mapInfo, isNull);

    final result = await service.importEvent(incoming, trustSigner: true);

    expect(service.organizers.single.name, 'Collectif Eau');
    expect(service.isTrusted(org.publicKey), isTrue);
    expect(result.packetAdded, isTrue);
    expect(service.packets, hasLength(1));
    expect(service.mapInfo, isNotNull);
  });

  test('sans nom donné, l\'organisateur est enregistré sous son empreinte', () async {
    final org = organizer();
    final incoming = await service.inspect(packetFile(org.sign(by: '')));

    await service.importEvent(incoming, trustSigner: true);

    expect(service.organizers.single.name, startsWith('Organisateur '));
    expect(service.organizers.single.name, contains(incoming.packet!.fingerprint));
  });

  test('un nom déjà pris par une autre clé est signalé', () async {
    final known = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: known.publicKey));
    final impostor = organizer();

    final incoming = await service.inspect(packetFile(impostor.sign(by: 'collectif eau')));

    expect(incoming.trusted, isFalse);
    expect(incoming.sameNameOtherKey, isTrue);
  });

  test('un signataire de confiance, sous son propre nom, n\'est pas un doublon', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));

    final incoming = await service.inspect(packetFile(org.sign()));

    expect(incoming.sameNameOtherKey, isFalse);
  });

  test('une carte jointe qui n\'est pas celle annoncée est refusée, l\'événement reste', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final altered = File('${dir.path}/altered.pmtiles')..writeAsBytesSync(fixture.readAsBytesSync());
    final bytes = altered.readAsBytesSync();
    bytes[bytes.length - 3] ^= 0xff;
    altered.writeAsBytesSync(bytes);
    final file = await bundleFile(org.sign(map: reference), map: altered);

    final result = await service.importEvent(await service.inspect(file));

    expect(result.packetAdded, isTrue);
    expect(result.mapProblem!.problem, PacketProblem.mapCorrupted);
    expect(result.map, isNull);
    expect(service.packets, hasLength(1));
    expect(service.mapInfo, isNull);
  });

  test('une carte jointe que le paquet n\'annonce pas est ignorée', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final file = await bundleFile(org.sign());

    final result = await service.importEvent(await service.inspect(file));

    expect(result.packetAdded, isTrue);
    expect(result.mapProblem!.problem, PacketProblem.mapNotExpected);
    expect(service.mapInfo, isNull);
  });

  test('le même événement reçu d\'abord seul, puis avec sa carte, ajoute la carte', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final text = org.sign(map: reference);
    await service.importEvent(await service.inspect(packetFile(text)));
    expect(service.mapInfo, isNull);

    final incoming = await service.inspect(await bundleFile(text));
    expect(incoming.packetIsNew, isFalse);
    expect(incoming.mapWanted, isTrue);
    final result = await service.importEvent(incoming);

    expect(result.packetAdded, isFalse);
    expect(result.map!.hash, reference.hash);
    expect(service.packets, hasLength(1));
  });

  test('un fichier qui n\'apporte rien de nouveau est refusé', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final text = org.sign(map: reference);
    await service.importEvent(await service.inspect(await bundleFile(text)));

    await expectLater(service.inspect(await bundleFile(text, name: 'encore.cortege')), rejected(PacketProblem.older));
    await expectLater(service.inspect(packetFile(text)), rejected(PacketProblem.older));
  });

  test('un événement plus ancien que celui qu\'on a est refusé', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    await service.importEvent(await service.inspect(packetFile(org.sign())));

    await expectLater(
      service.inspect(packetFile(org.sign(issued: clock.subtract(const Duration(hours: 5))), 'vieux.cortege')),
      rejected(PacketProblem.older),
    );
  });

  test('un événement plus récent remplace l\'ancien', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    await service.importEvent(await service.inspect(packetFile(org.sign(name: 'Version 1'))));

    final result = await service.importEvent(
      await service.inspect(
        packetFile(org.sign(name: 'Version 2', issued: clock.subtract(const Duration(minutes: 5))), 'v2.cortege'),
      ),
    );

    expect(result.packetAdded, isTrue);
    expect(service.packets.single.payload.name, 'Version 2');
  });

  test('un événement expiré ou daté du futur est refusé avant tout', () async {
    final org = organizer();
    final expired = OrganizerPacket.sign(
      crypto: crypto,
      publicKey: org.publicKey,
      secretKey: crypto.newSigningKeyPair().secretKey,
      payload: OrganizerPayload(
        name: 'x',
        issued: clock.subtract(const Duration(days: 3)),
        expires: clock.subtract(const Duration(days: 2)),
      ),
    );
    // Signé avec une autre clé : c'est la signature qui est refusée en premier.
    await expectLater(service.inspect(packetFile(expired)), rejected(PacketProblem.badSignature));

    final signer = crypto.newSigningKeyPair();
    String sign(DateTime issued, DateTime expires) => OrganizerPacket.sign(
          crypto: crypto,
          publicKey: signer.publicKey,
          secretKey: signer.secretKey,
          payload: OrganizerPayload(name: 'x', issued: issued, expires: expires),
        );
    await expectLater(
      service.inspect(packetFile(sign(clock.subtract(const Duration(days: 3)), clock.subtract(const Duration(days: 2))))),
      rejected(PacketProblem.expired),
    );
    await expectLater(
      service.inspect(packetFile(sign(clock.add(const Duration(days: 1)), clock.add(const Duration(days: 2))), 'futur.cortege')),
      rejected(PacketProblem.notYetValid),
    );
  });

  test('une signature cassée est refusée même pour un organisateur de confiance', () async {
    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    final text = org.sign();
    final broken = text.replaceFirst('"sig":"', '"sig":"AAAA');

    await expectLater(service.inspect(packetFile(broken)), rejected(PacketProblem.malformed));
    final other = organizer().sign();
    final swapped = text.replaceFirst(RegExp(r'"key":"[^"]+"'), RegExp(r'"key":"[^"]+"').firstMatch(other)!.group(0)!);
    await expectLater(service.inspect(packetFile(swapped, 'autre.cortege')), rejected(PacketProblem.badSignature));
  });

  test('une carte seule suit la règle d\'avant : elle doit être annoncée', () async {
    // Pas d'événement qui l'annonce : refusée tout de suite.
    await expectLater(service.inspect(fixture), rejected(PacketProblem.mapNotExpected));

    final org = organizer();
    await service.trust(OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey));
    await service.importEvent(await service.inspect(packetFile(org.sign(map: reference))));

    final incoming = await service.inspect(fixture);
    expect(incoming.kind, EventFileKind.map);
    final result = await service.importEvent(incoming);

    expect(result.packet, isNull);
    expect(result.map!.hash, reference.hash);
    final archive = (await service.openMap())!;
    addTearDown(archive.close);
    expect(archive.header.tileType, PmtilesHeader.tileTypeMvt);
  });

  test('un fichier quelconque est refusé', () async {
    final photo = File('${dir.path}/photo.jpg')..writeAsBytesSync(Uint8List.fromList(List.generate(2000, (i) => i % 251)));
    await expectLater(service.inspect(photo), rejected(PacketProblem.malformed));
  });
}
