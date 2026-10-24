import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
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

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PinPad(
              title: 'Cortège',
              subtitle: 'Tape ton code.',
              error: _wait > Duration.zero ? 'Trop d\'essais. Réessaie dans ${waitText(_wait)}.' : _error,
              busy: _busy,
              locked: _wait > Duration.zero,
              onSubmit: _submit,
            ),
          ),
        ),
      );
}
