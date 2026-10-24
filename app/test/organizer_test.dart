import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/encrypted_source.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/projection.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:cortege/organizer/organizer_service.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  late Directory dir;
  late VaultStore store;
  late VaultSession session;
  late Directory maps;
  late DateTime clock;
  late OrganizerService service;
  Uint8List? learnedKey;
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cortege_org');
    maps = Directory('${dir.path}/maps');
    clock = DateTime.utc(2026, 10, 20, 12);
    learnedKey = null;
    store = VaultStore(
      crypto: vaultCrypto,
      hardware: MemoryHardwareSecretStore(),
      directory: dir,
      kdf: KdfParams.cheapForTests,
    );
    session = await store.create(pin: '483920');
    service = OrganizerService(
      session: session,
      crypto: crypto,
      mapsDirectory: maps,
      now: () => clock,
      learnMedicKey: (key) => learnedKey = key,
    );
  });

  tearDown(() {
    service.dispose();
    session.lock();
    dir.deleteSync(recursive: true);
  });

  ({Uint8List publicKey, String Function(OrganizerPayload) sign}) organizer() {
    final pair = crypto.newSigningKeyPair();
    final secret = pair.secretKey;
    return (
      publicKey: pair.publicKey,
      sign: (payload) => OrganizerPacket.sign(
            crypto: crypto,
            publicKey: pair.publicKey,
            secretKey: secret,
            payload: payload,
          ),
    );
  }

  OrganizerPayload payload({
    DateTime? issued,
    DateTime? expires,
    MapReference? map,
    Uint8List? medicKey,
    String name = 'Marche du 21 octobre',
  }) =>
      OrganizerPayload(
        name: name,
        issued: issued ?? clock.subtract(const Duration(hours: 1)),
        expires: expires ?? clock.add(const Duration(hours: 12)),
        route: const [(48.8566, 2.3522), (48.8600, 2.3600)],
        points: const [
          OrganizerPoint(kind: PointKind.water, name: 'Fontaine', lat: 48.857, lon: 2.353, note: 'Eau potable'),
          OrganizerPoint(kind: PointKind.meeting, name: 'Départ', lat: 48.8566, lon: 2.3522),
        ],
        contacts: const [OrganizerContact(name: 'Permanence juridique', phone: '+33 1 23 45 67 89')],
        map: map,
        medicKey: medicKey,
      );

  group('paquet signé', () {
    test('un paquet signé se relit à l\'identique', () {
      final org = organizer();
      final key = crypto.randomBytes(32);
      final text = org.sign(payload(medicKey: key, map: MapReference(hash: 'a' * 64, size: 1234, name: 'paris.pmtiles')));

      final packet = OrganizerPacket.parse(text, crypto);

      expect(packet.organizerKey, org.publicKey);
      expect(packet.payload.name, 'Marche du 21 octobre');
      expect(packet.payload.route, hasLength(2));
      expect(packet.payload.points.map((p) => p.kind), [PointKind.water, PointKind.meeting]);
      expect(packet.payload.points.first.note, 'Eau potable');
      expect(packet.payload.contacts.single.phone, '+33 1 23 45 67 89');
      expect(packet.payload.map!.size, 1234);
      expect(packet.payload.medicKey, key);
      expect(packet.fingerprint, matches(RegExp(r'^[0-9a-f]{4}-[0-9a-f]{4}$')));
    });

    test('un octet changé dans le contenu casse la signature', () {
      final org = organizer();
      final envelope = jsonDecode(org.sign(payload())) as Map<String, Object?>;
      final body = base64Url.decode(base64Url.normalize(envelope['body']! as String));
      body[body.length ~/ 2] ^= 1;
      envelope['body'] = base64Url.encode(body).replaceAll('=', '');

      expect(
        () => OrganizerPacket.parse(jsonEncode(envelope), crypto),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.badSignature)),
      );
    });

    test('la signature d\'un autre organisateur ne passe pas sous une autre clé', () {
      final a = organizer();
      final b = organizer();
      final envelope = jsonDecode(a.sign(payload())) as Map<String, Object?>;
      envelope['key'] = base64Url.encode(b.publicKey).replaceAll('=', '');

      expect(
        () => OrganizerPacket.parse(jsonEncode(envelope), crypto),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.badSignature)),
      );
    });

    test('un texte qui n\'est pas un paquet est refusé sans planter', () {
      for (final junk in ['', 'bonjour', '{}', '{"cortege":"org2"}', '[1,2]', '{"cortege":"org1","key":3}']) {
        expect(
          () => OrganizerPacket.parse(junk, crypto),
          throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.malformed)),
          reason: junk,
        );
      }
      expect(
        () => OrganizerPacket.parse('x' * (OrganizerPacket.maxRawLength + 1), crypto),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.tooBig)),
      );
    });

    test('un contenu hors limites est refusé même signé', () {
      final org = organizer();
      PacketRejected? rejected(OrganizerPayload p) {
        try {
          OrganizerPacket.parse(org.sign(p), crypto);
        } on PacketRejected catch (e) {
          return e;
        }
        return null;
      }

      expect(rejected(payload(expires: clock.add(const Duration(days: 40)))), isNotNull, reason: 'trop long');
      expect(rejected(payload(expires: clock.subtract(const Duration(days: 1)))), isNotNull, reason: 'fin avant début');
      expect(
        rejected(OrganizerPayload(
          name: 'x',
          issued: clock,
          expires: clock.add(const Duration(hours: 1)),
          points: const [OrganizerPoint(kind: PointKind.water, name: 'a', lat: 91, lon: 0)],
        )),
        isNotNull,
        reason: 'latitude',
      );
      expect(
        rejected(OrganizerPayload(
          name: 'x',
          issued: clock,
          expires: clock.add(const Duration(hours: 1)),
          contacts: const [OrganizerContact(name: 'a', phone: 'appelle-moi')],
        )),
        isNotNull,
        reason: 'numéro',
      );
      expect(
        rejected(OrganizerPayload(
          name: 'x',
          issued: clock,
          expires: clock.add(const Duration(hours: 1)),
          points: [
            for (var i = 0; i < OrganizerPayload.maxPoints + 1; i++)
              OrganizerPoint(kind: PointKind.info, name: 'p', lat: 1, lon: 1),
          ],
        )),
        isNotNull,
        reason: 'trop de points',
      );
    });

    test('les caractères qui retournent le texte sont retirés des noms', () {
      final org = organizer();
      final reverse = String.fromCharCode(0x202e);
      final text = org.sign(payload(name: 'Mar${reverse}che'));
      expect(OrganizerPacket.parse(text, crypto).payload.name, 'Marche');
    });
  });

  group('code d\'organisateur', () {
    test('le QR se relit et donne la même empreinte', () {
      final org = organizer();
      final invite = OrganizerInvite(name: 'Collectif Eau', publicKey: org.publicKey);
      final back = OrganizerInvite.decode(invite.encode());

      expect(back.name, 'Collectif Eau');
      expect(back.publicKey, org.publicKey);
      expect(back.fingerprint, invite.fingerprint);
      expect(back.fingerprint, OrganizerPacket.parse(org.sign(payload()), crypto).fingerprint);
    });

    test('un code abîmé est refusé', () {
      final org = organizer();
      final text = OrganizerInvite(name: 'A', publicKey: org.publicKey).encode();
      expect(() => OrganizerInvite.decode('CORTEGEB1.abc'), throwsFormatException);
      expect(() => OrganizerInvite.decode(text.substring(0, text.length - 4)), throwsFormatException);
      expect(() => OrganizerInvite.decode('rien'), throwsFormatException);
    });
  });

  group('service', () {
    Future<({Uint8List publicKey, String Function(OrganizerPayload) sign})> trusted() async {
      final org = organizer();
      await service.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey));
      return org;
    }

    test('un organisateur inconnu est refusé, avec son empreinte pour s\'y retrouver', () async {
      final org = organizer();
      final text = org.sign(payload());

      Object? failure;
      try {
        await service.importPacket(text);
      } on PacketRejected catch (e) {
        failure = e;
      }

      expect(failure, isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.unknownOrganizer));
      expect((failure! as PacketRejected).detail, OrganizerPacket.parse(text, crypto).fingerprint);
      expect(service.packets, isEmpty);
    });

    test('après confiance, le paquet est accepté et reste après un verrouillage', () async {
      final org = await trusted();
      await service.importPacket(org.sign(payload()));
      expect(service.packets.single.payload.name, 'Marche du 21 octobre');

      session.lock();
      final reopened = (await store.unlock('483920'))!;
      final again = OrganizerService(session: reopened, crypto: crypto, mapsDirectory: maps, now: () => clock);
      expect(again.organizers.single.name, 'Collectif');
      expect(again.packets.single.payload.points, hasLength(2));
      again.dispose();
      reopened.lock();
    });

    test('un paquet expiré, pas encore valable ou plus vieux est refusé', () async {
      final org = await trusted();
      Future<PacketProblem?> problem(String text) async {
        try {
          await service.importPacket(text);
        } on PacketRejected catch (e) {
          return e.problem;
        }
        return null;
      }

      expect(
        await problem(org.sign(payload(issued: clock.subtract(const Duration(days: 2)), expires: clock.subtract(const Duration(hours: 1))))),
        PacketProblem.expired,
      );
      expect(
        await problem(org.sign(payload(issued: clock.add(const Duration(hours: 5)), expires: clock.add(const Duration(days: 1))))),
        PacketProblem.notYetValid,
      );

      expect(await problem(org.sign(payload(issued: clock.subtract(const Duration(hours: 2))))), isNull);
      expect(
        await problem(org.sign(payload(issued: clock.subtract(const Duration(hours: 5)), name: 'Ancienne version'))),
        PacketProblem.older,
      );
      expect(await problem(org.sign(payload(issued: clock.subtract(const Duration(hours: 1)), name: 'Nouvelle version'))), isNull);
      expect(service.packets.single.payload.name, 'Nouvelle version');
    });

    test('un paquet peut donner la clé des medics', () async {
      final org = await trusted();
      final key = crypto.randomBytes(32);
      await service.importPacket(org.sign(payload(medicKey: key)));
      expect(learnedKey, key);
    });

    test('oublier un organisateur retire ses paquets', () async {
      final org = await trusted();
      await service.importPacket(org.sign(payload()));
      await service.forget(org.publicKey);
      expect(service.organizers, isEmpty);
      expect(service.packets, isEmpty);
    });

    test('un paquet expire tout seul avec le temps', () async {
      final org = await trusted();
      await service.importPacket(org.sign(payload(expires: clock.add(const Duration(hours: 2)))));
      expect(service.packets, hasLength(1));
      clock = clock.add(const Duration(hours: 3));
      expect(service.packets, isEmpty);
    });
  });

  group('carte', () {
    Future<({Uint8List publicKey, String Function(OrganizerPayload) sign})> trustedWithMap(
      File file, {
      int? declaredSize,
      String? declaredHash,
    }) async {
      final org = organizer();
      await service.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey));
      final hash = declaredHash ?? _hex(await crypto.hashFile(file));
      await service.importPacket(
        org.sign(payload(map: MapReference(hash: hash, size: declaredSize ?? await file.length(), name: 'paris.pmtiles'))),
      );
      return org;
    }

    test('la carte annoncée est acceptée, chiffrée, et se lit comme une carte', () async {
      await trustedWithMap(fixture);

      final info = await service.importMap(fixture);

      expect(info.name, 'paris.pmtiles');
      expect(service.mapInfo!.hash, info.hash);
      final stored = maps.listSync().whereType<File>().single;
      expect(stored.path, endsWith('.ctm'));
      final head = stored.readAsBytesSync().sublist(0, 8);
      expect(utf8.decode(head, allowMalformed: true), isNot(contains('PMTiles')), reason: 'rien en clair sur le disque');

      final archive = (await service.openMap())!;
      final lon = (archive.header.minLon + archive.header.maxLon) / 2;
      final lat = (archive.header.minLat + archive.header.maxLat) / 2;
      final tile = await archive.tile(15, lonToTileX(lon, 15).floor(), latToTileY(lat, 15).floor());
      expect(tile, isNotNull);
      expect(tile![0], 0x1a);
      await archive.close();
    });

    test('une carte que personne n\'annonce est refusée', () async {
      final org = organizer();
      await service.trust(OrganizerInvite(name: 'Collectif', publicKey: org.publicKey));
      await service.importPacket(org.sign(payload()));

      expect(
        () => service.importMap(fixture),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.mapNotExpected)),
      );
    });

    test('un fichier de la bonne taille mais modifié est reconnu comme altéré', () async {
      await trustedWithMap(fixture);
      final copy = File('${dir.path}/copie.pmtiles')..writeAsBytesSync(fixture.readAsBytesSync());
      final raf = copy.openSync(mode: FileMode.append);
      raf.setPositionSync(2000);
      raf.writeByteSync(raf.readByteSync() ^ 0xff);
      raf.closeSync();
      final altered = copy.readAsBytesSync();
      altered[2000] ^= 0xff;
      copy.writeAsBytesSync(altered);

      expect(
        () => service.importMap(copy),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.mapCorrupted)),
      );
      expect(maps.existsSync() ? maps.listSync() : [], isEmpty);
    });

    test('un fichier qui a la bonne empreinte sans être une carte est refusé', () async {
      final junk = File('${dir.path}/pas_une_carte.bin')..writeAsBytesSync(Uint8List.fromList(List.filled(5000, 7)));
      await trustedWithMap(junk);

      expect(
        () => service.importMap(junk),
        throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', PacketProblem.mapCorrupted)),
      );
      expect(maps.existsSync() ? maps.listSync() : [], isEmpty);
    });

    test('l\'effacement automatique emporte la carte et son fichier', () async {
      await trustedWithMap(fixture);
      await service.importMap(fixture);
      expect(maps.listSync(), hasLength(1));

      clock = clock.add(const Duration(hours: 30));
      var told = 0;
      final eraser = AutoEraser(
        session,
        now: () => clock,
        onRecordsRemoved: () {
          told++;
          service.cleanFiles();
        },
      );
      await eraser.sweepNow();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(told, greaterThan(0));
      expect(service.mapInfo, isNull);
      expect(service.organizers, isEmpty, reason: 'l\'organisateur de confiance expire lui aussi');
      expect(maps.listSync(), isEmpty);
    });

    test('un nouveau paquet qui annonce une autre carte retire l\'ancienne', () async {
      final org = await trustedWithMap(fixture);
      await service.importMap(fixture);
      expect(service.mapInfo, isNotNull);

      await service.importPacket(org.sign(payload(
        issued: clock,
        map: MapReference(hash: 'b' * 64, size: 99, name: 'autre.pmtiles'),
      )));

      expect(service.mapInfo, isNull, reason: 'plus aucun paquet n\'annonce cette carte');
      expect(maps.listSync(), isEmpty);
    });
  });

  group('carte chiffrée', () {
    late Uint8List key;
    late File plain;
    late File sealed;
    late Uint8List data;

    setUp(() async {
      key = crypto.randomBytes(32);
      final random = math.Random(3);
      data = Uint8List.fromList(List.generate(300000, (_) => random.nextInt(256)));
      plain = File('${dir.path}/clair.bin')..writeAsBytesSync(data);
      sealed = File('${dir.path}/chiffre.ctm');
      await EncryptedMap.encrypt(crypto: crypto, source: plain, target: sealed, keyBytes: key);
    });

    test('toute lecture au hasard rend les mêmes octets qu\'en clair', () async {
      final source = await EncryptedByteSource.open(sealed, key, crypto);
      expect(source.length, data.length);
      final random = math.Random(11);
      for (var i = 0; i < 200; i++) {
        final offset = random.nextInt(data.length - 1);
        final count = 1 + random.nextInt(math.min(200000, data.length - offset));
        expect(await source.read(offset, count), data.sublist(offset, offset + count), reason: '$offset + $count');
      }
      await source.close();
    });

    test('des lectures en parallèle se passent bien', () async {
      final source = await EncryptedByteSource.open(sealed, key, crypto);
      final reads = await Future.wait([
        for (var i = 0; i < 20; i++) source.read(i * 13000, 9000),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(reads[i], data.sublist(i * 13000, i * 13000 + 9000));
      }
      await source.close();
    });

    test('le fichier chiffré n\'a rien de lisible', () {
      final bytes = sealed.readAsBytesSync();
      expect(bytes.length, greaterThan(data.length));
      // Aucune suite de 16 octets du clair ne se retrouve dans le chiffré.
      final window = data.sublist(1000, 1016);
      var found = false;
      for (var i = 0; i + 16 <= bytes.length && !found; i++) {
        var same = true;
        for (var j = 0; j < 16; j++) {
          if (bytes[i + j] != window[j]) {
            same = false;
            break;
          }
        }
        found = same;
      }
      expect(found, isFalse);
    });

    test('un morceau modifié est détecté à la lecture', () async {
      final bytes = sealed.readAsBytesSync();
      bytes[EncryptedMap.headerLength + 70000] ^= 1; // dans le deuxième morceau
      sealed.writeAsBytesSync(bytes);
      final source = await EncryptedByteSource.open(sealed, key, crypto);

      expect(await source.read(0, 1000), data.sublist(0, 1000), reason: 'le premier morceau est intact');
      await expectLater(source.read(70000, 100), throwsA(isA<EncryptedMapException>()));
      await source.close();
    });

    test('mauvaise clé, fichier tronqué ou rallongé : refusés', () async {
      final wrong = await EncryptedByteSource.open(sealed, crypto.randomBytes(32), crypto);
      await expectLater(wrong.read(0, 10), throwsA(isA<EncryptedMapException>()));
      await wrong.close();

      final bytes = sealed.readAsBytesSync();
      final truncated = File('${dir.path}/court.ctm')..writeAsBytesSync(bytes.sublist(0, bytes.length - 100));
      await expectLater(EncryptedByteSource.open(truncated, key, crypto), throwsA(isA<EncryptedMapException>()));
      final longer = File('${dir.path}/long.ctm')..writeAsBytesSync([...bytes, 1, 2, 3]);
      await expectLater(EncryptedByteSource.open(longer, key, crypto), throwsA(isA<EncryptedMapException>()));
      final foreign = File('${dir.path}/autre.bin')..writeAsBytesSync(Uint8List(100));
      await expectLater(EncryptedByteSource.open(foreign, key, crypto), throwsA(isA<EncryptedMapException>()));
    });

    test('deux chiffrements du même fichier ne se ressemblent pas', () async {
      final other = File('${dir.path}/chiffre2.ctm');
      await EncryptedMap.encrypt(crypto: crypto, source: plain, target: other, keyBytes: key);
      final a = sealed.readAsBytesSync();
      final b = other.readAsBytesSync();
      var equalBytes = 0;
      for (var i = EncryptedMap.headerLength; i < a.length; i++) {
        if (a[i] == b[i]) equalBytes++;
      }
      expect(equalBytes, lessThan(a.length * 0.02));
    });
  });

  test('la carte d\'essai se lit après un aller-retour par la source en mémoire', () async {
    final archive = await PmtilesArchive.open(MemoryByteSource(fixture.readAsBytesSync()));
    expect(archive.header.maxZoom, 15);
    await archive.close();
  });
}
