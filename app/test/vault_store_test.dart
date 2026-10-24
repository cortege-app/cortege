import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/vault/pin_policy.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

const realPin = '483920';
const duressPin = '715204';

void main() {
  late VaultCrypto crypto;
  late MemoryHardwareSecretStore hardware;
  late Directory dir;
  late VaultStore store;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
  });

  setUp(() {
    hardware = MemoryHardwareSecretStore();
    dir = Directory.systemTemp.createTempSync('cortege_vault_');
    store = VaultStore(
      crypto: crypto,
      hardware: hardware,
      directory: dir,
      kdf: KdfParams.cheapForTests,
    );
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  VaultRecord note(String id) => VaultRecord(
        id: id,
        kind: 'test',
        createdAt: DateTime.now(),
        data: {'texte': 'point de rendez-vous secret'},
      );

  group('deux codes, deux coffres', () {
    test('le vrai code ouvre le vrai coffre, le code de contrainte le leurre', () async {
      (await store.create(pin: realPin, duressPin: duressPin)).lock();

      final real = await store.unlock(realPin);
      final decoy = await store.unlock(duressPin);

      expect(real?.role, VaultRole.real);
      expect(decoy?.role, VaultRole.decoy);
      real?.lock();
      decoy?.lock();
    });

    test('un mauvais code n\'ouvre rien', () async {
      (await store.create(pin: realPin, duressPin: duressPin)).lock();
      expect(await store.unlock('000999'), isNull);
    });

    test('le leurre est vide et ne montre rien du vrai coffre', () async {
      final session = await store.create(pin: realPin, duressPin: duressPin);
      session.state.records.add(note('a'));
      await session.save();
      session.lock();

      final decoy = await store.unlock(duressPin);
      expect(decoy!.state.records, isEmpty);
      decoy.lock();

      final real = await store.unlock(realPin);
      expect(real!.state.records.map((r) => r.id), ['a']);
      real.lock();
    });

    test('les deux fichiers ont la même taille et aucun texte lisible', () async {
      final session = await store.create(pin: realPin, duressPin: duressPin);
      session.state.records.add(note('a'));
      await session.save();
      session.lock();

      final files = [store.slotFile(0), store.slotFile(1)];
      expect(files[0].lengthSync(), files[1].lengthSync());
      expect(files[0].lengthSync(), store.fileSize);
      for (final file in files) {
        final text = String.fromCharCodes(file.readAsBytesSync());
        expect(text.contains('role'), isFalse);
        expect(text.contains('decoy'), isFalse);
        expect(text.contains('rendez-vous'), isFalse);
      }
    });

    test('sans code de contrainte, le second emplacement a la même taille et ne s\'ouvre pas', () async {
      (await store.create(pin: realPin)).lock();

      expect(store.slotFile(0).lengthSync(), store.slotFile(1).lengthSync());
      expect(hardware.secrets.keys, unorderedEquals([0, 1]));
      expect(await store.unlock(duressPin), isNull);
    });

    test('code de contrainte ajouté plus tard', () async {
      final real = await store.create(pin: realPin);
      await real.setDuressPin(duressPin);
      real.lock();

      final decoy = await store.unlock(duressPin);
      expect(decoy?.role, VaultRole.decoy);
      decoy?.lock();
      final again = await store.unlock(realPin);
      expect(again?.role, VaultRole.real);
      again?.lock();
    });

    test('le leurre ne peut pas régler de code de contrainte', () async {
      (await store.create(pin: realPin, duressPin: duressPin)).lock();
      final decoy = (await store.unlock(duressPin))!;
      expect(() => decoy.setDuressPin('260413'), throwsStateError);
      decoy.lock();
    });
  });

  group('codes refusés', () {
    test('code trop faible à la création', () async {
      expect(
        () => store.create(pin: '123456'),
        throwsA(isA<PinRejected>()),
      );
      expect(await store.isInitialized(), isFalse);
    });

    test('code de contrainte identique au code', () async {
      expect(
        () => store.create(pin: realPin, duressPin: realPin),
        throwsA(isA<PinRejected>()),
      );
    });

    test('code de contrainte identique au vrai code, réglé plus tard', () async {
      final real = await store.create(pin: realPin);
      expect(() => real.setDuressPin(realPin), throwsA(isA<PinRejected>()));
      real.lock();
    });

    test('changer de code vers l\'autre code est refusé', () async {
      final real = await store.create(pin: realPin, duressPin: duressPin);
      expect(() => real.changePin(duressPin), throwsA(isA<PinRejected>()));
      real.lock();
    });
  });

  group('changer de code', () {
    test('l\'ancien code ne marche plus, le nouveau si, les données restent', () async {
      final session = await store.create(pin: realPin, duressPin: duressPin);
      session.state.records.add(note('a'));
      await session.changePin('930174');
      session.lock();

      expect(await store.unlock(realPin), isNull);
      final reopened = await store.unlock('930174');
      expect(reopened!.state.records.map((r) => r.id), ['a']);
      reopened.lock();
      final decoy = await store.unlock(duressPin);
      expect(decoy?.role, VaultRole.decoy);
      decoy?.lock();
    });
  });

  group('effacement du coffre', () {
    test('tout effacer supprime fichiers et secrets', () async {
      (await store.create(pin: realPin, duressPin: duressPin)).lock();
      await store.wipe();

      expect(await store.isInitialized(), isFalse);
      expect(hardware.secrets, isEmpty);
      expect(() => store.unlock(realPin), throwsA(isA<VaultUnrecoverable>()));
    });

    test('des fichiers récupérés avant l\'effacement restent illisibles, même avec le bon code', () async {
      final session = await store.create(pin: realPin, duressPin: duressPin);
      session.state.records.add(note('a'));
      await session.save();
      session.lock();
      final copies = [
        for (final slot in [0, 1]) store.slotFile(slot).readAsBytesSync(),
      ];

      await store.wipe();
      for (final slot in [0, 1]) {
        store.slotFile(slot).writeAsBytesSync(copies[slot]);
      }

      expect(() => store.unlock(realPin), throwsA(isA<VaultUnrecoverable>()));
    });

    test('avec un autre secret matériel, le bon code ne suffit pas', () async {
      (await store.create(pin: realPin)).lock();
      for (final slot in [0, 1]) {
        await hardware.store(slot, crypto.randomBytes(32));
      }
      expect(await store.unlock(realPin), isNull);
    });

    test('secrets matériels perdus : coffre déclaré irrécupérable', () async {
      (await store.create(pin: realPin)).lock();
      await hardware.eraseAll();
      expect(() => store.unlock(realPin), throwsA(isA<VaultUnrecoverable>()));
    });
  });

  group('intégrité', () {
    test('un octet modifié dans le fichier : le coffre ne s\'ouvre plus', () async {
      final session = await store.create(pin: realPin);
      final slot = session.slot;
      session.lock();

      final file = store.slotFile(slot);
      final bytes = file.readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 1;
      file.writeAsBytesSync(bytes);

      expect(await store.unlock(realPin), isNull);
    });

    test('fichier tronqué : ignoré sans planter', () async {
      final session = await store.create(pin: realPin);
      final slot = session.slot;
      session.lock();
      store.slotFile(slot).writeAsBytesSync(Uint8List(100));

      expect(await store.unlock(realPin), isNull);
    });

    test('contenu trop gros : refusé', () async {
      final session = await store.create(pin: realPin);
      session.state.records.add(
        VaultRecord(
          id: 'enorme',
          kind: 'test',
          createdAt: DateTime.now(),
          data: {'blob': 'x' * VaultStore.plainSize},
        ),
      );
      expect(session.save, throwsA(isA<VaultFullException>()));
      session.lock();
    });
  });
}
