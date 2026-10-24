import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cortege/content/fiche.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/map/byte_source.dart';
import 'package:cortege/map/encrypted_source.dart';
import 'package:cortege/map/mvt.dart';
import 'package:cortege/map/pmtiles.dart';
import 'package:cortege/map/pmtiles_extract.dart';
import 'package:cortege/mesh/buddy_invite.dart';
import 'package:cortege/mesh/frame.dart';
import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/medic_invite.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/event_file.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pmtiles_builder.dart';

/// Abîme volontairement tout ce qui vient de l'extérieur (cartes, fichiers
/// d'événement, paquets, codes QR, trames, fiches) et vérifie trois choses : ni
/// plantage, ni exception d'un genre imprévu, ni calcul qui s'éternise. Les
/// mutations sont tirées d'un générateur fixe : un échec se rejoue à
/// l'identique.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = File('test/fixtures/paris_fixture.pmtiles');
  final random = Random(20261024);
  // `FUZZ_SCALE=10 flutter test test/fuzz_parsers_test.dart` multiplie le nombre
  // de fichiers abîmés, pour une recherche plus longue avant une diffusion.
  final scale = int.tryParse(Platform.environment['FUZZ_SCALE'] ?? '') ?? 1;
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  late Directory dir;

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
  });

  setUp(() => dir = Directory.systemTemp.createTempSync('cortege_fuzz'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Un tirage de mutation : octets changés, coupure, fenêtre écrasée, morceau
  /// dupliqué. [focus] oriente une partie des mutations vers le début du fichier
  /// (en-têtes, répertoires).
  Uint8List mutate(Uint8List seed, {int focus = 0}) {
    final out = Uint8List.fromList(seed);
    if (out.isEmpty) return out;
    int position() => focus > 0 && random.nextInt(10) < 7
        ? random.nextInt(min(focus, out.length))
        : random.nextInt(out.length);
    switch (random.nextInt(5)) {
      case 0:
        for (var i = 0; i < 1 + random.nextInt(6); i++) {
          out[position()] = random.nextInt(256);
        }
        return out;
      case 1:
        return Uint8List.sublistView(out, 0, random.nextInt(out.length));
      case 2:
        final at = position();
        final fill = [0x00, 0xff, 0x80, 0x7f][random.nextInt(4)];
        for (var i = at; i < min(out.length, at + 1 + random.nextInt(12)); i++) {
          out[i] = fill;
        }
        return out;
      case 3:
        final at = position();
        final length = min(out.length - at, 1 + random.nextInt(32));
        return Uint8List.fromList([
          ...out.sublist(0, at + length),
          ...out.sublist(at, at + length),
          ...out.sublist(at + length),
        ]);
      default:
        out[position()] ^= 1 << random.nextInt(8);
        return out;
    }
  }

  /// Lance [run] [count] fois. Une exception de genre non prévu, ou un tour qui
  /// dure plus de [slowest], fait échouer le test avec la liste de ce qui a été vu.
  Future<void> fuzz(
    int count,
    Future<void> Function(int) run,
    bool Function(Object) allowed, {
    Duration slowest = const Duration(seconds: 3),
  }) async {
    final unexpected = <String, String>{};
    final slow = <String>[];
    for (var i = 0; i < count; i++) {
      final watch = Stopwatch()..start();
      try {
        await run(i);
      } on Object catch (error, stack) {
        if (!allowed(error)) {
          unexpected.putIfAbsent(
            error.runtimeType.toString(),
            () => 'tour $i : $error\n${stack.toString().split('\n').take(4).join('\n')}',
          );
        }
      }
      if (watch.elapsed > slowest) slow.add('tour $i : ${watch.elapsed}');
    }
    expect(unexpected, isEmpty, reason: 'exceptions imprévues :\n${unexpected.values.join('\n---\n')}');
    expect(slow, isEmpty, reason: 'tours trop longs');
  }

  List<(int, int, int)> fixtureTiles(PmtilesArchive archive) {
    final h = archive.header;
    return [
      for (final id in tileIdsCovering(
        (west: h.minLon, south: h.minLat, east: h.maxLon, north: h.maxLat),
        h.minZoom,
        h.maxZoom,
      ))
        tileIdToZxy(id),
    ];
  }

  group('cartes', () {
    test('une carte PMTiles abîmée ne plante pas et se lit ou se refuse proprement', () async {
      final seed = fixture.readAsBytesSync();
      final original = await PmtilesArchive.open(MemoryByteSource(seed));
      final tiles = fixtureTiles(original);
      expect(tiles, isNotEmpty);

      await fuzz(
        500 * scale,
        (i) async {
          final bytes = mutate(seed, focus: 400);
          final archive = await PmtilesArchive.open(MemoryByteSource(bytes));
          for (final (z, x, y) in tiles) {
            final data = await archive.tile(z, x, y);
            if (data != null) decodeMvt(data);
          }
        },
        (e) => e is PmtilesException || e is MvtException || e is RangeError || e is FormatException,
      );
    });

    test('une tuile vectorielle abîmée ne plante pas et ne s\'éternise pas', () async {
      final archive = await PmtilesArchive.open(MemoryByteSource(fixture.readAsBytesSync()));
      final seeds = <Uint8List>[
        for (final (z, x, y) in fixtureTiles(archive)) (await archive.tile(z, x, y))!,
      ];
      expect(seeds, isNotEmpty);

      await fuzz(
        240 * scale,
        (i) async {
          final seed = seeds[i % seeds.length];
          decodeMvt(mutate(seed, focus: 600));
        },
        (e) => e is MvtException,
      );
    });

    test('du texte quelconque, ou aléatoire, n\'est pas une tuile', () async {
      await fuzz(
        400 * scale,
        (i) async {
          final bytes = Uint8List.fromList(List.generate(random.nextInt(300), (_) => random.nextInt(256)));
          decodeMvt(bytes);
        },
        (e) => e is MvtException,
      );
    });

    test('une bombe de décompression est refusée sans remplir la mémoire', () async {
      // Une tuile de 150 Mo de zéros tient en quelques Ko une fois compressée.
      final bomb = Uint8List.fromList(gzip.encode(Uint8List(150 * 1024 * 1024)));
      expect(bomb.length, lessThan(1024 * 1024));
      const area = (west: 2.30, south: 48.83, east: 2.36, north: 48.87);
      final id = tileIdsCovering(area, 12, 12).first;
      final file = buildPmtiles(
        tiles: {id: bomb},
        bounds: area,
        minZoom: 12,
        maxZoom: 12,
        tileCompression: 2,
      );
      final archive = await PmtilesArchive.open(MemoryByteSource(file));
      final (z, x, y) = tileIdToZxy(id);

      await expectLater(archive.tile(z, x, y), throwsA(isA<PmtilesException>()));
    });

    test('un répertoire racine qui est une bombe de décompression est refusé', () async {
      const area = (west: 2.30, south: 48.83, east: 2.36, north: 48.87);
      final id = tileIdsCovering(area, 12, 12).first;
      final file = buildPmtiles(tiles: {id: Uint8List.fromList([1, 2, 3])}, bounds: area, minZoom: 12, maxZoom: 12);
      final bomb = Uint8List.fromList(gzip.encode(Uint8List(150 * 1024 * 1024)));
      final patched = Uint8List.fromList([...file.sublist(0, PmtilesHeader.length), ...bomb]);
      ByteData.sublistView(patched).setUint64(8, PmtilesHeader.length, Endian.little);
      ByteData.sublistView(patched).setUint64(16, bomb.length, Endian.little);

      await expectLater(
        PmtilesArchive.open(MemoryByteSource(patched)),
        throwsA(isA<PmtilesException>()),
      );
    });

    test('une tuile ou un répertoire annoncé démesuré est refusé avant toute lecture', () async {
      const area = (west: 2.30, south: 48.83, east: 2.36, north: 48.87);
      final id = tileIdsCovering(area, 12, 12).first;
      final file = buildPmtiles(tiles: {id: Uint8List.fromList([1, 2, 3])}, bounds: area, minZoom: 12, maxZoom: 12);
      // Un fichier de 200 Mo dont la tuile annoncée occupe presque tout.
      final big = Uint8List(200 * 1024 * 1024)..setRange(0, file.length, file);
      final header = PmtilesHeader.parse(file);
      // Le répertoire racine est écrit tel quel ; on gonfle la longueur de la tuile
      // en réécrivant un répertoire non compressé n'est pas possible : on
      // vérifie donc surtout la limite de longueur d'un répertoire.
      ByteData.sublistView(big).setUint64(16, 190 * 1024 * 1024, Endian.little);

      await expectLater(
        PmtilesArchive.open(MemoryByteSource(big)),
        throwsA(isA<PmtilesException>()),
      );
      expect(header.rootLength, lessThan(1024));
    });
  });

  group('cartes chiffrées', () {
    test('un fichier de carte chiffré abîmé est refusé ou détecté à la lecture', () async {
      final source = File('${dir.path}/source.bin')..writeAsBytesSync(Uint8List.fromList(List.generate(300 * 1024, (i) => i % 251)));
      final target = File('${dir.path}/carte.ctm');
      final key = crypto.randomBytes(32);
      await EncryptedMap.encrypt(crypto: crypto, source: source, target: target, keyBytes: key);
      final seed = target.readAsBytesSync();

      await fuzz(
        200 * scale,
        (i) async {
          final copy = File('${dir.path}/abime.ctm')..writeAsBytesSync(mutate(seed, focus: 64));
          final reader = await EncryptedByteSource.open(copy, key, crypto);
          try {
            await reader.read(0, reader.length);
          } finally {
            await reader.close();
          }
        },
        (e) => e is EncryptedMapException || e is RangeError,
      );
    });
  });

  group('événements', () {
    late String packet;

    setUp(() {
      final pair = crypto.newSigningKeyPair();
      packet = OrganizerPacket.sign(
        crypto: crypto,
        publicKey: pair.publicKey,
        secretKey: pair.secretKey,
        payload: OrganizerPayload(
          name: 'Marche',
          issued: DateTime.utc(2026, 10, 24),
          expires: DateTime.utc(2026, 10, 25),
          route: const [(48.85, 2.35), (48.86, 2.36)],
          points: const [OrganizerPoint(kind: PointKind.water, name: 'Fontaine', lat: 48.85, lon: 2.35, note: 'Eau')],
          contacts: const [OrganizerContact(name: 'Permanence', phone: '01 23 45 67 89')],
          map: MapReference(hash: 'a' * 64, size: 1234, name: 'carte.pmtiles'),
          medicKey: Uint8List(32),
          organizerName: 'Collectif',
        ),
      );
    });

    test('un paquet abîmé est refusé sans exception imprévue', () async {
      final seed = Uint8List.fromList(utf8.encode(packet));
      await fuzz(
        1500 * scale,
        (i) async {
          final text = utf8.decode(mutate(seed), allowMalformed: true);
          OrganizerPacket.parse(text, crypto);
        },
        (e) => e is PacketRejected,
      );
    });

    test('un contenu signé aux types faux est refusé sans exception imprévue', () async {
      final pair = crypto.newSigningKeyPair();
      final base = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize((jsonDecode(packet) as Map)['body'] as String),
          ),
        ),
      ) as Map<String, Object?>;
      Object? odd() => <Object?>[
            null,
            true,
            -1,
            0,
            1 << 62,
            1e308,
            -1e308,
            double.nan,
            '',
            'x' * 5000,
            <Object?>[],
            <String, Object?>{},
            <Object?>[1, 2, 3],
            <String, Object?>{'a': 1},
          ][random.nextInt(14)];

      await fuzz(
        3000 * scale,
        (i) async {
          final copy = jsonDecode(jsonEncode(base)) as Map<String, Object?>;
          for (var n = 0; n < 1 + random.nextInt(3); n++) {
            final keys = copy.keys.toList();
            final key = keys[random.nextInt(keys.length)];
            final value = copy[key];
            if (value is List && value.isNotEmpty && random.nextBool()) {
              value[random.nextInt(value.length)] = odd();
            } else if (value is Map && value.isNotEmpty && random.nextBool()) {
              value[value.keys.toList()[random.nextInt(value.length)]] = odd();
            } else {
              copy[key] = odd();
            }
          }
          OrganizerPayload.fromJson(copy);
        },
        (e) => e is PacketRejected,
      );
      expect(pair.publicKey, isNotEmpty);
    });

    test('un fichier d\'événement quelconque est refusé sans exception imprévue', () async {
      final bundle = BytesBuilder()
        ..add(EventFile.magic)
        ..add([0, 0, 0, 40])
        ..add(utf8.encode(packet.substring(0, 40)))
        ..add(Uint8List(200));
      final seeds = [bundle.toBytes(), Uint8List.fromList(utf8.encode(packet)), fixture.readAsBytesSync().sublist(0, 4000)];

      await fuzz(
        600 * scale,
        (i) async {
          final file = File('${dir.path}/fichier.cortege')..writeAsBytesSync(mutate(seeds[i % seeds.length]));
          await EventFile.readHead(file);
        },
        (e) => e is PacketRejected,
      );
    });
  });

  group('codes QR et trames', () {
    test('un code d\'organisateur abîmé est refusé par une FormatException', () async {
      final valid = OrganizerInvite(name: 'Collectif', publicKey: Uint8List(32)).encode();
      final seed = Uint8List.fromList(utf8.encode(valid));
      await fuzz(
        1500 * scale,
        (i) async {
          OrganizerInvite.decode(utf8.decode(mutate(seed), allowMalformed: true));
        },
        (e) => e is FormatException,
      );
    });

    test('des codes de groupe, de binôme et de medics au contenu quelconque sont refusés par une FormatException', () async {
      final decoders = <String, void Function(String)>{
        GroupInvite.prefix: (s) => GroupInvite.decode(s),
        BuddyInvite.prefix: (s) => BuddyInvite.decode(s),
        MedicInvite.prefix: (s) => MedicInvite.decode(s),
      };
      await fuzz(
        6000 * scale,
        (i) async {
          final entry = decoders.entries.elementAt(i % 3);
          final body = Uint8List.fromList(List.generate(random.nextInt(200), (_) => random.nextInt(256)));
          entry.value('${entry.key}${base64Url.encode(body).replaceAll('=', '')}');
        },
        (e) => e is FormatException,
      );
    });

    test('des trames et des flux au contenu quelconque ne lèvent que ce qui est prévu', () async {
      await fuzz(
        3000 * scale,
        (i) async {
          final bytes = Uint8List.fromList(List.generate(random.nextInt(700), (_) => random.nextInt(256)));
          if (i.isEven) {
            Frame.parse(bytes, minSealedLength: 32);
          } else {
            final assembler = FrameAssembler();
            for (var offset = 0; offset < bytes.length; offset += 1 + random.nextInt(40)) {
              assembler.add(Uint8List.sublistView(bytes, offset, min(bytes.length, offset + 40)));
            }
          }
        },
        (e) => e is FrameStreamError,
      );
    });
  });

  group('fiches', () {
    test('une fiche abîmée est refusée par une FormatException', () async {
      final seeds = [
        for (final category in ['droits', 'secours'])
          for (final file in Directory('assets/content/$category').listSync().whereType<File>())
            file.readAsBytesSync(),
      ];
      await fuzz(
        900 * scale,
        (i) async {
          parseFiche('x', utf8.decode(mutate(seeds[i % seeds.length]), allowMalformed: true));
        },
        (e) => e is FormatException,
      );
    });
  });
}
