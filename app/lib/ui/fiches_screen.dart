import 'package:flutter/material.dart';

import '../content/catalog.dart';
import '../content/fiche.dart';
import 'theme.dart';
import 'widgets.dart';

/// Bandeau en haut de chaque écran de fiche. Jaune plein tant que le contenu
/// n'a pas été relu : impossible à rater, même en plein soleil.
class ReviewBanner extends StatelessWidget {
  const ReviewBanner({super.key, required this.fiche});

  final Fiche fiche;

  @override
  Widget build(BuildContext context) {
    final pending = fiche.needsReview;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pending ? Palette.accent : null,
        border: Border.all(color: pending ? Palette.accent : Palette.line, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fiche.bannerText,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: pending ? Colors.black : Palette.text,
            ),
          ),
          if (fiche.draftNotice != null) ...[
            const SizedBox(height: 6),
            Text(
              fiche.draftNotice!,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.black),
            ),
          ],
        ],
      ),
    );
  }
}

class FicheListScreen extends StatefulWidget {
  const FicheListScreen({
    super.key,
    required this.category,
    required this.title,
    required this.catalog,
  });

  final FicheCategory category;
  final String title;
  final ContentCatalog catalog;

  @override
  State<FicheListScreen> createState() => _FicheListScreenState();
}

class _FicheListScreenState extends State<FicheListScreen> {
  late final Future<List<Fiche>> _fiches = widget.catalog.loadAll(widget.category);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: FutureBuilder<List<Fiche>>(
          future: _fiches,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Impossible de lire les fiches.',
                  style: theme.bodyLarge?.copyWith(color: Palette.danger),
                ),
              );
            }
            final fiches = snapshot.data;
            if (fiches == null) return const SizedBox.shrink();
            final pending = fiches.where((f) => f.needsReview).toList();
            final onlyDrafts = pending.isNotEmpty && pending.every((f) => f.draftFromSources);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (pending.isNotEmpty) ...[
                  ReviewBanner(fiche: pending.first),
                  const SizedBox(height: 12),
                  Text(
                    onlyDrafts
                        ? 'Personne n\'a encore relu ces fiches. Vérifie auprès d\'un avocat ou de secouristes avant de t\'y fier pour une décision grave.'
                        : 'Ces fiches ne sont pas encore toutes rédigées ni relues. Celles qui n\'ont que des questions à rédiger ne servent à rien pour l\'instant. Ne t\'y fie pas.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 16),
                ],
                for (final fiche in fiches) ...[
                  NavTile(
                    title: fiche.title,
                    subtitle: fiche.summary,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FicheScreen(fiche: fiche),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class FicheScreen extends StatelessWidget {
  const FicheScreen({super.key, required this.fiche});

  final Fiche fiche;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(fiche.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ReviewBanner(fiche: fiche),
            const SizedBox(height: 12),
            Text(
              fiche.summary,
              style: theme.bodyLarge?.copyWith(color: Palette.muted),
            ),
            for (final block in fiche.blocks) _BlockView(block),
          ],
        ),
      ),
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView(this.block);

  final FicheBlock block;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return switch (block) {
      HeadingBlock(:final text) => Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 8),
          child: Semantics(
            header: true,
            child: Container(
              padding: const EdgeInsets.only(bottom: 4),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Palette.text, width: 2)),
              ),
              child: Text(text, style: theme.titleLarge),
            ),
          ),
        ),
      ParagraphBlock(:final text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(text, style: theme.bodyLarge),
        ),
      BulletBlock(:final text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 12),
                child: Container(width: 10, height: 10, color: Palette.accent),
              ),
              Expanded(child: Text(text, style: theme.bodyLarge)),
            ],
          ),
        ),
      WarningBlock(:final text) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Palette.danger, width: 6)),
            ),
            child: Text(text, style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ),
      ToWriteBlock(:final text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            label: 'Texte à rédiger : $text',
            excludeSemantics: true,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Palette.line, width: 2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'À RÉDIGER',
                    style: theme.bodyMedium?.copyWith(
                      color: Palette.muted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(text, style: theme.bodyLarge),
                ],
              ),
            ),
          ),
        ),
    };
  }
}
