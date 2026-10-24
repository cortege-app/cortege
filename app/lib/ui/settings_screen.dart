import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../vault/pin_policy.dart';
import '../vault/vault_state.dart';
import 'pin_create_flow.dart';
import 'texts.dart';
import 'theme.dart';
import 'widgets.dart';

const _ttlChoices = [1, 6, 12, 24, 48, 72];

/// Premier niveau : l'écran de code apparaît après ce temps hors de l'appli.
const _screenLockChoices = [
  (label: '30 secondes', delay: Duration(seconds: 30)),
  (label: '1 minute', delay: Duration(minutes: 1)),
  (label: '5 minutes', delay: Duration(minutes: 5)),
  (label: '15 minutes', delay: Duration(minutes: 15)),
];

/// Second niveau : combien de temps la clé et le maillage restent en mémoire
/// derrière l'écran de code.
const _memoryChoices = [
  (label: 'Aucun : tout se ferme avec l\'écran de code', delay: Duration.zero),
  (label: '15 minutes', delay: Duration(minutes: 15)),
  (label: '1 heure', delay: Duration(hours: 1)),
  (label: '4 heures', delay: Duration(hours: 4)),
];

/// Un binôme se tait au bout de deux intervalles. Plus l'intervalle est court,
/// plus l'alerte est rapide, plus la batterie en pâtit.
const _checkInChoices = [
  (label: '2 minutes', delay: Duration(minutes: 2)),
  (label: '5 minutes', delay: Duration(minutes: 5)),
  (label: '10 minutes', delay: Duration(minutes: 10)),
  (label: '15 minutes', delay: Duration(minutes: 15)),
];

/// Où en est le renouvellement de la clé du coffre, en une phrase.
String renewalText(DateTime? last, bool due, DateTime now) {
  if (last == null) {
    return due ? 'Un renouvellement attend son tour.' : 'Pas de renouvellement depuis l\'ouverture du coffre.';
  }
  final minutes = now.difference(last).inMinutes;
  final ago = minutes < 1
      ? 'à l\'instant'
      : minutes < 60
          ? 'il y a $minutes min'
          : 'il y a ${minutes ~/ 60} h';
  return 'Dernier renouvellement : $ago.${due ? ' Un autre attend son tour.' : ''}';
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final session = controller.session;
        if (session == null) return const SizedBox.shrink();
        final currentHours = session.state.ttl.inHours;
        return Scaffold(
          appBar: AppBar(title: const Text('Réglages')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Effacement automatique', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Les messages et les données de l\'événement disparaissent après :',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                for (final hours in _ttlChoices) ...[
                  ChoiceRow(
                    label: '$hours h',
                    selected: hours == currentHours,
                    onTap: () => controller.setTtl(Duration(hours: hours)),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 4),
                Text(
                  'Après chaque effacement, la clé du coffre est renouvelée : les anciennes copies, restées dans la mémoire du téléphone, ne se relisent plus. ${renewalText(session.lastRenewed, session.renewalDue, DateTime.now())}',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 16),
                Text('Écran de code', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Quand tu quittes l\'appli, l\'écran de code s\'affiche après ce délai. Sans le code, on ne voit plus rien.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                for (final choice in _screenLockChoices) ...[
                  ChoiceRow(
                    label: choice.label,
                    selected: choice.delay == session.state.lockAfter,
                    onTap: () => controller.setLockAfter(choice.delay),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 16),
                Text('Maillage derrière l\'écran de code', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Pour recevoir et relayer des messages dans ta poche, la clé du coffre et le maillage restent en mémoire pendant ce temps, puis tout se verrouille pour de bon. Pendant ce temps, quelqu\'un qui saisit ton téléphone allumé et sait lire sa mémoire pourrait récupérer les clés. L\'écran de code, lui, protège d\'un simple regard.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                for (final choice in _memoryChoices) ...[
                  ChoiceRow(
                    label: choice.label,
                    selected: choice.delay == session.state.closeAfter,
                    onTap: () => controller.setCloseAfter(choice.delay),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 16),
                Text('Binôme', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Ton téléphone envoie un signe de vie à ton binôme toutes les :',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 4),
                Text(
                  "Quelqu'un est signalé muet au bout de deux intervalles de silence. Court, c'est plus réactif et ça use plus la batterie.",
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                for (final choice in _checkInChoices) ...[
                  ChoiceRow(
                    label: choice.label,
                    selected: choice.delay == session.state.checkInEvery,
                    onTap: () => controller.setCheckInEvery(choice.delay),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 16),
                Text('Codes', style: theme.titleLarge),
                const SizedBox(height: 12),
                BigButton(
                  label: 'Changer mon code',
                  primary: false,
                  onPressed: () => _push(
                    context,
                    _PinChangeScreen(
                      title: 'Changer mon code',
                      intro: 'Choisis un nouveau code. L\'ancien ne marchera plus.',
                      hint:
                          '${PinPolicy.minLength} à ${PinPolicy.maxLength} chiffres.',
                      apply: session.changePin,
                    ),
                  ),
                ),
                if (session.role == VaultRole.real) ...[
                  const SizedBox(height: 8),
                  BigButton(
                    label: 'Code de contrainte',
                    primary: false,
                    onPressed: () => _push(
                      context,
                      _PinChangeScreen(
                        title: 'Code de contrainte',
                        intro:
                            'Ce code ouvre une version vide de l\'appli. Il remplace l\'ancien code de contrainte s\'il y en avait un.',
                        hint: 'Différent de ton code.',
                        apply: session.setDuressPin,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                BigButton(
                  label: 'Écran de code maintenant',
                  onPressed: controller.lockScreen,
                ),
                const SizedBox(height: 8),
                BigButton(
                  label: 'Tout verrouiller et arrêter le maillage',
                  primary: false,
                  onPressed: controller.lock,
                ),
                const SizedBox(height: 32),
                Text(
                  'Tout effacer',
                  style: theme.titleLarge?.copyWith(color: Palette.danger),
                ),
                const SizedBox(height: 8),
                Text(
                  'Détruit le coffre, les codes et toutes les données. Impossible à annuler. Garde le doigt appuyé trois secondes.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                HoldToConfirmButton(
                  label: 'Tout effacer',
                  onConfirmed: controller.wipeEverything,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _push(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));
}

class _PinChangeScreen extends StatefulWidget {
  const _PinChangeScreen({
    required this.title,
    required this.intro,
    required this.hint,
    required this.apply,
  });

  final String title;
  final String intro;
  final String hint;
  final Future<void> Function(String pin) apply;

  @override
  State<_PinChangeScreen> createState() => _PinChangeScreenState();
}

class _PinChangeScreenState extends State<_PinChangeScreen> {
  bool _done = false;

  Future<String?> _apply(String pin) async {
    try {
      await widget.apply(pin);
    } on PinRejected catch (e) {
      return describePinProblem(e.problem);
    }
    if (mounted) setState(() => _done = true);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _done
              ? ListView(
                  children: [
                    Text('C\'est fait.', style: theme.headlineMedium),
                    const SizedBox(height: 24),
                    BigButton(
                      label: 'Retour',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.intro,
                      style: theme.bodyMedium?.copyWith(color: Palette.muted),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: PinCreateFlow(
                        title: 'Nouveau code',
                        hint: widget.hint,
                        onPin: _apply,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
