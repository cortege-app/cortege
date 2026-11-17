import 'dart:io';

import 'package:flutter/widgets.dart';

/// Langues de l'appli. L'anglais est la langue par défaut ; le français se
/// choisit dans les réglages (ou au premier lancement) et reste mémorisé.
enum AppLanguage {
  en('English'),
  fr('Français');

  const AppLanguage(this.nativeName);

  /// Le nom de la langue dans cette langue, pour le sélecteur.
  final String nativeName;

  Locale get locale => Locale(name);
}

/// La langue courante, partagée par toute l'appli.
///
/// Elle est gardée dans un petit fichier en clair à côté du coffre : il faut la
/// connaître avant l'ouverture du coffre (écran de code, premier lancement), et
/// elle ne dit rien de ce que contient l'appli.
class Language {
  Language._();

  static const defaultLanguage = AppLanguage.en;

  static final ValueNotifier<AppLanguage> notifier = ValueNotifier(defaultLanguage);

  static AppLanguage get current => notifier.value;

  static bool get isFrench => current == AppLanguage.fr;

  static File? _file;

  /// Lit la langue mémorisée dans [directory]. Sans fichier, ou s'il est
  /// illisible, on reste sur la langue par défaut.
  static Future<void> load(Directory directory) async {
    final file = File('${directory.path}${Platform.pathSeparator}language');
    _file = file;
    try {
      if (!await file.exists()) return;
      final saved = (await file.readAsString()).trim();
      for (final language in AppLanguage.values) {
        if (language.name == saved) notifier.value = language;
      }
    } on FileSystemException {
      // Langue par défaut.
    }
  }

  /// Change la langue tout de suite et la mémorise pour les prochains lancements.
  static Future<void> set(AppLanguage language) async {
    notifier.value = language;
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(language.name, flush: true);
    } on FileSystemException {
      // La langue tient jusqu'à la fermeture de l'appli.
    }
  }
}

/// Le texte dans la langue courante : l'anglais d'abord, le français ensuite.
///
///     Text(tr('Settings', 'Réglages'))
String tr(String en, String fr) => Language.isFrench ? fr : en;
