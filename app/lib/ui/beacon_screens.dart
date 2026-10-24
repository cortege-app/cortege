import 'dart:async';

import 'package:flutter/material.dart';

import '../mesh/medic_service.dart';
import '../mesh/mesh_controller.dart';
import '../mesh/proximity.dart';
import '../mesh/torch.dart';
import 'screen_brightness.dart';
import 'theme.dart';
import 'widgets.dart';

/// Côté blessé : « Aider à me trouver ». Tant que l'écran est ouvert, le
/// téléphone annonce une balise Bluetooth que seul le medic qui a reçu l'alerte
/// sait reconnaître. Il peut aussi faire clignoter l'écran et la lampe.
class ImHereScreen extends StatefulWidget {
  const ImHereScreen({super.key, required this.mesh, required this.alertId});

  final MeshController mesh;
  final String alertId;

  @override
  State<ImHereScreen> createState() => _ImHereScreenState();
}

class _ImHereScreenState extends State<ImHereScreen> {
  late final MedicService _medic = widget.mesh.medic;

  @override
  void initState() {
    super.initState();
    unawaited(_medic.startBeacon(widget.alertId));
  }

  @override
  void dispose() {
    // Le signal s'arrête avec l'écran.
    unawaited(_medic.stopBeacon());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Aider à me trouver')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _medic.beaconOn ? Palette.accent : Palette.line,
                    width: 2,
                  ),
                ),
                child: Text(
                  _medic.beaconOn ? 'Signal Bluetooth actif' : 'Signal Bluetooth éteint',
                  style: theme.titleLarge,
                ),
              ),
              if (!_medic.beaconOn) ...[
                const SizedBox(height: 8),
                Text(
                  'Le signal n\'a pas pu démarrer sur ce téléphone. Le clignotement marche quand même.',
                  style: theme.bodyMedium?.copyWith(color: Palette.danger),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Tant que tu restes sur cet écran, ton téléphone envoie un signal que seul le medic qui a reçu ton alerte sait reconnaître. Il s\'en sert pour savoir s\'il se rapproche. Ça porte de 20 à 50 m.',
                style: theme.bodyLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Quelqu\'un avec un scanner Bluetooth voit qu\'un signal est émis, pas à qui il est ni ce qu\'il veut dire. Il s\'arrête quand tu quittes cet écran.',
                style: theme.bodyMedium?.copyWith(color: Palette.muted),
              ),
              const SizedBox(height: 24),
              BigButton(
                label: 'Faire clignoter l\'écran et la lampe',
                primary: false,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FlashScreen(torch: _medic.torch),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Ça se voit de loin, par tout le monde. À utiliser quand le medic est tout près.',
                style: theme.bodyMedium?.copyWith(color: Palette.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Écran plein qui passe du blanc au noir, lampe allumée en même temps, deux
/// fois par seconde environ (assez lent pour ne gêner personne).
class FlashScreen extends StatefulWidget {
  const FlashScreen({super.key, required this.torch});

  final Torch torch;

  /// Un demi-cycle : blanc, puis noir.
  static const half = Duration(milliseconds: 600);

  @override
  State<FlashScreen> createState() => _FlashScreenState();
}

class _FlashScreenState extends State<FlashScreen> {
  var _on = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(ScreenBrightness.max(on: true));
    unawaited(widget.torch.set(true));
    _timer = Timer.periodic(FlashScreen.half, (_) {
      setState(() => _on = !_on);
      unawaited(widget.torch.set(_on));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(widget.torch.set(false));
    unawaited(ScreenBrightness.max(on: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = _on ? Colors.black : Colors.white;
    return Scaffold(
      backgroundColor: _on ? Colors.white : Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  'Je suis ici',
                  style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: ink),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Semantics(
                button: true,
                label: 'Arrêter',
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    height: 88,
                    width: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(border: Border.all(color: ink, width: 4)),
                    child: Text(
                      'Arrêter',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: ink),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Côté medic : « chaud / froid ». Le signal de la balise de la personne, sa
/// force, et si on s'en rapproche. Ne donne pas de direction : il faut marcher
/// et regarder si la jauge monte.
class FindScreen extends StatefulWidget {
  const FindScreen({super.key, required this.mesh, required this.alert});

  final MeshController mesh;
  final MedicAlert alert;

  @override
  State<FindScreen> createState() => _FindScreenState();
}

class _FindScreenState extends State<FindScreen> {
  final _tracker = ProximityTracker();
  StreamSubscription<int>? _subscription;
  Timer? _ticker;

  // La tendance affichée ne change qu'après trois secondes de constance : le
  // signal saute de plusieurs dB sans que la distance change.
  ProximityTrend? _shownTrend;
  ProximityTrend? _candidate;
  var _candidateTicks = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.mesh.medic.proximityTo(widget.alert).listen((rssi) {
      _tracker.add(widget.mesh.now(), rssi);
      if (mounted) setState(() {});
    });
    // Sans mesure, rien ne redessine l'écran : on le rafraîchit chaque seconde
    // pour que « Aucun signal » apparaisse.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateTrend();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _updateTrend() {
    final raw = _tracker.trend(widget.mesh.now());
    if (raw == _shownTrend) {
      _candidate = null;
      _candidateTicks = 0;
      return;
    }
    if (raw == _candidate) {
      _candidateTicks++;
    } else {
      _candidate = raw;
      _candidateTicks = 1;
    }
    if (_shownTrend == null || _candidateTicks >= 3) {
      _shownTrend = raw;
      _candidate = null;
      _candidateTicks = 0;
    }
  }

  static String _level(ProximityLevel level) => switch (level) {
        ProximityLevel.veryClose => 'Tout près',
        ProximityLevel.close => 'Près',
        ProximityLevel.near => 'Dans les parages',
        ProximityLevel.far => 'Loin',
      };

  static String _trend(ProximityTrend? trend) => switch (trend) {
        ProximityTrend.closer => 'Tu te rapproches',
        ProximityTrend.farther => 'Tu t\'éloignes',
        ProximityTrend.steady => 'Pas de changement',
        null => 'Bouge un peu pour que je compare',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final now = widget.mesh.now();
    final rssi = _tracker.current(now);
    final level = rssi == null ? null : ProximityTracker.levelOf(rssi);
    return Scaffold(
      appBar: AppBar(title: const Text('Chaud / froid')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (rssi == null) ...[
              Text('Aucun signal', style: theme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                'Soit la personne n\'a pas appuyé sur « Aider à me trouver » sur son téléphone, soit tu es trop loin : le signal porte de 20 à 50 m.',
                style: theme.bodyLarge,
              ),
            ] else ...[
              Text(
                _level(level!),
                style: theme.displaySmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              Semantics(
                label: 'Force du signal',
                value: '${(ProximityTracker.fraction(rssi) * 100).round()} pour cent',
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(border: Border.all(color: Palette.text, width: 2)),
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: ProximityTracker.fraction(rssi),
                          child: Container(color: Palette.accent),
                        ),
                      ),
                      // Le trait blanc marque le meilleur signal depuis le début.
                      if (_tracker.best != null)
                        Align(
                          alignment: Alignment(ProximityTracker.fraction(_tracker.best!) * 2 - 1, 0),
                          child: Container(width: 4, color: Palette.text),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                level == ProximityLevel.veryClose
                    ? 'Cherche le point où la jauge est la plus haute'
                    : _trend(_shownTrend),
                style: theme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '$rssi dBm · meilleur signal jusqu\'ici : ${_tracker.best} dBm',
                style: theme.bodyMedium?.copyWith(color: Palette.muted),
              ),
              if (level == ProximityLevel.veryClose) ...[
                const SizedBox(height: 12),
                Text(
                  'Tu es tout près. À cette distance le signal varie trop pour te guider : regarde autour de toi, ou demande à la personne de faire clignoter son téléphone.',
                  style: theme.bodyLarge,
                ),
              ],
            ],
            const SizedBox(height: 24),
            Text(
              'Marche lentement et regarde si la jauge monte. Le signal change aussi quand tu tournes le téléphone, que tu mets la main devant ou qu\'un corps passe : tiens-le toujours dans la même position, devant toi, et fie-toi à la tendance sur quelques secondes, pas à un chiffre.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}
