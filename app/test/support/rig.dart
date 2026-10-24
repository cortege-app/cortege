import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/mesh_controller.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/vault/vault_store.dart';

import 'fake_location.dart';
import 'fake_transport.dart';
import 'memory_hardware.dart';

/// Un téléphone de test complet : coffre, maillage, fausse radio, fausse
/// position et vibreur qui compte.
class Rig {
  Rig({
    required this.name,
    required this.pin,
    required this.store,
    required this.session,
    required this.mesh,
    required this.transport,
    required this.location,
    required this.signal,
  });

  final String name;
  final String pin;
  final VaultStore store;
  final dynamic session;
  final MeshController mesh;
  final FakeTransport transport;
  final FakeLocation location;
  final CountingSignal signal;
}

class RigFactory {
  RigFactory(this.vaultCrypto, this.air, this.now);

  final VaultCrypto vaultCrypto;
  final FakeAir air;
  final DateTime Function() now;
  final dirs = <Directory>[];
  final meshes = <MeshController>[];

  Future<Rig> create(
    String name, {
    String pin = '483920',
    bool named = true,
    GeoPoint? at,
    Duration silenceTolerance = Duration.zero,
    Duration buddyWatchEvery = const Duration(milliseconds: 20),
    Duration firstCheckInDelay = const Duration(milliseconds: 10),
    Duration retryInterval = const Duration(seconds: 8),
    List<Duration> medicResendDelays = const [Duration(seconds: 3600)],
  }) async {
    final dir = Directory.systemTemp.createTempSync('cortege_rig_$name');
    dirs.add(dir);
    final store = VaultStore(
      crypto: vaultCrypto,
      hardware: MemoryHardwareSecretStore(),
      directory: dir,
      kdf: KdfParams.cheapForTests,
    );
    final session = await store.create(pin: pin);
    final transport = FakeTransport(air, name);
    final location = FakeLocation(at);
    final signal = CountingSignal();
    final mesh = MeshController(
      crypto: MeshCrypto(vaultCrypto),
      session: session,
      transport: transport,
      now: now,
      jitter: false,
      location: location,
      signal: signal,
      silenceTolerance: silenceTolerance,
      buddyWatchEvery: buddyWatchEvery,
      firstCheckInDelay: firstCheckInDelay,
      retryInterval: retryInterval,
      medicResendDelays: medicResendDelays,
    );
    meshes.add(mesh);
    await mesh.start();
    if (named) await mesh.setDisplayName(name);
    return Rig(
      name: name,
      pin: pin,
      store: store,
      session: session,
      mesh: mesh,
      transport: transport,
      location: location,
      signal: signal,
    );
  }

  /// Rouvre le coffre d'un téléphone après un verrouillage complet.
  Future<Rig> reopen(Rig old) async {
    old.mesh.stop();
    old.session.lock();
    final session = (await old.store.unlock(old.pin))!;
    final mesh = MeshController(
      crypto: MeshCrypto(vaultCrypto),
      session: session,
      transport: old.transport,
      now: now,
      jitter: false,
      location: old.location,
      signal: old.signal,
      silenceTolerance: Duration.zero,
      buddyWatchEvery: const Duration(milliseconds: 20),
      firstCheckInDelay: const Duration(milliseconds: 10),
    );
    meshes.add(mesh);
    await mesh.start();
    return Rig(
      name: old.name,
      pin: old.pin,
      store: old.store,
      session: session,
      mesh: mesh,
      transport: old.transport,
      location: old.location,
      signal: old.signal,
    );
  }

  Future<void> close() async {
    for (final mesh in meshes) {
      mesh.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final dir in dirs) {
      // Une écriture du coffre peut encore tenir un fichier : on réessaie un peu.
      for (var attempt = 0; attempt < 10 && dir.existsSync(); attempt++) {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }
}
