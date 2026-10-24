import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/organizer_tool.dart';

import 'http_source.dart';

/// `dart run tool/organizer/organizer.dart <commande> ...`
/// Voir `dart run tool/organizer/organizer.dart help`.
Future<void> main(List<String> args) async {
  final crypto = MeshCrypto(await VaultCrypto.create());
  exit(await runOrganizerTool(args, crypto: crypto, openRemote: HttpRangeSource.openSource));
}
