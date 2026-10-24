import 'dart:io';

import 'package:cortege/content/catalog.dart';
import 'package:cortege/content/fiche.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/disk_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = ContentCatalog(bundle: DiskAssetBundle());

  // Les autres tests lisent les fichiers sur le disque ; celui-ci passe par le
  // vrai chargeur d'assets et vérifie donc que pubspec.yaml les déclare.
  test('les fiches sont bien déclarées comme assets dans pubspec.yaml', () async {
    final fiches = await ContentCatalog().loadAll(FicheCategory.droits);
    expect(fiches, isNotEmpty);
    expect(await ContentCatalog().loadAll(FicheCategory.secours), isNotEmpty);
  });

  test('toutes les fiches prévues par la spec existent', () {
    expect(
      ContentCatalog.ids[FicheCategory.droits],
      containsAll(['controle-identite', 'fouille', 'garde-a-vue', 'contacts']),
    );
    expect(
      ContentCatalog.ids[FicheCategory.secours],
      containsAll(['lacrymogenes', 'chaleur', 'malaise', 'blessure']),
    );
  });

  test('chaque fiche du catalogue se charge et se lit', () async {
    for (final category in FicheCategory.values) {
      final fiches = await catalog.loadAll(category);
      expect(fiches.map((f) => f.id), ContentCatalog.ids[category]);
    }
  });

  test('aucun fichier de contenu oublié ou en trop', () {
    for (final category in FicheCategory.values) {
      final onDisk = Directory('assets/content/${category.name}')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last.replaceAll('.txt', ''))
          .toSet();
      expect(onDisk, ContentCatalog.ids[category]!.toSet(), reason: category.name);
    }
  });

  test('droits relus par un juriste, secours par des secouristes', () async {
    for (final fiche in await catalog.loadAll(FicheCategory.droits)) {
      expect(fiche.reviewBy, ReviewBy.juriste, reason: fiche.id);
    }
    for (final fiche in await catalog.loadAll(FicheCategory.secours)) {
      expect(fiche.reviewBy, ReviewBy.secouristes, reason: fiche.id);
    }
  });

  // Un texte juridique ou médical ne s'ajoute normalement qu'avec relu_par et
  // statut: valide. Seule exception, décidée par le responsable du projet le 24 octobre 2026
  // en connaissance de cause : le brouillon sourcé (`redaction: brouillon_source`),
  // dont les conditions sont vérifiées par le test suivant.
  test('une fiche non relue ne contient que des titres et des questions à rédiger, sauf brouillon sourcé', () async {
    for (final category in FicheCategory.values) {
      for (final fiche in await catalog.loadAll(category)) {
        if (!fiche.needsReview || fiche.draftFromSources) continue;
        for (final block in fiche.blocks) {
          expect(
            block is HeadingBlock || block is ToWriteBlock,
            isTrue,
            reason: 'La fiche « ${fiche.id} » n\'est pas relue mais contient du texte : '
                '« ${block.text} ». Un texte juridique ou médical ne s\'ajoute '
                'qu\'avec relu_par et statut: valide, ou comme brouillon sourcé '
                '(redaction: brouillon_source, avec ses sources).',
          );
        }
      }
    }
  });

  test('un brouillon sourcé cite ses sources, dit qu\'il n\'a pas été relu et reste lisible', () async {
    var drafts = 0;
    for (final category in FicheCategory.values) {
      for (final fiche in await catalog.loadAll(category)) {
        if (!fiche.draftFromSources) continue;
        drafts++;
        final reason = '${category.name}/${fiche.id}';
        final text = File('assets/content/${category.name}/${fiche.id}.txt').readAsStringSync();
        expect(fiche.needsReview, isTrue, reason: reason);
        expect(
          fiche.blocks.whereType<HeadingBlock>().map((b) => b.text),
          contains('Sources'),
          reason: '$reason : un brouillon cite ses sources',
        );
        expect(text, contains('https://'), reason: reason);
        expect(text, contains('Aucune relecture humaine à ce jour'), reason: reason);
        expect(
          fiche.blocks.where((b) => b is BulletBlock || b is ParagraphBlock).length,
          greaterThan(5),
          reason: reason,
        );
        // Mise en forme du projet : tutoiement, pas de tiret long.
        expect(text, isNot(contains('—')), reason: reason);
        expect(text, isNot(contains('vous êtes')), reason: reason);
      }
    }
    expect(drafts, greaterThan(0));
  });

  test('un brouillon qui devient relu n\'a plus la mention de brouillon', () async {
    for (final category in FicheCategory.values) {
      for (final fiche in await catalog.loadAll(category)) {
        if (!fiche.needsReview) expect(fiche.draftFromSources, isFalse, reason: fiche.id);
      }
    }
  });

  test('chaque question à rédiger est bien une question ou une consigne', () async {
    for (final category in FicheCategory.values) {
      for (final fiche in await catalog.loadAll(category)) {
        for (final block in fiche.blocks.whereType<ToWriteBlock>()) {
          expect(
            block.text.endsWith('?') || block.text.endsWith('.'),
            isTrue,
            reason: '${fiche.id} : « ${block.text} »',
          );
        }
      }
    }
  });

  // Barrière avant toute diffusion :
  //   CORTEGE_RELEASE_CHECK=1 flutter test test/content_catalog_test.dart
  test(
    'diffusion : toutes les fiches ont été relues',
    () async {
      for (final category in FicheCategory.values) {
        for (final fiche in await catalog.loadAll(category)) {
          expect(fiche.needsReview, isFalse, reason: '${category.name}/${fiche.id}');
        }
      }
    },
    skip: Platform.environment['CORTEGE_RELEASE_CHECK'] == '1'
        ? false
        : 'contrôle réservé à la diffusion (CORTEGE_RELEASE_CHECK=1)',
  );
}
