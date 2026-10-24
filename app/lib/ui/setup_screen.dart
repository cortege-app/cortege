import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../vault/pin_policy.dart';
import 'pin_create_flow.dart';
import 'texts.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Step { intro, pin, duressAsk, duress, creating }

/// Premier lancement : choix du code, puis du code de contrainte (facultatif).
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  _Step _step = _Step.intro;
  String? _pin;
  String? _error;

  Future<String?> _createVault(String? duress) async {
    setState(() => _step = _Step.creating);
    try {
      await widget.controller.setUp(pin: _pin!, duressPin: duress);
    } on PinRejected catch (e) {
      if (!mounted) return null;
      setState(() {
        _step = _Step.pin;
        _error = describePinProblem(e.problem);
      });
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (_step) {
              _Step.intro => _intro(context),
              _Step.pin => PinCreateFlow(
                  title: 'Choisis ton code',
                  hint:
                      '${PinPolicy.minLength} à ${PinPolicy.maxLength} chiffres. Pas de suite facile comme 123456.',
                  onPin: (pin) async {
                    setState(() {
                      _pin = pin;
                      _error = null;
                      _step = _Step.duressAsk;
                    });
                    return null;
                  },
                ),
              _Step.duressAsk => _duressAsk(context),
              _Step.duress => PinCreateFlow(
                  title: 'Code de contrainte',
                  hint: 'Différent du premier. Tu dois pouvoir le taper sans réfléchir.',
                  onPin: (duress) async {
                    if (duress == _pin) {
                      return 'Il doit être différent de ton code.';
                    }
                    return _createVault(duress);
                  },
                ),
              _Step.creating => const Center(
                  child: Text(
                    'Création du coffre...\nÇa prend quelques secondes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ),
            },
          ),
        ),
      );

  Widget _intro(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListView(
      children: [
        Text('Cortège', style: theme.headlineMedium),
        const SizedBox(height: 24),
        Text('Avant de commencer :', style: theme.titleMedium),
        const SizedBox(height: 12),
        _point(context, 'Tout reste sur ce téléphone. Pas de compte, pas de serveur, aucune connexion.'),
        _point(context, 'Ton code ouvre l\'appli. Personne ne peut le retrouver : si tu l\'oublies, il faut tout effacer.'),
        _point(context, 'Les messages disparaissent tout seuls au bout de 24 h. Tu peux changer ça dans les réglages.'),
        const SizedBox(height: 24),
        BigButton(
          label: 'Choisir mon code',
          onPressed: () => setState(() => _step = _Step.pin),
        ),
      ],
    );
  }

  Widget _duressAsk(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListView(
      children: [
        Text('Code de contrainte', style: theme.headlineMedium),
        const SizedBox(height: 16),
        Text(
          'Si on te force à ouvrir l\'appli, ce second code ouvre une version vide, sans tes groupes ni tes messages.',
          style: theme.bodyLarge,
        ),
        const SizedBox(height: 12),
        Text(
          'Ça te sort d\'un contrôle rapide. Ça ne trompe pas quelqu\'un qui analyse le téléphone en détail.',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
        ),
        const SizedBox(height: 24),
        BigButton(
          label: 'Choisir un code de contrainte',
          onPressed: () => setState(() => _step = _Step.duress),
        ),
        const SizedBox(height: 12),
        BigButton(
          label: 'Plus tard, dans les réglages',
          primary: false,
          onPressed: () => _createVault(null),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: theme.bodyMedium?.copyWith(color: Palette.danger)),
        ],
      ],
    );
  }

  Widget _point(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Palette.accent, width: 4)),
          ),
          child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
}
