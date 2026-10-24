import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_controller.dart';
import 'home_screen.dart';
import 'lock_screen.dart';
import 'organizer_screens.dart';
import 'setup_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class CortegeApp extends StatefulWidget {
  const CortegeApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<CortegeApp> createState() => _CortegeAppState();
}

class _CortegeAppState extends State<CortegeApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  AppPhase? _lastPhase;
  var _importing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastPhase = widget.controller.phase;
    widget.controller.addListener(_onControllerChange);
  }

  /// Un fichier d'événement ouvert avec Cortège depuis une autre appli attend
  /// que le coffre soit ouvert : on le prend alors, une seule fois, et on montre
  /// ce qu'il contient.
  Future<void> _checkIncoming() async {
    final controller = widget.controller;
    if (_importing || controller.phase != AppPhase.unlocked || controller.organizer == null) return;
    _importing = true;
    try {
      final picked = await controller.filePicker.takeIncoming();
      if (picked == null) return;
      final navigator = _navigatorKey.currentState;
      if (navigator == null || controller.phase != AppPhase.unlocked) {
        // Verrouillé entre-temps : le fichier est jeté, il suffira de le rouvrir.
        try {
          await picked.file.delete();
        } on FileSystemException {
          // Nettoyé plus tard.
        }
        return;
      }
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => EventImportScreen(controller: controller, picked: picked),
        ),
      );
    } finally {
      _importing = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Un écran empilé (réglages, « code oublié »...) ne doit pas rester visible
  /// après un verrouillage ou un effacement.
  void _onControllerChange() {
    final phase = widget.controller.phase;
    if (phase != _lastPhase && phase != AppPhase.unlocked) {
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    final opened = _lastPhase != AppPhase.unlocked && phase == AppPhase.unlocked;
    _lastPhase = phase;
    if (opened) unawaited(_checkIncoming());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        widget.controller.didEnterBackground();
      case AppLifecycleState.resumed:
        widget.controller.didReturnToForeground();
        unawaited(_checkIncoming());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cortège',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        navigatorKey: _navigatorKey,
        locale: const Locale('fr'),
        supportedLocales: const [Locale('fr')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final controller = widget.controller;
            return switch (controller.phase) {
              AppPhase.starting => const Scaffold(),
              AppPhase.needsSetup => SetupScreen(controller: controller),
              AppPhase.locked => LockScreen(controller: controller),
              AppPhase.unlocked => HomeScreen(controller: controller),
              AppPhase.unrecoverable => _UnrecoverableScreen(controller: controller),
              AppPhase.failed => _FailedScreen(controller: controller),
            };
          },
        ),
      );
}

class _UnrecoverableScreen extends StatelessWidget {
  const _UnrecoverableScreen({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Données perdues', style: theme.headlineMedium),
            const SizedBox(height: 16),
            Text(
              'La protection matérielle du téléphone a été réinitialisée ou effacée. Ce qui était chiffré est définitivement illisible, même avec le bon code.',
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 24),
            BigButton(
              label: 'Effacer et repartir de zéro',
              onPressed: controller.wipeEverything,
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedScreen extends StatelessWidget {
  const _FailedScreen({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Impossible de continuer', style: theme.headlineMedium),
            const SizedBox(height: 16),
            Text(
              'L\'appli n\'arrive pas à utiliser la protection matérielle ou le stockage de ce téléphone. Elle ne démarre pas sans, pour ne pas laisser tes données sans protection.',
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              '${controller.failure}',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}
