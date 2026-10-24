import 'package:cortege/content/fiche.dart';
import 'package:flutter_test/flutter_test.dart';

const _header = 'titre: Test\nresume: Un résumé.\nrelecture: juriste\nstatut: a_valider\n';

String _fiche({String header = _header, String body = '# Section\n? Une question ?\n'}) =>
    '$header\n$body';

void main() {
  group('lecture', () {
    test('en-tête et blocs', () {
      final fiche = parseFiche('t', _fiche(body: '''
# Titre de section
Une ligne
et sa suite.

- Un point
! Attention
? Une question ?
'''));

      expect(fiche.title, 'Test');
      expect(fiche.summary, 'Un résumé.');
      expect(fiche.reviewBy, ReviewBy.juriste);
      expect(fiche.status, ReviewStatus.aValider);
      expect(fiche.blocks.map((b) => b.runtimeType), [
        HeadingBlock,
        ParagraphBlock,
        BulletBlock,
        WarningBlock,
        ToWriteBlock,
      ]);
      expect(fiche.blocks[1].text, 'Une ligne et sa suite.');
      expect(fiche.toWriteCount, 1);
    });

    test('fins de ligne Windows', () {
      final fiche = parseFiche('t', _fiche().replaceAll('\n', '\r\n'));
      expect(fiche.title, 'Test');
      expect(fiche.blocks, hasLength(2));
    });

    test('les deux bandeaux, mot pour mot', () {
      final juriste = parseFiche('t', _fiche());
      final secouristes = parseFiche(
        't',
        _fiche(header: _header.replaceFirst('juriste', 'secouristes')),
      );
      expect(juriste.bannerText, 'À FAIRE VALIDER PAR UN JURISTE');
      expect(secouristes.bannerText, 'À FAIRE VALIDER PAR DES SECOURISTES');
    });

    test('un brouillon sourcé le dit sous le bandeau, une fiche ordinaire non', () {
      final draft = parseFiche('t', _fiche(header: '${_header}redaction: brouillon_source\n'));
      expect(draft.draftFromSources, isTrue);
      expect(draft.needsReview, isTrue);
      expect(draft.draftNotice, contains('Personne ne l\'a relu'));
      expect(draft.bannerText, 'À FAIRE VALIDER PAR UN JURISTE');

      final plain = parseFiche('t', _fiche());
      expect(plain.draftFromSources, isFalse);
      expect(plain.draftNotice, isNull);
    });

    test('une fiche validée dit qui l\'a relue et n\'a plus de bandeau d\'alerte', () {
      final fiche = parseFiche(
        't',
        _fiche(
          header: '${_header.replaceFirst('a_valider', 'valide')}'
              'relu_par: Maître Exemple, 1 janvier 2027\n',
        ),
      );
      expect(fiche.needsReview, isFalse);
      expect(fiche.bannerText, 'Relu par Maître Exemple, 1 janvier 2027');
    });
  });

  group('refus', () {
    void rejects(String source, Pattern message) => expect(
          () => parseFiche('t', source),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(message))),
        );

    test('titre manquant', () {
      rejects(_fiche(header: 'resume: x\nrelecture: juriste\nstatut: a_valider\n'), 'titre');
    });

    test('relecture inconnue', () {
      rejects(_fiche(header: _header.replaceFirst('juriste', 'medecin')), 'relecture inconnue');
    });

    test('statut inconnu', () {
      rejects(_fiche(header: _header.replaceFirst('a_valider', 'ok')), 'statut inconnu');
    });

    test('clé d\'en-tête inconnue ou en double', () {
      rejects(_fiche(header: '${_header}auteur: moi\n'), 'inconnue');
      rejects(_fiche(header: '${_header}titre: autre\n'), 'en double');
    });

    test('validée sans relecteur', () {
      rejects(_fiche(header: _header.replaceFirst('a_valider', 'valide')), 'relu_par');
    });

    test('relecteur indiqué alors que rien n\'est validé', () {
      rejects(_fiche(header: '${_header}relu_par: Quelqu\'un\n'), 'interdit');
    });

    test('mention de rédaction inconnue, ou gardée sur une fiche relue', () {
      rejects(_fiche(header: '${_header}redaction: ia\n'), 'redaction inconnue');
      rejects(
        _fiche(
          header: '${_header.replaceFirst('a_valider', 'valide')}'
              'relu_par: Maître Exemple, 1 janvier 2027\nredaction: brouillon_source\n',
        ),
        'retire-le',
      );
    });

    test('préfixe collé au texte', () {
      rejects(_fiche(body: '#Section\n'), 'espace');
      rejects(_fiche(body: '-point\n'), 'espace');
    });

    test('préfixe sans texte', () {
      rejects(_fiche(body: '# \n'), 'vide');
    });

    test('fiche sans contenu', () {
      rejects('$_header\n', 'aucun contenu');
    });

    test('l\'erreur dit la ligne', () {
      rejects(_fiche(body: '# Bien\n#Mal\n'), 'ligne 7');
    });
  });
}
