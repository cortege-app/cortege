import 'package:flutter/services.dart';

import '../l10n/language.dart';

import 'fiche.dart';

enum FicheCategory { droits, secours }

/// Les fiches sont embarquées dans l'appli (dossier `assets/content/`) : rien
/// n'est téléchargé, tout marche sans réseau. L'ordre ci-dessous est l'ordre
/// d'affichage.
class ContentCatalog {
  ContentCatalog({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  static const ids = {
    FicheCategory.droits: ['controle-identite', 'fouille', 'garde-a-vue', 'contacts'],
    FicheCategory.secours: ['urgences', 'lacrymogenes', 'chaleur', 'malaise', 'blessure'],
  };

  /// Les fiches françaises sont à la racine de `assets/content/`, leurs
  /// traductions anglaises dans `assets/content/en/`.
  static String assetPath(FicheCategory category, String id, [AppLanguage? language]) =>
      switch (language ?? Language.current) {
        AppLanguage.fr => 'assets/content/${category.name}/$id.txt',
        AppLanguage.en => 'assets/content/en/${category.name}/$id.txt',
      };

  Future<Fiche> load(FicheCategory category, String id) async =>
      parseFiche(id, await _bundle.loadString(assetPath(category, id)));

  Future<List<Fiche>> loadAll(FicheCategory category) =>
      Future.wait([for (final id in ids[category]!) load(category, id)]);
}
