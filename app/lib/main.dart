import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';
import 'crypto/vault_crypto.dart';
import 'mesh/alert_signal.dart';
import 'mesh/ble_transport.dart';
import 'mesh/keep_alive.dart';
import 'mesh/compass.dart';
import 'mesh/location_provider.dart';
import 'mesh/mesh_controller.dart';
import 'mesh/mesh_crypto.dart';
import 'mesh/torch.dart';
import 'organizer/file_picker.dart';
import 'share/app_sharer.dart';
import 'ui/app.dart';
import 'vault/hardware_secret.dart';
import 'vault/vault_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait seulement : la boussole compte les angles depuis le haut du
  // téléphone, qui doit rester le haut de l'écran.
  await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  final crypto = await VaultCrypto.create();
  final meshCrypto = MeshCrypto(crypto);
  final directory = await getApplicationSupportDirectory();
  final controller = AppController(
    store: VaultStore(
      crypto: crypto,
      hardware: PlatformHardwareSecretStore(),
      directory: directory,
    ),
    mapsDirectory: Directory('${directory.path}${Platform.pathSeparator}maps'),
    filePicker: const PlatformFilePicker(),
    appSharer: const PlatformAppSharer(),
    meshFactory: (session) => MeshController(
      crypto: meshCrypto,
      session: session,
      transport: BleMeshTransport(keepAlive: PlatformKeepAlive()),
      location: PlatformLocationProvider(),
      compass: const PlatformCompass(),
      torch: const PlatformTorch(),
      signal: PlatformAlertSignal(),
    ),
  );
  await controller.start();
  runApp(CortegeApp(controller: controller));
}
