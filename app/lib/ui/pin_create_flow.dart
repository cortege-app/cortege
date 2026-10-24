import 'package:flutter/material.dart';

import '../vault/pin_policy.dart';
import 'texts.dart';
import 'widgets.dart';

/// Saisie d'un nouveau code en deux fois. [onPin] reçoit le code confirmé et
/// renvoie un message d'erreur à afficher, ou null si tout s'est bien passé.
class PinCreateFlow extends StatefulWidget {
  const PinCreateFlow({
    super.key,
    required this.title,
    required this.onPin,
    this.hint,
  });

  final String title;
  final String? hint;
  final Future<String?> Function(String pin) onPin;

  @override
  State<PinCreateFlow> createState() => _PinCreateFlowState();
}

class _PinCreateFlowState extends State<PinCreateFlow> {
  String? _first;
  String? _error;
  bool _busy = false;

  Future<void> _submit(String pin) async {
    final first = _first;
    if (first == null) {
      final problem = PinPolicy.check(pin);
      setState(() {
        _error = problem == null ? null : describePinProblem(problem);
        if (problem == null) _first = pin;
      });
      return;
    }
    if (pin != first) {
      setState(() {
        _first = null;
        _error = 'Les deux codes ne sont pas pareils. Recommence.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onPin(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _first = null;
        _error = error;
      }
    });
  }

  @override
  Widget build(BuildContext context) => PinPad(
        title: _first == null ? widget.title : 'Tape-le encore une fois',
        subtitle: _first == null ? widget.hint : null,
        error: _error,
        busy: _busy,
        onSubmit: _submit,
      );
}
