import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late VaultCrypto vaultCrypto;
  late MeshCrypto crypto;
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  setUpAll(() async {
    vaultCrypto = await VaultCrypto.create();
    crypto = MeshCrypto(vaultCrypto);
  });

  test('ouvrir le coffre leurre ne supprime pas la carte du vrai coffre', () async {
    final dir = Directory.systemTemp.createTempSync('cortege_maps');
    final maps = Directory('${dir.path}/maps')..createSync();
    // Une carte de l'ancienne disposition (à la racine) : elle disparaît.
    File('${maps.path}/ancienne.ctm').writeAsBytesSync([1, 2, 3]);
    final controller = AppController(
      store: VaultStore(
        crypto: vaultCrypto,
        hardware: MemoryHardwareSecretStore(),
        directory: dir,
        kdf: KdfParams.cheapForTests,
      ),
      mapsDirectory: maps,
    );
    addTearDown(() async {
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Un fichier encore tenu : le dossier temporaire reste.
      }
    });
    await controller.start();
    await controller.setUp(pin: '483920', duressPin: '739104');

    // Dans le vrai coffre : un organisateur, un événement et sa carte.
    final pair = crypto.newSigningKeyPair();
    final reference = MapReference(
      hash: _hex(await crypto.hashFile(fixture)),
      size: fixture.lengthSync(),
      name: 'paris.pmtiles',
    );
    final service = controller.organizer!;
    await service.trust(OrganizerInvite(name: 'Collectif', publicKey: pair.publicKey));
    await service.importPacket(
      OrganizerPacket.sign(
        crypto: crypto,
        publicKey: pair.publicKey,
        secretKey: pair.secretKey,
        payload: OrganizerPayload(
          name: 'Marche',
          issued: DateTime.now().subtract(const Duration(minutes: 5)),
          expires: DateTime.now().add(const Duration(hours: 8)),
          map: reference,
        ),
      ),
    );
    await service.importMap(fixture);
    List<File> mapFiles() => maps
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.ctm'))
        .toList();
    expect(mapFiles(), hasLength(1));
    expect(File('${maps.path}/ancienne.ctm').existsSync(), isFalse, reason: 'la carte d\'avant est supprimée');

    // Le code de contrainte ouvre l'autre coffre : il ne voit rien, et ne touche à rien.
    controller.lock();
    expect(await controller.unlock('739104'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(controller.organizer!.mapInfo, isNull);
    expect(controller.organizer!.packets, isEmpty);
    expect(mapFiles(), hasLength(1), reason: 'la carte du vrai coffre est toujours là');

    // Le vrai code retrouve la carte, lisible.
    controller.lock();
    expect(await controller.unlock('483920'), isTrue);
    expect(controller.organizer!.mapInfo!.hash, reference.hash);
    final archive = (await controller.organizer!.openMap())!;
    expect(archive.header.maxZoom, greaterThan(0));
    await archive.close();
  });
}
