import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Garde-fou : l'appli ne doit jamais pouvoir parler au réseau, ni embarquer de
/// télémétrie. Si un de ces tests casse, c'est que quelqu'un a ajouté une
/// dépendance ou une permission qui change la promesse faite aux gens.
void main() {
  test('le manifeste de production n\'a aucune permission réseau', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest.contains('android.permission.INTERNET'), isFalse);
    // Une bibliothèque (caméra, Bluetooth) peut ajouter ACCESS_NETWORK_STATE
    // d'office : le manifeste doit la retirer explicitement.
    expect(
      RegExp(r'ACCESS_NETWORK_STATE"\s+tools:node="remove"').hasMatch(manifest),
      isTrue,
    );
  });

  test('les permissions ajoutées d\'office et inutiles sont retirées', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final permission in [
      'RECORD_AUDIO',
      'READ_EXTERNAL_STORAGE',
      'WRITE_EXTERNAL_STORAGE',
    ]) {
      expect(
        RegExp('$permission"\\s+tools:node="remove"').hasMatch(manifest),
        isTrue,
        reason: permission,
      );
    }
  });

  test('pas de sauvegarde cloud des données', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest.contains('android:allowBackup="false"'), isTrue);
  });

  test('seules les dépendances prévues sont déclarées', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final start = lines.indexOf('dependencies:');
    final declared = <String>{};
    for (final line in lines.skip(start + 1)) {
      if (line.isNotEmpty && !line.startsWith(' ')) break;
      final match = RegExp(r'^  ([a-z_0-9]+):').firstMatch(line);
      if (match != null) declared.add(match.group(1)!);
    }
    expect(
      declared,
      {
        'flutter',
        'flutter_localizations',
        'sodium',
        'path_provider',
        'bluetooth_low_energy',
        'camera',
        'zxing2',
      },
    );
  });

  test('aucune bibliothèque de télémétrie ou de requêtes HTTP dans le graphe', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final packages = RegExp(r'^  ([a-z_0-9]+):$', multiLine: true)
        .allMatches(lock)
        .map((m) => m.group(1)!)
        .toSet();
    const forbiddenFragments = [
      'firebase',
      'sentry',
      'crashlytics',
      'analytics',
      'mixpanel',
      'amplitude',
      'appsflyer',
      'posthog',
      'bugsnag',
      'datadog',
      'google_mobile_ads',
      'dio',
    ];
    const forbiddenExact = {'http', 'web_socket', 'web_socket_channel'};
    for (final name in packages) {
      expect(forbiddenExact.contains(name), isFalse, reason: name);
      for (final fragment in forbiddenFragments) {
        expect(name.contains(fragment), isFalse, reason: name);
      }
    }
  });
}
