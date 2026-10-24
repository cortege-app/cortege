/// Format des fiches : un fichier texte par fiche, lisible et modifiable par un
/// juriste ou un secouriste sans toucher au code.
///
///     titre: Contrôle d'identité
///     resume: Quand on te demande tes papiers.
///     relecture: juriste              (juriste ou secouristes)
///     statut: a_valider               (a_valider ou valide)
///     relu_par: Nom, date             (obligatoire si valide, interdit sinon)
///     redaction: brouillon_source     (facultatif, seulement avec a_valider)
///
/// `redaction: brouillon_source` dit que la fiche a été rédigée par un
/// assistant à partir de sources officielles, qu'elle cite, sans relecture
/// humaine. C'est la seule façon pour une fiche non relue de contenir du texte,
/// et l'écran l'annonce sous le bandeau jaune. Une fois la fiche relue, on
/// passe `statut` à `valide`, on ajoute `relu_par` et on retire `redaction`.
///
///     # Titre de section
///     Un paragraphe. Les lignes qui se suivent sont collées.
///     - Un point de liste
///     ! Un avertissement
///     ? Une question à laquelle la fiche doit répondre (texte à rédiger)
///
/// Les lignes `? ` sont des emplacements vides : ils s'affichent comme tels et
/// ne passent jamais pour du contenu validé.
enum ReviewBy { juriste, secouristes }

enum ReviewStatus { aValider, valide }

sealed class FicheBlock {
  const FicheBlock(this.text);

  final String text;
}

final class HeadingBlock extends FicheBlock {
  const HeadingBlock(super.text);
}

final class ParagraphBlock extends FicheBlock {
  const ParagraphBlock(super.text);
}

final class BulletBlock extends FicheBlock {
  const BulletBlock(super.text);
}

final class WarningBlock extends FicheBlock {
  const WarningBlock(super.text);
}

final class ToWriteBlock extends FicheBlock {
  const ToWriteBlock(super.text);
}

class Fiche {
  const Fiche({
    required this.id,
    required this.title,
    required this.summary,
    required this.reviewBy,
    required this.status,
    required this.reviewedBy,
    required this.blocks,
    this.draftFromSources = false,
  });

  final String id;
  final String title;
  final String summary;
  final ReviewBy reviewBy;
  final ReviewStatus status;
  final String? reviewedBy;
  final List<FicheBlock> blocks;

  /// Rédigée par un assistant à partir de sources officielles, jamais relue.
  final bool draftFromSources;

  bool get needsReview => status == ReviewStatus.aValider;

  /// La phrase sous le bandeau d'un brouillon : ce qu'il est et ce qu'il n'est pas.
  String? get draftNotice => draftFromSources && needsReview
      ? 'Brouillon écrit par un assistant d\'après des sources officielles. Personne ne l\'a relu. Les sources sont en bas de la fiche.'
      : null;

  int get toWriteCount => blocks.whereType<ToWriteBlock>().length;

  String get bannerText {
    if (!needsReview) return 'Relu par $reviewedBy';
    return switch (reviewBy) {
      ReviewBy.juriste => 'À FAIRE VALIDER PAR UN JURISTE',
      ReviewBy.secouristes => 'À FAIRE VALIDER PAR DES SECOURISTES',
    };
  }
}

const _headerKeys = {'titre', 'resume', 'relecture', 'statut', 'relu_par', 'redaction'};

FormatException _error(String id, int line, String message) =>
    FormatException('fiche "$id", ligne $line : $message');

Fiche parseFiche(String id, String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');

  final header = <String, String>{};
  var i = 0;
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    final line = lines[i];
    final colon = line.indexOf(':');
    if (colon <= 0) {
      throw _error(id, i + 1, 'en-tête attendu sous la forme « clé: valeur »');
    }
    final key = line.substring(0, colon).trim();
    if (!_headerKeys.contains(key)) {
      throw _error(id, i + 1, 'clé d\'en-tête inconnue : $key');
    }
    if (header.containsKey(key)) {
      throw _error(id, i + 1, 'clé d\'en-tête en double : $key');
    }
    header[key] = line.substring(colon + 1).trim();
    i++;
  }

  for (final required in const ['titre', 'resume', 'relecture', 'statut']) {
    if ((header[required] ?? '').isEmpty) {
      throw _error(id, 1, 'en-tête « $required » manquant ou vide');
    }
  }

  final reviewBy = switch (header['relecture']) {
    'juriste' => ReviewBy.juriste,
    'secouristes' => ReviewBy.secouristes,
    final other => throw _error(id, 1, 'relecture inconnue : $other'),
  };
  final status = switch (header['statut']) {
    'a_valider' => ReviewStatus.aValider,
    'valide' => ReviewStatus.valide,
    final other => throw _error(id, 1, 'statut inconnu : $other'),
  };
  final reviewedBy = header['relu_par'];
  if (status == ReviewStatus.valide && (reviewedBy == null || reviewedBy.isEmpty)) {
    throw _error(id, 1, 'une fiche validée doit dire qui l\'a relue (relu_par)');
  }
  if (status == ReviewStatus.aValider && reviewedBy != null) {
    throw _error(id, 1, 'relu_par est interdit tant que le statut est a_valider');
  }
  final redaction = header['redaction'];
  if (redaction != null && redaction != 'brouillon_source') {
    throw _error(id, 1, 'redaction inconnue : $redaction');
  }
  if (redaction != null && status == ReviewStatus.valide) {
    throw _error(id, 1, 'redaction: brouillon_source est interdit sur une fiche relue : retire-le');
  }

  final blocks = <FicheBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(ParagraphBlock(paragraph.join(' ')));
    paragraph.clear();
  }

  for (; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    FicheBlock Function(String) make;
    if (line.startsWith('# ')) {
      make = HeadingBlock.new;
    } else if (line.startsWith('- ')) {
      make = BulletBlock.new;
    } else if (line.startsWith('! ')) {
      make = WarningBlock.new;
    } else if (line.startsWith('? ')) {
      make = ToWriteBlock.new;
    } else if (RegExp(r'^[#\-!?]').hasMatch(line)) {
      throw _error(
        id,
        i + 1,
        line.length == 1
            ? 'ligne vide après « ${line[0]} »'
            : 'il manque une espace après « ${line[0]} »',
      );
    } else {
      paragraph.add(line.trim());
      continue;
    }
    flush();
    final text = line.substring(2).trim();
    if (text.isEmpty) throw _error(id, i + 1, 'ligne vide après « ${line[0]} »');
    blocks.add(make(text));
  }
  flush();

  if (blocks.isEmpty) throw _error(id, lines.length, 'la fiche n\'a aucun contenu');

  return Fiche(
    id: id,
    title: header['titre']!,
    summary: header['resume']!,
    reviewBy: reviewBy,
    status: status,
    reviewedBy: reviewedBy,
    blocks: List.unmodifiable(blocks),
    draftFromSources: redaction != null,
  );
}
