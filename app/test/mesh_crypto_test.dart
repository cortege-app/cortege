import 'dart:typed_data';

import 'package:cortege/mesh/frame.dart';
import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_sim.dart';

void main() {
  late MeshCrypto crypto;

  setUpAll(() async {
    crypto = await newMeshCrypto();
  });

  group('invitation QR', () {
    test('aller-retour', () {
      final invite = GroupInvite(
        name: 'Équipe République',
        groupKey: crypto.randomBytes(32),
        eventSecret: crypto.randomBytes(32),
      );
      final decoded = GroupInvite.decode(invite.encode());
      expect(decoded.name, 'Équipe République');
      expect(decoded.groupKey, invite.groupKey);
      expect(decoded.eventSecret, invite.eventSecret);
    });

    test('le texte du QR reste court', () {
      final invite = GroupInvite(
        name: 'x' * GroupInvite.maxNameBytes,
        groupKey: crypto.randomBytes(32),
        eventSecret: crypto.randomBytes(32),
      );
      // Un QR de ce texte reste petit et se scanne bien.
      expect(invite.encode().length, lessThan(160));
    });

    test('refus des textes qui ne sont pas des invitations', () {
      final good = GroupInvite(
        name: 'ok',
        groupKey: crypto.randomBytes(32),
        eventSecret: crypto.randomBytes(32),
      ).encode();
      for (final bad in [
        '',
        'https://exemple.org',
        'CORTEGE1.',
        'CORTEGE1.!!!!',
        good.substring(0, good.length - 4),
        '${good}AAAA',
      ]) {
        expect(() => GroupInvite.decode(bad), throwsFormatException, reason: bad);
      }
    });

    test('nom vide ou trop long refusé', () {
      expect(
        () => GroupInvite(name: '', groupKey: Uint8List(32), eventSecret: Uint8List(32)),
        throwsFormatException,
      );
      expect(
        () => GroupInvite(
          name: 'x' * (GroupInvite.maxNameBytes + 1),
          groupKey: Uint8List(32),
          eventSecret: Uint8List(32),
        ),
        throwsFormatException,
      );
    });
  });

  group('dérivations', () {
    test('mêmes entrées, mêmes valeurs ; autre entrée, autre valeur', () {
      final a = crypto.secure(Uint8List.fromList(List.filled(32, 1)));
      final b = crypto.secure(Uint8List.fromList(List.filled(32, 2)));
      expect(crypto.derive(a, 'x/1', 16), crypto.derive(a, 'x/1', 16));
      expect(crypto.derive(a, 'x/1', 16), isNot(crypto.derive(b, 'x/1', 16)));
      expect(crypto.derive(a, 'x/1', 16), isNot(crypto.derive(a, 'y/1', 16)));
      expect(crypto.derive(a, 'x/1', 8), hasLength(8));
    });

    test('l\'identifiant Bluetooth annoncé change à chaque période', () {
      final keys = EventKeys(crypto, crypto.randomBytes(32));
      final first = keys.advertisedService(100);
      expect(first, hasLength(16));
      expect(keys.advertisedService(100), first);
      expect(keys.advertisedService(101), isNot(first));
    });

    test('deux événements n\'ont aucun identifiant en commun', () {
      final a = EventKeys(crypto, crypto.randomBytes(32));
      final b = EventKeys(crypto, crypto.randomBytes(32));
      expect(a.advertisedService(7), isNot(b.advertisedService(7)));
      expect(a.gattService, isNot(b.gattService));
      expect(a.inboxCharacteristic, isNot(b.inboxCharacteristic));
    });

    test('on cherche la période précédente, courante et suivante', () {
      final keys = EventKeys(crypto, crypto.randomBytes(32));
      final now = DateTime.utc(2026, 10, 18, 12, 7);
      final period = EventKeys.periodOf(now);
      final scanned = keys.servicesToScan(now);
      expect(scanned, hasLength(3));
      expect(scanned[1], keys.advertisedService(period));
      // Un voisin dont l'horloge avance ou retarde de 15 minutes est retrouvé.
      String key(Uint8List bytes) => bytes.join(',');
      final scannedKeys = scanned.map(key).toList();
      expect(scannedKeys, contains(key(keys.advertisedService(period + 1))));
      expect(scannedKeys, contains(key(keys.advertisedService(period - 1))));
    });

    test('l\'identifiant annoncé ne ressemble à aucun identifiant fixe de l\'appli', () {
      final hits = <String>{};
      for (var i = 0; i < 20; i++) {
        final keys = EventKeys(crypto, crypto.randomBytes(32));
        hits.add(keys.advertisedService(1).join(','));
      }
      expect(hits, hasLength(20));
    });
  });

  group('trame', () {
    test('aller-retour', () {
      final frame = Frame(
        ttl: 5,
        groupTag: crypto.randomBytes(16),
        sealed: crypto.randomBytes(200),
      );
      final parsed = Frame.parse(frame.encode(), minSealedLength: 100)!;
      expect(parsed.ttl, 5);
      expect(parsed.groupTag, frame.groupTag);
      expect(parsed.sealed, frame.sealed);
    });

    test('le TTL n\'entre pas dans les données authentifiées', () {
      final frame = Frame(ttl: 5, groupTag: crypto.randomBytes(16), sealed: crypto.randomBytes(200));
      expect(frame.associatedData, frame.withTtl(2).associatedData);
    });

    test('trames malformées : null, jamais d\'exception', () {
      expect(Frame.parse(Uint8List(0), minSealedLength: 10), isNull);
      expect(Frame.parse(Uint8List(5), minSealedLength: 10), isNull);
      expect(Frame.parse(Uint8List(Frame.maxLength + 1), minSealedLength: 10), isNull);
      final wrongVersion = Frame(ttl: 1, groupTag: Uint8List(16), sealed: Uint8List(50)).encode()..[0] = 9;
      expect(Frame.parse(wrongVersion, minSealedLength: 10), isNull);
    });
  });

  group('flux d\'octets', () {
    test('trames recollées quel que soit le découpage', () {
      final frames = [
        crypto.randomBytes(300),
        crypto.randomBytes(1),
        crypto.randomBytes(500),
      ];
      final stream = BytesBuilder();
      for (final f in frames) {
        stream.add(withLength(f));
      }
      final bytes = stream.toBytes();
      for (final size in [1, 2, 7, 20, 100, 512, 5000]) {
        final assembler = FrameAssembler();
        final got = <Uint8List>[];
        for (final chunk in chunksOf(bytes, size)) {
          got.addAll(assembler.add(chunk));
        }
        expect(got, hasLength(3), reason: 'morceaux de $size');
        for (var i = 0; i < 3; i++) {
          expect(got[i], frames[i], reason: 'trame $i, morceaux de $size');
        }
      }
    });

    test('longueur absurde : le flux est refusé', () {
      expect(
        () => FrameAssembler().add(Uint8List.fromList([0xff, 0xff, 1, 2, 3])),
        throwsA(isA<FrameStreamError>()),
      );
      expect(
        () => FrameAssembler().add(Uint8List.fromList([0, 0, 1])),
        throwsA(isA<FrameStreamError>()),
      );
    });
  });

  group('signature et remplissage', () {
    test('une signature valide passe, modifiée elle échoue', () {
      final pair = crypto.newSigningKeyPair();
      final message = Uint8List.fromList([1, 2, 3, 4]);
      final signature = crypto.sign(message, pair.secretKey);
      expect(crypto.verify(message, signature, pair.publicKey), isTrue);
      expect(crypto.verify(Uint8List.fromList([1, 2, 3, 5]), signature, pair.publicKey), isFalse);
      final broken = Uint8List.fromList(signature)..[0] ^= 1;
      expect(crypto.verify(message, broken, pair.publicKey), isFalse);
      expect(crypto.verify(message, signature, crypto.newSigningKeyPair().publicKey), isFalse);
    });

    test('longueurs absurdes : faux, sans exception', () {
      expect(crypto.verify(Uint8List(3), Uint8List(3), Uint8List(3)), isFalse);
    });

    test('remplissage : taille multiple de 64 et retrouvée', () {
      for (final length in [1, 63, 64, 65, 200]) {
        final data = crypto.randomBytes(length);
        final padded = crypto.pad(data);
        expect(padded.length % MeshCrypto.padBlock, 0);
        expect(crypto.unpad(padded), data);
      }
      expect(crypto.unpad(Uint8List(64)), isNull);
    });
  });
}
