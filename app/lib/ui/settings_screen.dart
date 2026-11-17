import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/language.dart';
import '../vault/pin_policy.dart';
import '../vault/vault_state.dart';
import 'pin_create_flow.dart';
import 'texts.dart';
import 'theme.dart';
import 'widgets.dart';

const _ttlChoices = [1, 6, 12, 24, 48, 72];

/// Premier niveau : l'écran de code apparaît après ce temps hors de l'appli.
List<({String label, Duration delay})> get _screenLockChoices => [
      (label: tr('30 seconds', '30 secondes'), delay: const Duration(seconds: 30)),
      (label: tr('1 minute', '1 minute'), delay: const Duration(minutes: 1)),
      (label: tr('5 minutes', '5 minutes'), delay: const Duration(minutes: 5)),
      (label: tr('15 minutes', '15 minutes'), delay: const Duration(minutes: 15)),
    ];

/// Second niveau : combien de temps la clé et le maillage restent en mémoire
/// derrière l'écran de code.
List<({String label, Duration delay})> get _memoryChoices => [
      (
        label: tr('None: everything closes with the code screen', 'Aucun : tout se ferme avec l\'écran de code'),
        delay: Duration.zero,
      ),
      (label: tr('15 minutes', '15 minutes'), delay: const Duration(minutes: 15)),
      (label: tr('1 hour', '1 heure'), delay: const Duration(hours: 1)),
      (label: tr('4 hours', '4 heures'), delay: const Duration(hours: 4)),
    ];

/// Un binôme se tait au bout de deux intervalles. Plus l'intervalle est court,
/// plus l'alerte est rapide, plus la batterie en pâtit.
List<({String label, Duration delay})> get _checkInChoices => [
      (label: tr('2 minutes', '2 minutes'), delay: const Duration(minutes: 2)),
      (label: tr('5 minutes', '5 minutes'), delay: const Duration(minutes: 5)),
      (label: tr('10 minutes', '10 minutes'), delay: const Duration(minutes: 10)),
      (label: tr('15 minutes', '15 minutes'), delay: const Duration(minutes: 15)),
    ];

