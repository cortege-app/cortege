import 'package:cortege/content/catalog.dart';
import 'package:cortege/ui/fiches_screen.dart';
import 'package:cortege/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/disk_bundle.dart';

Widget _app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

ContentCatalog _catalog() => ContentCatalog(bundle: DiskAssetBundle());

void main() {
  testWidgets('la liste des droits porte le bandeau juriste', (tester) async {
    await tester.pumpWidget(_app(FicheListScreen(
      category: FicheCategory.droits,
      title: 'Droits',
      catalog: _catalog(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('À FAIRE VALIDER PAR UN JURISTE'), findsOneWidget);
    expect(find.textContaining('Brouillon écrit par un assistant'), findsOneWidget);
    expect(find.textContaining('Personne n\'a encore relu ces fiches'), findsOneWidget);
    expect(find.text('Contrôle d\'identité'), findsOneWidget);
    expect(find.text('Garde à vue'), findsOneWidget);
  });

  testWidgets('la liste des secours porte le bandeau secouristes', (tester) async {
    await tester.pumpWidget(_app(FicheListScreen(
      category: FicheCategory.secours,
      title: 'Secours',
      catalog: _catalog(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('À FAIRE VALIDER PAR DES SECOURISTES'), findsOneWidget);
    expect(find.text('Lacrymogènes'), findsOneWidget);
  });

  testWidgets('une fiche ouverte garde son bandeau, annonce qu\'elle est un brouillon et cite ses sources', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fiche = await _catalog().load(FicheCategory.droits, 'fouille');
    await tester.pumpWidget(_app(FicheScreen(fiche: fiche)));
    await tester.pumpAndSettle();

    expect(find.text('À FAIRE VALIDER PAR UN JURISTE'), findsOneWidget);
    expect(find.textContaining('Brouillon écrit par un assistant'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(find.textContaining('À faire vérifier par le juriste'), findsWidgets);
    expect(find.text('À RÉDIGER'), findsNothing, reason: 'cette fiche n\'a plus de question ouverte');
  });

  testWidgets('une question restée sans source reste marquée à rédiger', (tester) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fiche = await _catalog().load(FicheCategory.secours, 'lacrymogenes');
    await tester.pumpWidget(_app(FicheScreen(fiche: fiche)));
    await tester.pumpAndSettle();

    expect(find.text('À RÉDIGER'), findsNWidgets(3));
    expect(find.textContaining('Enfants, femmes enceintes'), findsOneWidget);
  });

  testWidgets('les numéros d\'urgence s\'affichent', (tester) async {
    final fiche = await _catalog().load(FicheCategory.secours, 'urgences');
    await tester.pumpWidget(_app(FicheScreen(fiche: fiche)));
    await tester.pumpAndSettle();

    for (final number in ['15 :', '17 :', '18 :', '112 :', '114 :']) {
      expect(find.textContaining(number), findsWidgets, reason: number);
    }
  });
}
