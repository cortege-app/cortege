import 'dart:async';

import 'package:cortege/l10n/language.dart';

/// Lu par `flutter test` avant chaque fichier de test. Les tests existants
/// cherchent les textes français de l'interface : ils tournent donc en
/// français, alors que l'appli démarre en anglais par défaut.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Language.notifier.value = AppLanguage.fr;
  await testMain();
}