/// Où en est le renouvellement de la clé du coffre, en une phrase.
String renewalText(DateTime? last, bool due, DateTime now) {
  if (last == null) {
    return due
        ? tr('A renewal is waiting its turn.', 'Un renouvellement attend son tour.')
        : tr('No renewal since the vault was opened.', 'Pas de renouvellement depuis l\'ouverture du coffre.');
  }
  final minutes = now.difference(last).inMinutes;
  final ago = minutes < 1
      ? tr('just now', 'à l\'instant')
      : minutes < 60
          ? tr('$minutes min ago', 'il y a $minutes min')
          : tr('${minutes ~/ 60} h ago', 'il y a ${minutes ~/ 60} h');
  return tr(
    'Last renewal: $ago.${due ? ' Another one is waiting its turn.' : ''}',
    'Dernier renouvellement : $ago.${due ? ' Un autre attend son tour.' : ''}',
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, Language.notifier]),
      builder: (context, _) {
        final session = controller.session;
        if (session == null) return const SizedBox.shrink();
        final currentHours = session.state.ttl.inHours;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Settings', 'Réglages'))),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(tr('Language', 'Langue'), style: theme.titleLarge),
                const SizedBox(height: 12),
                for (final language in AppLanguage.values) ...[
                  ChoiceRow(
                    label: language.nativeName,
                    selected: language == Language.current,
                    onTap: () => Language.set(language),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 16),
                Text(tr('Automatic erasure', 'Effacement automatique'), style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Messages and event data disappear after:',
                    'Les messages et les données de l\'événement disparaissent après :',
                  ),
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
                  tr(
                    'After each erasure, the vault key is renewed: old copies left in the phone\'s memory can no longer be read. ${renewalText(session.lastRenewed, session.renewalDue, DateTime.now())}',
                    'Après chaque effacement, la clé du coffre est renouvelée : les anciennes copies, restées dans la mémoire du téléphone, ne se relisent plus. ${renewalText(session.lastRenewed, session.renewalDue, DateTime.now())}',
                  ),
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 16),
                Text(tr('Code screen', 'Écran de code'), style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'When you leave the app, the code screen appears after this delay. Without the code, nothing can be seen.',
                    'Quand tu quittes l\'appli, l\'écran de code s\'affiche après ce délai. Sans le code, on ne voit plus rien.',
                  ),
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
                Text(
                  tr('Mesh behind the code screen', 'Maillage derrière l\'écran de code'),
                  style: theme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'To receive and relay messages while the phone is in your pocket, the vault key and the mesh stay in memory for this long, then everything locks for good. During that time, someone who grabs your phone while it is on and knows how to read its memory could recover the keys. The code screen only protects against a quick glance.',
                    'Pour recevoir et relayer des messages dans ta poche, la clé du coffre et le maillage restent en mémoire pendant ce temps, puis tout se verrouille pour de bon. Pendant ce temps, quelqu\'un qui saisit ton téléphone allumé et sait lire sa mémoire pourrait récupérer les clés. L\'écran de code, lui, protège d\'un simple regard.',
                  ),
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
                Text(tr('Buddy', 'Binôme'), style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Your phone sends a sign of life to your buddy every:',
                    'Ton téléphone envoie un signe de vie à ton binôme toutes les :',
                  ),
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 4),
                Text(
                  tr(
                    'Someone is reported silent after two intervals without a signal. Shorter reacts faster and uses more battery.',
                    "Quelqu'un est signalé muet au bout de deux intervalles de silence. Court, c'est plus réactif et ça use plus la batterie.",
                  ),
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
                Text(tr('Codes', 'Codes'), style: theme.titleLarge),
                const SizedBox(height: 12),
                BigButton(
                  label: tr('Change my code', 'Changer mon code'),
                  primary: false,
                  onPressed: () => _push(
                    context,
                    _PinChangeScreen(
                      title: () => tr('Change my code', 'Changer mon code'),
                      intro: () => tr(
                        'Choose a new code. The old one will stop working.',
                        'Choisis un nouveau code. L\'ancien ne marchera plus.',
                      ),
                      hint: () => tr(
                        '${PinPolicy.minLength} to ${PinPolicy.maxLength} digits.',
                        '${PinPolicy.minLength} à ${PinPolicy.maxLength} chiffres.',
                      ),
                      apply: session.changePin,
                    ),
                  ),
                ),
                if (session.role == VaultRole.real) ...[
                  const SizedBox(height: 8),
                  BigButton(
                    label: tr('Duress code', 'Code de contrainte'),
                    primary: false,
                    onPressed: () => _push(
                      context,
                      _PinChangeScreen(
                        title: () => tr('Duress code', 'Code de contrainte'),
                        intro: () => tr(
                          'This code opens an empty version of the app. It replaces the previous duress code, if there was one.',
                          'Ce code ouvre une version vide de l\'appli. Il remplace l\'ancien code de contrainte s\'il y en avait un.',
                        ),
                        hint: () => tr('Different from your code.', 'Différent de ton code.'),
                        apply: session.setDuressPin,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                BigButton(
                  label: tr('Code screen now', 'Écran de code maintenant'),
                  onPressed: controller.lockScreen,
                ),
                const SizedBox(height: 8),
                BigButton(
                  label: tr('Lock everything and stop the mesh', 'Tout verrouiller et arrêter le maillage'),
                  primary: false,
                  onPressed: controller.lock,
                ),
                const SizedBox(height: 32),
                Text(
                  tr('Erase everything', 'Tout effacer'),
                  style: theme.titleLarge?.copyWith(color: Palette.danger),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Destroys the vault, the codes and all data. Cannot be undone. Keep your finger pressed for three seconds.',
                    'Détruit le coffre, les codes et toutes les données. Impossible à annuler. Garde le doigt appuyé trois secondes.',
                  ),
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 12),
                HoldToConfirmButton(
                  label: tr('Erase everything', 'Tout effacer'),
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

/// Les textes sont passés comme fonctions pour suivre un changement de langue
/// pendant que l'écran est ouvert.
class _PinChangeScreen extends StatefulWidget {
  const _PinChangeScreen({
    required this.title,
    required this.intro,
    required this.hint,
    required this.apply,
  });

  final String Function() title;
  final String Function() intro;
  final String Function() hint;
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
      appBar: AppBar(title: Text(widget.title())),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _done
              ? ListView(
                  children: [
                    Text(tr('Done.', 'C\'est fait.'), style: theme.headlineMedium),
                    const SizedBox(height: 24),
                    BigButton(
                      label: tr('Back', 'Retour'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.intro(),
                      style: theme.bodyMedium?.copyWith(color: Palette.muted),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: PinCreateFlow(
                        title: tr('New code', 'Nouveau code'),
                        hint: widget.hint(),
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
