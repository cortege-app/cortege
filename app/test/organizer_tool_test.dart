import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/event_file.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:cortege/organizer/organizer_tool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pmtiles_builder.dart';

void main() {
  late MeshCrypto crypto;
  late Directory dir;
  late List<String> lines;
  final now = DateTime.utc(2026, 10, 21, 9);

  setUpAll(() async {
    crypto = MeshCrypto(await VaultCrypto.create());
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cortege_tool');
    lines = [];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> args) =>
      runOrganizerTool(args, crypto: crypto, out: lines.add, now: () => now);

  String path(String name) => '${dir.path}/$name';

  File event({Map<String, Object?>? extra}) => File(path('evenement.json'))
    ..writeAsStringSync(jsonEncode({
      'nom': 'Marche du 21 octobre',
      'heures': 10,
      'parcours': [
        [48.8566, 2.3522],
        [48.8600, 2.3600],
      ],
      'lieux': [
        {'type': 'eau', 'nom': 'Fontaine', 'lat': 48.857, 'lon': 2.353, 'note': 'Eau potable'},
        {'type': 'rdv', 'nom': 'Départ', 'lat': 48.8566, 'lon': 2.3522},
      ],
      'contacts': [
        {'nom': 'Permanence juridique', 'tel': '01 23 45 67 89'},
      ],
      ...?extra,
    }));

  test('la clé, son QR et un paquet signé s\'enchaînent, et l\'appli les accepte', () async {
    expect(await run(['keygen', '--name', 'Collectif Eau', '--out', path('collectif.cle')]), 0);
    expect(File(path('collectif.cle')).existsSync(), isTrue);
    final png = File(path('collectif.cle.qr.png')).readAsBytesSync();
    expect(png.sublist(1, 4), ascii.encode('PNG'));

    expect(await run(['packet', '--key', path('collectif.cle'), '--in', event().path, '--out', path('paquet.cortege')]), 0);
    expect(await run(['show', '--in', path('paquet.cortege')]), 0);
    expect(lines.join('\n'), contains('Signature valable'));
    expect(lines.join('\n'), contains('Fontaine'));

    // L'appli lit ce que l'outil a écrit.
    final packet = OrganizerPacket.parse(File(path('paquet.cortege')).readAsStringSync(), crypto);
    expect(packet.payload.name, 'Marche du 21 octobre');
    expect(packet.payload.expires.difference(packet.payload.issued).inHours, 10);
    expect(packet.payload.points.map((p) => p.kind.name), ['water', 'meeting']);

    // Le texte du QR donne la même empreinte que le paquet.
    final qrLine = lines.firstWhere((l) => l.startsWith('Texte du QR : '));
    final invite = OrganizerInvite.decode(qrLine.substring('Texte du QR : '.length));
    expect(invite.fingerprint, packet.fingerprint);
    expect(invite.publicKey, packet.organizerKey);
  });

  test('le paquet annonce la carte avec son empreinte', () async {
    await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
    final map = File('test/fixtures/paris_fixture.pmtiles');

    expect(await run(['packet', '--key', path('a.cle'), '--in', event().path, '--out', path('p.cortege'), '--map', map.path]), 0);

    final packet = OrganizerPacket.parse(File(path('p.cortege')).readAsStringSync(), crypto);
    expect(packet.payload.map!.size, map.lengthSync());
    expect(packet.payload.map!.hash, hexOf(await crypto.hashFile(map)));
    expect(packet.payload.map!.name, 'paris_fixture.pmtiles');

    lines.clear();
    expect(await run(['hash', '--in', map.path]), 0);
    expect(lines.single, packet.payload.map!.hash);
  });

  test('l\'outil refuse d\'écraser une clé, un type de lieu inconnu, un fichier absent', () async {
    await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
    final before = File(path('a.cle')).readAsStringSync();

    expect(await run(['keygen', '--name', 'B', '--out', path('a.cle')]), 1);
    expect(File(path('a.cle')).readAsStringSync(), before, reason: 'la clé n\'est pas écrasée');

    final bad = File(path('mauvais.json'))
      ..writeAsStringSync(jsonEncode({
        'nom': 'x',
        'lieux': [
          {'type': 'piscine', 'lat': 1, 'lon': 1},
        ],
      }));
    lines.clear();
    expect(await run(['packet', '--key', path('a.cle'), '--in', bad.path, '--out', path('p.cortege')]), 1);
    expect(lines.join(), contains('type de lieu inconnu'));
    expect(File(path('p.cortege')).existsSync(), isFalse);

    expect(await run(['show', '--in', path('absent.cortege')]), 1);
    expect(await run(['nimporte']), 2);
    expect(await run([]), 2);
  });

  test('un paquet qui sortirait des limites n\'est pas écrit', () async {
    await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
    final tooLong = event(extra: {'heures': 24 * 40});
    lines.clear();

    expect(await run(['packet', '--key', path('a.cle'), '--in', tooLong.path, '--out', path('p.cortege')]), 1);
    expect(File(path('p.cortege')).existsSync(), isFalse);
  });

  group('un seul fichier pour l\'événement', () {
    const region = (west: 2.25, south: 48.80, east: 2.45, north: 48.92);
    late Uint8List worldFile;
    late List<String> opened;
    late int failFirst;

    setUpAll(() {
      worldFile = buildPmtiles(tiles: blockOfTiles(region, 10, 14), bounds: region, minZoom: 10, maxZoom: 14);
    });

    setUp(() {
      opened = [];
      failFirst = 0;
    });

    /// Une « carte du monde » en mémoire, dont les premières versions ne répondent pas.
    Future<ByteSource> remote(String url) async {
      opened.add(url);
      if (opened.length <= failFirst) throw const SocketException('pas de réponse');
      return MemoryByteSource(worldFile);
    }

    Future<int> runWithRemote(List<String> args) => runOrganizerTool(
          args,
          crypto: crypto,
          out: lines.add,
          now: () => now,
          openRemote: remote,
        );

    Future<File> mapPart(File bundle) async {
      final head = await EventFile.readHead(bundle);
      final part = File(path('extrait.pmtiles'))..writeAsBytesSync(bundle.readAsBytesSync().sublist(head.mapStart));
      return part;
    }

    test('avec une carte déjà prête : un fichier, la carte jointe et conforme', () async {
      await run(['keygen', '--name', 'Collectif Eau', '--out', path('a.cle')]);
      final map = File('test/fixtures/paris_fixture.pmtiles');

      expect(
        await run(['event', '--key', path('a.cle'), '--in', event().path, '--out', path('e.cortege'), '--map', map.path]),
        0,
        reason: lines.join('\n'),
      );

      final bundle = File(path('e.cortege'));
      final head = await EventFile.readHead(bundle);
      expect(head.kind, EventFileKind.bundle);
      expect(head.mapLength, map.lengthSync());
      final packet = OrganizerPacket.parse(head.packetText!, crypto);
      expect(packet.payload.organizerName, 'Collectif Eau');
      expect(packet.payload.map!.hash, hexOf(await crypto.hashFile(map)));
      expect(lines.join('\n'), contains('Envoie ce fichier tel quel'));

      lines.clear();
      expect(await run(['show', '--in', bundle.path]), 0);
      expect(lines.join('\n'), contains('conforme à celle que le paquet annonce'));
      expect(lines.join('\n'), contains('Se présente comme : Collectif Eau'));
    });

    test('"carte": true prend la zone du parcours, cherche la carte la plus récente et la joint', () async {
      failFirst = 2;
      await run(['keygen', '--name', 'Collectif Eau', '--out', path('a.cle')]);
      lines.clear();

      final code = await runWithRemote([
        'event',
        '--key',
        path('a.cle'),
        '--in',
        event(extra: {'carte': true}).path,
        '--out',
        path('e.cortege'),
      ]);

      expect(code, 0, reason: lines.join('\n'));
      expect(opened, [
        'https://build.protomaps.com/20261020.pmtiles',
        'https://build.protomaps.com/20261019.pmtiles',
        'https://build.protomaps.com/20261018.pmtiles',
      ]);
      expect(File(path('e.cortege.carte.tmp')).existsSync(), isFalse);
      expect(lines.join('\n'), contains('Carte prête'));

      final bundle = File(path('e.cortege'));
      final head = await EventFile.readHead(bundle);
      expect(head.kind, EventFileKind.bundle);
      final packet = OrganizerPacket.parse(head.packetText!, crypto);
      final part = await mapPart(bundle);
      expect(packet.payload.map!.hash, hexOf(await crypto.hashFile(part)));
      expect(packet.payload.map!.size, part.lengthSync());
      expect(packet.payload.map!.name, 'carte.pmtiles');
      final archive = await PmtilesArchive.open(await FileByteSource.open(part));
      addTearDown(archive.close);
      // La zone entoure le parcours, avec une marge.
      expect(archive.header.minLat, lessThan(48.8566));
      expect(archive.header.maxLat, greaterThan(48.8600));
      expect(archive.header.minLon, lessThan(2.3522));
      expect(archive.header.maxLon, greaterThan(2.3600));
      expect(archive.header.maxZoom, 14);
      expect(archive.header.minZoom, 10);

      lines.clear();
      expect(await run(['show', '--in', bundle.path]), 0);
      expect(lines.join('\n'), contains('conforme'));
    });

    test('une zone et des zooms donnés dans le fichier d\'événement sont respectés', () async {
      await run(['keygen', '--name', 'A', '--out', path('a.cle')]);

      final code = await runWithRemote([
        'event',
        '--key',
        path('a.cle'),
        '--in',
        event(extra: {
          'carte': {
            'zone': [2.30, 48.83, 2.36, 48.87],
            'zoom_min': 11,
            'zoom_max': 12,
          },
        }).path,
        '--out',
        path('e.cortege'),
      ]);

      expect(code, 0, reason: lines.join('\n'));
      final archive = await PmtilesArchive.open(await FileByteSource.open(await mapPart(File(path('e.cortege')))));
      addTearDown(archive.close);
      expect(archive.header.minZoom, 11);
      expect(archive.header.maxZoom, 12);
      expect(archive.header.minLon, closeTo(2.30, 1e-6));
      expect(archive.header.maxLat, closeTo(48.87, 1e-6));
    });

    test('sans carte demandée, le fichier est le simple paquet', () async {
      await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
      lines.clear();

      expect(await run(['event', '--key', path('a.cle'), '--in', event().path, '--out', path('e.cortege')]), 0);

      expect((await EventFile.readHead(File(path('e.cortege')))).kind, EventFileKind.packet);
      expect(lines.join('\n'), contains('Sans carte'));
    });

    test('une carte en ligne sans moyen de la lire, ou trop lourde, ou sans zone : une erreur claire', () async {
      await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
      lines.clear();

      // L'outil lancé sans accès au réseau.
      expect(
        await run(['event', '--key', path('a.cle'), '--in', event(extra: {'carte': true}).path, '--out', path('e.cortege')]),
        1,
      );
      expect(lines.join('\n'), contains('--map'));
      expect(File(path('e.cortege')).existsSync(), isFalse);

      // Plus lourde que la limite.
      lines.clear();
      expect(
        await runWithRemote(
          ['event', '--key', path('a.cle'), '--in', event(extra: {'carte': {'max_mo': 0}}).path, '--out', path('e.cortege')],
        ),
        1,
      );
      expect(lines.join('\n'), contains('Réduis la zone'));
      expect(File(path('e.cortege')).existsSync(), isFalse);
      expect(File(path('e.cortege.carte.tmp')).existsSync(), isFalse);

      // Rien pour deviner une zone.
      lines.clear();
      final empty = File(path('vide.json'))..writeAsStringSync(jsonEncode({'nom': 'x', 'carte': true}));
      expect(await runWithRemote(['event', '--key', path('a.cle'), '--in', empty.path, '--out', path('e.cortege')]), 1);
      expect(lines.join('\n'), contains('parcours ou de lieux'));

      // Aucune carte récente n'a répondu.
      lines.clear();
      failFirst = 100;
      expect(
        await runWithRemote(['event', '--key', path('a.cle'), '--in', event(extra: {'carte': true}).path, '--out', path('e.cortege')]),
        1,
      );
      expect(lines.join('\n'), contains('aucune carte Protomaps récente'));
    });

    test('extract prépare seulement la carte', () async {
      expect(
        await runWithRemote([
          'extract',
          '--zone',
          '2.30,48.83,2.36,48.87',
          '--zoom-max',
          '12',
          '--source',
          'https://exemple.test/monde.pmtiles',
          '--out',
          path('carte.pmtiles'),
        ]),
        0,
        reason: lines.join('\n'),
      );
      expect(opened, ['https://exemple.test/monde.pmtiles']);
      final archive = await PmtilesArchive.open(await FileByteSource.open(File(path('carte.pmtiles'))));
      addTearDown(archive.close);
      expect(archive.header.maxZoom, 12);

      lines.clear();
      expect(await runWithRemote(['extract', '--zone', '2.3,48.8', '--out', path('x.pmtiles')]), 1);
      expect(lines.join('\n'), contains('ouest,sud,est,nord'));
      expect(await runWithRemote(['extract', '--zone', '2.3,48.8,2.4,48.9', '--zoom-max', 'beaucoup', '--out', path('x.pmtiles')]), 1);
      expect(File(path('x.pmtiles')).existsSync(), isFalse);
    });

    test('show signale une carte jointe qui a été modifiée', () async {
      await run(['keygen', '--name', 'A', '--out', path('a.cle')]);
      final map = File('test/fixtures/paris_fixture.pmtiles');
      await run(['event', '--key', path('a.cle'), '--in', event().path, '--out', path('e.cortege'), '--map', map.path]);
      final bytes = File(path('e.cortege')).readAsBytesSync();
      bytes[bytes.length - 10] ^= 0xff;
      File(path('e.cortege')).writeAsBytesSync(bytes);
      lines.clear();

      expect(await run(['show', '--in', path('e.cortege')]), 0);

      expect(lines.join('\n'), contains('NE CORRESPOND PAS'));
    });
  });
}

String hexOf(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
