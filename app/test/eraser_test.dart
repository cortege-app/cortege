import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/vault/eraser.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

void main() {
  final start = DateTime(2026, 10, 18, 12);

  VaultRecord record(String id, DateTime createdAt, {DateTime? expiresAt}) =>
      VaultRecord(id: id, kind: 'test', createdAt: createdAt, expiresAt: expiresAt);

  group('sweepExpired', () {
    test('retire ce qui a dépassé la durée, garde le reste', () {
      final state = VaultState(role: VaultRole.real, ttl: const Duration(hours: 24))
        ..records.addAll([
          record('vieux', start.subtract(const Duration(hours: 25))),
          record('recent', start.subtract(const Duration(hours: 2))),
        ]);

      expect(sweepExpired(state, start), 1);
      expect(state.records.map((r) => r.id), ['recent']);
    });

    test('pile à l\'échéance, c\'est périmé', () {
      final state = VaultState(role: VaultRole.real, ttl: const Duration(hours: 24))
        ..records.add(record('a', start.subtract(const Duration(hours: 24))));
      expect(sweepExpired(state, start), 1);
    });

    test('une minute avant l\'échéance, c\'est gardé', () {
      final state = VaultState(role: VaultRole.real, ttl: const Duration(hours: 24))
        ..records.add(
          record('a', start.subtract(const Duration(hours: 23, minutes: 59))),
        );
      expect(sweepExpired(state, start), 0);
    });

    test('l\'échéance propre à l\'enregistrement s\'applique aussi', () {
      final state = VaultState(role: VaultRole.real, ttl: const Duration(hours: 72))
        ..records.add(
          record(
            'parcours',
            start.subtract(const Duration(hours: 1)),
            expiresAt: start.subtract(const Duration(minutes: 1)),
          ),
        );
      expect(sweepExpired(state, start), 1);
    });

    test('raccourcir la durée efface tout de suite ce qui dépasse', () {
      final state = VaultState(role: VaultRole.real)
        ..records.add(record('a', start.subtract(const Duration(hours: 5))));
      expect(sweepExpired(state, start), 0);

      state.ttl = const Duration(hours: 1);
      expect(sweepExpired(state, start), 1);
      expect(state.records, isEmpty);
    });

    test('coffre vide : rien à faire', () {
      expect(sweepExpired(VaultState(role: VaultRole.decoy), start), 0);
    });
  });

  group('AutoEraser', () {
    late VaultCrypto crypto;
    late Directory dir;
    late VaultStore store;

    setUpAll(() async {
      crypto = await VaultCrypto.create();
    });

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cortege_eraser_');
      store = VaultStore(
        crypto: crypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('l\'effacement est écrit sur disque : rouvrir le coffre ne ramène rien', () async {
      final session = await store.create(pin: '483920');
      session.state.records.add(record('a', start));
      await session.save();

      var now = start.add(const Duration(hours: 23));
      final eraser = AutoEraser(session, now: () => now);
      expect(await eraser.sweepNow(), 0);

      now = start.add(const Duration(hours: 25));
      expect(await eraser.sweepNow(), 1);
      session.lock();

      final reopened = await store.unlock('483920');
      expect(reopened!.state.records, isEmpty);
      reopened.lock();
    });

    test('rien à effacer : le fichier n\'est pas réécrit', () async {
      final session = await store.create(pin: '483920');
      final before = store.slotFile(session.slot).readAsBytesSync();

      final eraser = AutoEraser(session, now: () => start);
      expect(await eraser.sweepNow(), 0);

      expect(store.slotFile(session.slot).readAsBytesSync(), before);
      session.lock();
    });

    test('le minuteur efface tout seul', () async {
      final session = await store.create(pin: '483920');
      session.state.records.add(record('a', start));
      final eraser = AutoEraser(
        session,
        now: () => start.add(const Duration(days: 2)),
        interval: const Duration(milliseconds: 20),
      )..start();

      await Future<void>.delayed(const Duration(milliseconds: 300));
      eraser.stop();

      expect(session.state.records, isEmpty);
      session.lock();
    });
  });
}
