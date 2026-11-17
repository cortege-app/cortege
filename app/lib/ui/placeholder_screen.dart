import 'package:flutter/material.dart';

import '../l10n/language.dart';

import 'theme.dart';

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            tr("This part isn't available yet.", 'Cette partie n\'est pas encore disponible.'),
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Palette.muted),
          ),
        ),
      );
}
