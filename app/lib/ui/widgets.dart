import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vault/pin_policy.dart';
import 'theme.dart';

/// Bouton plein largeur, 72 px de haut : utilisable avec des gants.
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => primary
      ? FilledButton(onPressed: onPressed, child: Text(label))
      : OutlinedButton(onPressed: onPressed, child: Text(label));
}

/// Bloc cadré avec un titre et un sous-titre, tout le bloc est cliquable.
class NavTile extends StatelessWidget {
  const NavTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.urgent = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Cadre et titre rouges : pour ce qu'on cherche en urgence.
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        highlightColor: Palette.accent.withValues(alpha: 0.35),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: urgent ? Palette.danger : Palette.text, width: 2),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: urgent
                          ? theme.titleMedium?.copyWith(color: Palette.danger)
                          : theme.titleMedium,
                    ),
                    Text(
                      subtitle,
                      style: theme.bodyMedium?.copyWith(color: Palette.muted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Une ligne "libellé : valeur" pour les blocs d'état.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
          ),
          Text(value, style: theme.labelLarge),
        ],
      ),
    );
  }
}

/// Choix unique dans une liste (durée d'effacement, par exemple).
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          highlightColor: Palette.accent.withValues(alpha: 0.35),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? Palette.accent : Palette.line,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: selected ? Palette.accent : null,
                    border: Border.all(
                      color: selected ? Palette.accent : Palette.text,
                      width: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Pavé numérique maison : pas de clavier du système (pas d'historique de
/// saisie, pas de suggestions) et de grosses touches. Le code est effacé du
/// pavé dès qu'il est envoyé.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    required this.onSubmit,
    this.subtitle,
    this.error,
    this.busy = false,
    this.locked = false,
  });

  final String title;
  final String? subtitle;
  final String? error;
  final bool busy;

  /// Le clavier ne répond plus (attente après trop d'essais), sans le dire
  /// « occupé » : le message d'[error] reste affiché.
  final bool locked;
  final void Function(String pin) onSubmit;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _digits = '';

  bool get _frozen => widget.busy || widget.locked;

  void _add(String digit) {
    if (_frozen || _digits.length >= PinPolicy.maxLength) return;
    HapticFeedback.selectionClick();
    setState(() => _digits += digit);
  }

  void _erase() {
    if (_frozen || _digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _submit() {
    if (_frozen || _digits.isEmpty) return;
    final pin = _digits;
    setState(() => _digits = '');
    widget.onSubmit(pin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final status = widget.busy ? 'Un instant...' : widget.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: theme.headlineMedium),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.subtitle!,
            style: theme.bodyMedium?.copyWith(color: Palette.muted),
          ),
        ],
        const SizedBox(height: 20),
        Semantics(
          label: '${_digits.length} chiffres tapés',
          child: _Dots(count: _digits.length),
        ),
        Container(
          height: 56,
          alignment: Alignment.centerLeft,
          child: Text(
            status ?? '',
            style: theme.bodyMedium?.copyWith(
              color: widget.busy ? Palette.accent : Palette.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              for (final row in const [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
              ])
                _KeyRow([
                  for (final digit in row)
                    _Key(label: digit, onTap: () => _add(digit)),
                ]),
              _KeyRow([
                _Key(label: 'Effacer', small: true, onTap: _erase),
                _Key(label: '0', onTap: () => _add('0')),
                _Key(label: 'OK', small: true, accent: true, onTap: _submit),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final slots = count < PinPolicy.minLength ? PinPolicy.minLength : count;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < slots; i++)
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: i < count ? Palette.text : null,
              border: Border.all(color: Palette.text, width: 2),
            ),
          ),
      ],
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow(this.keys);

  final List<Widget> keys;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              for (var i = 0; i < keys.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: keys[i]),
              ],
            ],
          ),
        ),
      );
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onTap,
    this.small = false,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool small;
  final bool accent;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          highlightColor: Palette.accent.withValues(alpha: 0.4),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent ? Palette.accent : null,
              border: Border.all(
                color: accent ? Palette.accent : Palette.text,
                width: 2,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: small ? 20 : 34,
                fontWeight: FontWeight.w700,
                color: accent ? Colors.black : Palette.text,
              ),
            ),
          ),
        ),
      );
}

/// Action sans retour : il faut garder le doigt appuyé. Un simple appui, même
/// par erreur dans une poche, ne fait rien.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.duration = const Duration(seconds: 3),
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration duration;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> {
  Timer? _ticker;
  DateTime? _since;
  double _progress = 0;

  void _start() {
    _since = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final elapsed = DateTime.now().difference(_since!);
      final progress = elapsed.inMilliseconds / widget.duration.inMilliseconds;
      if (progress >= 1) {
        _stop();
        widget.onConfirmed();
      } else {
        setState(() => _progress = progress);
      }
    });
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    if (mounted) setState(() => _progress = 0);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final holding = _progress > 0;
    return Semantics(
      button: true,
      label: widget.label,
      hint: 'Garde le doigt appuyé pour confirmer',
      onLongPress: widget.onConfirmed,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            border: Border.all(color: Palette.danger, width: 2),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _progress,
                  child: const ColoredBox(color: Palette.danger),
                ),
              ),
              Center(
                child: Text(
                  holding ? 'Continue d\'appuyer...' : widget.label,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: holding && _progress > 0.5
                        ? Colors.black
                        : Palette.danger,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
