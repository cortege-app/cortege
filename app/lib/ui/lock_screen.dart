import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// « 30 s », « 4 min 12 s », « 15 min », « 1 h ».
String waitText(Duration wait) {
  final total = wait.inSeconds + (wait.inMilliseconds % 1000 > 0 ? 1 : 0);
  if (total >= 3600) {
    final minutes = (total % 3600) ~/ 60;
    return minutes == 0 ? '${total ~/ 3600} h' : '${total ~/ 3600} h $minutes min';
  }
  if (total >= 60) {
    final seconds = total % 60;
    return seconds == 0 ? '${total ~/ 60} min' : '${total ~/ 60} min $seconds s';
  }
  return '$total s';
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _busy = false;
  String? _error;
  Duration _wait = Duration.zero;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshWait());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Relit l'attente imposée après trop d'essais ratés, et la décompte.
  Future<void> _refreshWait() async {
    final wait = await widget.controller.lockoutRemaining();
    if (!mounted) return;
    _timer?.cancel();
    setState(() {
      _wait = wait;
      if (wait > Duration.zero) _error = null;
    });
    if (wait > Duration.zero) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final left = _wait - const Duration(seconds: 1);
        if (left <= Duration.zero) {
          _timer?.cancel();
          unawaited(_refreshWait());
        } else {
          setState(() => _wait = left);
        }
      });
    }
  }

  Future<void> _submit(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final opened = await widget.controller.unlock(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Même message pour tout code qui n'ouvre rien : on ne dit jamais s'il
      // existe un autre coffre.
      if (!opened) _error = 'Code incorrect.';
    });
    if (!opened) await _refreshWait();
  }

  void _forgotten() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ForgotCodeScreen(controller: widget.controller)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: PinPad(
                    title: 'Cortège',
                    subtitle: 'Tape ton code.',
                    error: _wait > Duration.zero ? 'Trop d\'essais. Réessaie dans ${waitText(_wait)}.' : _error,
                    busy: _busy,
                    locked: _wait > Duration.zero,
                    onSubmit: _submit,
                  ),
                ),
                TextButton(onPressed: _forgotten, child: const Text('Code oublié ?')),
              ],
            ),
          ),
        ),
      );
}

/// Seule issue quand le code est perdu : tout effacer et repartir de zéro. Le
/// code ne s'écrit nulle part, aucune donnée ne se récupère. Effacer ne donne
/// rien à celui qui tient le téléphone, et il peut déjà vider l'appli depuis
/// Android : ce chemin ne change que la clarté pour la personne.
///
/// Il reste ouvert pendant l'attente après trop d'essais ratés : celui qui a
/// oublié son code n'a pas à attendre une heure pour repartir.
class ForgotCodeScreen extends StatelessWidget {
  const ForgotCodeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Code oublié')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Personne ne peut retrouver ton code, pas même nous : il n\'est écrit nulle part.',
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'La seule issue est de tout effacer : le coffre, tes groupes, tes messages, tes codes et les cartes. C\'est définitif. Ensuite tu choisis un nouveau code et tu repars de zéro.',
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'Pas sûr de l\'avoir oublié ? Reviens à l\'écran de code et essaie encore.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 24),
            Text(
              'Tout effacer',
              style: theme.titleLarge?.copyWith(color: Palette.danger),
            ),
            const SizedBox(height: 8),
            Text(
              'Garde le doigt appuyé trois secondes. Impossible à annuler.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 12),
            HoldToConfirmButton(
              label: 'Tout effacer',
              onConfirmed: controller.wipeEverything,
            ),
            const SizedBox(height: 16),
            BigButton(
              label: 'Retour à l\'écran de code',
              primary: false,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
