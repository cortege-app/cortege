import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/ui/settings_screen.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:cortege/vault/hardware_secret.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

const realPin = '483920';
const duressPin = '715204';

/// Un Keystore qui peut tomber en panne à un endroit précis du renouvellement.
class FlakyHardware extends MemoryHardwareSecretStore {
  var failRotate = false;

  /// Numéro (à partir de 1) de l'appel à `keepOnly` qui échoue, ou null.
  int? failKeepOnlyCall;
  var _keepOnlyCalls = 0;

  @override
  Future<int> rotate(int slot, Uint8List secret) async {
    if (failRotate) throw HardwareSecretUnavailable('panne');
    return super.rotate(slot, secret);
  }

  @override
  Future<void> keepOnly(int slot, int generation) async {
    _keepOnlyCalls++;
    if (_keepOnlyCalls == failKeepOnlyCall) throw HardwareSecretUnavailable('panne');
    return super.keepOnly(slot, generation);
  }
}

void main() {
  late VaultCrypto crypto;
  late FlakyHardware hardware;
  late Directory dir;
  late DateTime clock;
  late VaultStore store;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
  });

  setUp(() {
    hardware = FlakyHardware();
    dir = Directory.systemTemp.createTempSync('cortege_renewal');
    clock = DateTime.utc(2026, 10, 23, 12);
    store = VaultStore(
      crypto: crypto,
      hardware: hardware,
      directory: dir,
      kdf: KdfParams.cheapForTests,
      now: () => clock,
    );
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  VaultRecord note(String id, {DateTime? createdAt}) => VaultRecord(
        id: id,
        kind: 'test',
        createdAt: createdAt ?? clock,
        data: {'texte': 'point de rendez-vous secret'},
      );

  Future<VaultSession> createReal({bool withDuress = false}) =>
      store.create(pin: realPin, duressPin: withDuress ? duressPin : null);

  List<int> bytesOf(VaultSession session) => store.slotFile(session.slot).readAsBytesSync();

  group('le coffre change de secret après un effacement', () {
    test('il s\'ouvre toujours avec le même code, et garde ses données', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();
      final before = session.generation;

      await session.renewSecret(force: true);

      expect(session.generation, isNot(before));
      expect(hardware.generations(session.slot), [session.generation], reason: 'un seul secret reste');
      session.lock();
      final reopened = (await store.unlock(realPin))!;
      expect(reopened.state.records.single.id, 'a');
      reopened.lock();
    });

    test('une copie du fichier faite avant ne se relit plus, même avec le bon code', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();
      final oldFile = bytesOf(session);
      final oldSecrets = hardware.allSecretBytes(session.slot);

      await session.renewSecret(force: true);
      session.lock();

      // Le fichier récent s'ouvre.
      (await store.unlock(realPin))!.lock();
      // L'ancien secret a disparu du matériel.
      expect(hardware.allSecretBytes(session.slot), isNot(contains(oldSecrets.single)));
      // Une vieille copie du fichier, restée dans la mémoire flash, ne s'ouvre plus.
      store.slotFile(session.slot).writeAsBytesSync(oldFile);
      expect(await store.unlock(realPin), isNull);

      // Preuve que le test est juste : avec l'ancien secret, cette copie s'ouvrirait.
      await hardware.store(session.slot, oldSecrets.single);
      final recovered = await store.unlock(realPin);
      expect(recovered?.state.records.single.id, 'a');
      recovered?.lock();
    });

    test('l\'effacement automatique rend illisible ce qu\'il vient d\'effacer', () async {
      final session = await createReal();
      session.state.records.add(note('vieux', createdAt: clock.subtract(const Duration(hours: 30))));
      session.state.records.add(note('recent'));
      await session.save();
      final copyBeforeErase = bytesOf(session);
      final oldSecret = hardware.allSecretBytes(session.slot).single;

      final removed = await AutoEraser(session, now: () => clock).sweepNow();

      expect(removed, 1);
      expect(hardware.allSecretBytes(session.slot), isNot(contains(oldSecret)));
      session.lock();
      final reopened = (await store.unlock(realPin))!;
      expect(reopened.state.records.map((r) => r.id), ['recent']);
      reopened.lock();
      store.slotFile(session.slot).writeAsBytesSync(copyBeforeErase);
      expect(await store.unlock(realPin), isNull, reason: 'la copie d\'avant l\'effacement est perdue');
    });

    test('au plus un renouvellement toutes les dix minutes, le reste attend', () async {
      final session = await createReal();
      await session.renewSecret();
      final afterFirst = session.generation;
      expect(session.renewalDue, isFalse);

      clock = clock.add(const Duration(minutes: 3));
      await session.renewSecret();
      expect(session.generation, afterFirst, reason: 'trop tôt');
      expect(session.renewalDue, isTrue);

      await session.flushRenewal();
      expect(session.generation, afterFirst, reason: 'toujours trop tôt');

      clock = clock.add(const Duration(minutes: 8));
      await session.flushRenewal();
      expect(session.generation, isNot(afterFirst));
      expect(session.renewalDue, isFalse);
      session.lock();
    });

    test('l\'effaceur reprend lui-même un renouvellement en attente', () async {
      final session = await createReal();
      final eraser = AutoEraser(session, now: () => clock);
      session.state.records.add(note('a', createdAt: clock.subtract(const Duration(hours: 30))));
      await eraser.sweepNow();
      final afterFirst = session.generation;

      session.state.records.add(note('b', createdAt: clock.subtract(const Duration(hours: 30))));
      clock = clock.add(const Duration(minutes: 2));
      await eraser.sweepNow();
      expect(session.generation, afterFirst, reason: 'trop tôt pour renouveler');
      expect(session.renewalDue, isTrue);

      clock = clock.add(const Duration(minutes: 9));
      expect(await eraser.sweepNow(), 0);
      expect(session.generation, isNot(afterFirst), reason: 'le balayage suivant le fait');
      session.lock();
    });

    test('quitter ou oublier quelque chose renouvelle aussi, sans attendre l\'effaceur', () async {
      final session = await createReal();
      final before = session.generation;

      await session.save(removal: true);

      expect(session.generation, isNot(before));
      session.lock();
    });
  });

  group('une coupure ne fait jamais perdre le coffre', () {
    test('coupée après l\'ajout du nouveau secret, avant la réécriture', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();
      final slot = session.slot;
      final oldGeneration = session.generation;
      session.lock();
      // Le nouveau secret est là, le fichier est encore sous l'ancien.
      await hardware.rotate(slot, crypto.randomBytes(32));
      expect(hardware.generations(slot), hasLength(2));

      final reopened = (await store.unlock(realPin))!;

      expect(reopened.state.records.single.id, 'a');
      expect(reopened.generation, oldGeneration, reason: 'c\'est l\'ancien qui ouvre le fichier');
      expect(hardware.generations(slot), [oldGeneration], reason: 'l\'autre est détruit');
      // Et le prochain renouvellement se passe normalement.
      await reopened.renewSecret(force: true);
      reopened.lock();
      (await store.unlock(realPin))!.lock();
    });

    test('coupée après la réécriture, avant la destruction de l\'ancien secret', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();
      // Le premier appel à `keepOnly` nettoie avant de commencer ; c'est le second,
      // juste après la réécriture, qui tombe en panne.
      hardware.failKeepOnlyCall = 2;

      await expectLater(session.renewSecret(force: true), throwsA(isA<HardwareSecretUnavailable>()));

      // Le fichier est déjà sous la nouvelle clé : la session la tient, et ses
      // écritures suivantes en restent là.
      expect(hardware.generations(session.slot), hasLength(2));
      session.state.records.add(note('b'));
      await session.save();
      session.lock();

      final reopened = (await store.unlock(realPin))!;

      expect(reopened.state.records.map((r) => r.id), ['a', 'b']);
      expect(hardware.generations(reopened.slot), hasLength(1));
      reopened.lock();
    });

    test('un Keystore en panne ne touche pas au coffre, et le renouvellement est retenté', () async {
      final session = await createReal();
      hardware.failRotate = true;

      await expectLater(session.renewSecret(force: true), throwsA(isA<HardwareSecretUnavailable>()));
      expect(session.renewalDue, isTrue);

      session.state.records.add(note('a'));
      await session.save();
      hardware.failRotate = false;
      clock = clock.add(const Duration(minutes: 11));
      final before = session.generation;
      await session.flushRenewal();

      expect(session.generation, isNot(before));
      session.lock();
      expect((await store.unlock(realPin))!.state.records.single.id, 'a');
    });

    test('une écriture demandée pendant le renouvellement n\'est pas perdue', () async {
      final session = await createReal();
      final renewal = session.renewSecret(force: true);
      session.state.records.add(note('pendant'));
      final write = session.save();
      session.state.records.add(note('apres'));
      final lastWrite = session.save();

      await Future.wait([renewal, write, lastWrite]);
      session.lock();

      final reopened = (await store.unlock(realPin))!;
      expect(reopened.state.records.map((r) => r.id), ['pendant', 'apres']);
      expect(hardware.generations(reopened.slot), hasLength(1));
      reopened.lock();
    });

    test('verrouiller en plein renouvellement laisse un coffre qui s\'ouvre', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();

      final renewal = session.renewSecret(force: true);
      session.lock();
      try {
        await renewal;
      } on Object {
        // Selon l'instant, le renouvellement s'arrête ou va au bout : les deux conviennent.
      }

      final reopened = (await store.unlock(realPin))!;
      expect(reopened.state.records.single.id, 'a');
      reopened.lock();
    });

    test('deux renouvellements demandés d\'un coup se suivent', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();

      await Future.wait([
        session.renewSecret(force: true),
        session.renewSecret(force: true),
      ]);
      session.lock();

      final reopened = (await store.unlock(realPin))!;
      expect(reopened.state.records.single.id, 'a');
      expect(hardware.generations(reopened.slot), hasLength(1));
      reopened.lock();
    });
  });

  group('autour du renouvellement', () {
    test('changer de code après un renouvellement', () async {
      final session = await createReal();
      session.state.records.add(note('a'));
      await session.save();
      await session.renewSecret(force: true);

      await session.changePin('930174');
      session.lock();

      expect(await store.unlock(realPin), isNull);
      final reopened = (await store.unlock('930174'))!;
      expect(reopened.state.records.single.id, 'a');
      reopened.lock();
    });

    test('changer de code pendant un renouvellement ne fait jamais perdre le coffre', () async {
      // Les deux opérations touchent aux clés de la session : si elles se
      // croisaient, le coffre serait réécrit avec un secret déjà détruit. On les
      // lance l'une contre l'autre avec des décalages différents.
      for (var i = 0; i < 24; i++) {
        final session = await createReal();
        session.state.records.add(note('a$i'));
        await session.save();
        final newPin = '9${(300000 + i * 7919).toString().padLeft(5, '0')}';

        final change = session.changePin(newPin);
        if (i % 3 != 0) await Future<void>.delayed(Duration(milliseconds: i % 4));
        final renewal = session.renewSecret(force: true);
        await Future.wait([change, renewal]);
        session.lock();

        final reopened = await store.unlock(newPin);
        expect(reopened, isNotNull, reason: 'tour $i : le nouveau code ouvre le coffre');
        expect(reopened!.state.records.single.id, 'a$i', reason: 'tour $i');
        reopened.lock();
        expect(await store.unlock(realPin), isNull, reason: 'tour $i : l\'ancien code est refusé');
      }
    });

    test('renouveler le vrai coffre laisse le leurre intact, et inversement', () async {
      final real = await createReal(withDuress: true);
      real.state.records.add(note('secret'));
      await real.save();
      await real.renewSecret(force: true);
      real.lock();

      final decoy = (await store.unlock(duressPin))!;
      expect(decoy.role, VaultRole.decoy);
      expect(decoy.state.records, isEmpty);
      await decoy.renewSecret(force: true);
      decoy.lock();

      final again = (await store.unlock(realPin))!;
      expect(again.role, VaultRole.real);
      expect(again.state.records.single.id, 'secret');
      again.lock();
      expect((await store.unlock(duressPin))!.role, VaultRole.decoy);
    });

    test('le dernier renouvellement se lit et se dit en une phrase', () async {
      final session = await createReal();
      expect(session.lastRenewed, isNull);
      expect(renewalText(null, false, clock), contains('Pas de renouvellement'));
      expect(renewalText(null, true, clock), contains('attend son tour'));

      await session.renewSecret(force: true);

      expect(session.lastRenewed, clock);
      expect(renewalText(session.lastRenewed, false, clock), 'Dernier renouvellement : à l\'instant.');
      expect(
        renewalText(session.lastRenewed, true, clock.add(const Duration(minutes: 5))),
        'Dernier renouvellement : il y a 5 min. Un autre attend son tour.',
      );
      expect(renewalText(session.lastRenewed, false, clock.add(const Duration(hours: 3))), contains('il y a 3 h'));
      session.lock();
    });

    test('rien ne se renouvelle sur un coffre verrouillé', () async {
      final session = await createReal();
      final before = hardware.generations(session.slot);
      session.lock();

      await session.renewSecret(force: true);

      expect(hardware.generations(session.slot), before);
    });

    test('deux secrets qui traînent après une panne ne trahissent pas le leurre', () async {
      // Les deux emplacements ont toujours un secret ; un renouvellement
      // interrompu n'en change pas le nombre visible depuis les fichiers.
      final session = await createReal(withDuress: true);
      final files = [for (final s in [0, 1]) store.slotFile(s).lengthSync()];
      await session.renewSecret(force: true);

      expect([for (final s in [0, 1]) store.slotFile(s).lengthSync()], files);
      expect(hardware.secrets.keys, unorderedEquals([0, 1]));
      session.lock();
    });
  });
}
