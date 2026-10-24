// Sous Windows, le build de libsodium lancé par `dart run` échoue parfois (voir
// le README). `flutter test` passe, lui, après tool\windows\prepare_libsodium.ps1 :
//
//   flutter test tool/organizer/runner.dart --dart-define=ORG_ARGS="event --key a.cle --in e.json --out e.cortege"
//
// Les arguments sont séparés par des espaces ; mettre entre guillemets simples
// les valeurs qui en contiennent, par exemple --name 'Collectif Eau'.
import 'dart:io';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/organizer/organizer_tool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'http_source.dart';

void main() {
  test('outil de l\'organisateur', () async {
    // Les tests Flutter coupent le réseau ; l'outil de l'organisateur en a besoin
    // pour lire une carte en ligne.
    HttpOverrides.global = null;
    const raw = String.fromEnvironment('ORG_ARGS');
    final args = RegExp(r"'([^']*)'|(\S+)")
        .allMatches(raw)
        .map((m) => m.group(1) ?? m.group(2)!)
        .toList();
    final lines = <String>[];
    final code = await runOrganizerTool(
      args,
      crypto: MeshCrypto(await VaultCrypto.create()),
      openRemote: HttpRangeSource.openSource,
      out: (line) {
        lines.add(line);
        // ignore: avoid_print
        print(line);
      },
    );
    expect(code, 0, reason: lines.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
