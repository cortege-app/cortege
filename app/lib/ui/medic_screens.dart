import 'dart:async';

import 'package:flutter/material.dart';

import '../mesh/geo.dart';
import '../mesh/medic_invite.dart';
import '../mesh/mesh_controller.dart';
import 'beacon_screens.dart';
import 'buddy_screens.dart';
import 'compass_view.dart';
import 'event_prompt.dart';
import 'qr_scanner.dart';
import 'qr_widgets.dart';
import 'screen_brightness.dart';
import 'theme.dart';
import 'time_text.dart';
import 'widgets.dart';

/// Bandeau jaune quand une alerte de blessé attend une réponse.
class MedicAlertBanner extends StatelessWidget {
  const MedicAlertBanner({super.key, required this.mesh, required this.onTap});

  final MeshController mesh;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!mesh.medic.isMedic) return const SizedBox.shrink();
    final open = mesh.medic.alertsForMedic.where((a) => !a.answered).length;
    if (open == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: Palette.danger,
          child: Text(
            open == 1 ? 'Un blessé attend un medic' : '$open blessés attendent un medic',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.black),
          ),
        ),
      ),
    );
  }
}

class MedicScreen extends StatelessWidget {
  const MedicScreen({super.key, required this.mesh});

  final MeshController mesh;

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _create(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Créer le canal des medics'),
        content: const Text(
          'Tu deviens le premier medic de cet événement. Les autres medics devront scanner ton code pour lire les alertes. À ne remettre qu\'à des medics que tu connais.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer')),
        ],
      ),
    );
    if (ok != true) return;
    await mesh.medic.createChannel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final medic = mesh.medic;
        final now = mesh.now();
        final alerts = medic.alertsForMedic;
        return Scaffold(
          appBar: AppBar(title: const Text('Rôle medic')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!medic.canInviteMedics) ...[
                  Text(
                    'Si tu es secouriste ou street medic, tu peux recevoir les alertes de blessés de l\'événement.',
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    medic.hasChannel
                        ? 'Ce téléphone sait envoyer une alerte aux medics, mais pas la lire.'
                        : 'Les alertes sont lisibles par les seuls medics : elles sont chiffrées pour eux. Il faut donc qu\'un medic crée le canal, puis donne son code aux autres.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 16),
                  if (!medic.hasChannel) ...[
                    BigButton(label: 'Créer le canal des medics', onPressed: () => _create(context)),
                    const SizedBox(height: 12),
                  ],
                  BigButton(
                    label: 'Rejoindre le canal d\'un medic',
                    primary: medic.hasChannel,
                    onPressed: () => _push(context, MedicScanScreen(mesh: mesh)),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
                    child: Column(
                      children: [
                        InfoRow('Réception des alertes', medic.isMedic ? 'activée' : 'coupée'),
                        InfoRow('Alertes en attente', '${alerts.where((a) => !a.answered).length}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  BigButton(
                    label: medic.isMedic ? 'Couper la réception' : 'Activer la réception',
                    primary: false,
                    onPressed: () => medic.setActive(!medic.isMedic),
                  ),
                  const SizedBox(height: 16),
                  if (medic.isMedic) ...[
                    Text('Alertes reçues', style: theme.titleLarge),
                    const SizedBox(height: 8),
                    if (alerts.isEmpty)
                      Text(
                        'Aucune alerte pour l\'instant. Elles disparaissent d\'ici 2 h et quand tu verrouilles tout.',
                        style: theme.bodyMedium?.copyWith(color: Palette.muted),
                      ),
                    for (final alert in alerts) ...[
                      NavTile(
                        title: '${alert.kind.label}${alert.answered ? ', réponse envoyée' : ''}',
                        subtitle: agoText(alert.receivedAt, now),
                        onTap: () => _push(context, AlertDetailScreen(mesh: mesh, alertId: alert.id)),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 8),
                  ],
                  BigButton(
                    label: 'Montrer le code des medics',
                    primary: false,
                    onPressed: () => _push(context, MedicCodeScreen(mesh: mesh)),
                  ),
                  const SizedBox(height: 24),
                  HoldToConfirmButton(
                    label: 'Quitter le rôle de medic',
                    duration: const Duration(seconds: 2),
                    onConfirmed: () => medic.leave(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class MedicCodeScreen extends StatefulWidget {
  const MedicCodeScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<MedicCodeScreen> createState() => _MedicCodeScreenState();
}

class _MedicCodeScreenState extends State<MedicCodeScreen> {
  late final String? _code = widget.mesh.medic.invite()?.encode();

  @override
  void initState() {
    super.initState();
    unawaited(ScreenBrightness.max(on: true));
  }

  @override
  void dispose() {
    unawaited(ScreenBrightness.max(on: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width - 32;
    return Scaffold(
      appBar: AppBar(title: const Text('Code des medics')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_code != null) ...[
              Center(child: QrCodeView(data: _code, size: width.clamp(200, 640))),
              const SizedBox(height: 16),
            ],
            Text(
              'Celui qui scanne ce code lit toutes les alertes de blessés, avec leur position approximative. Ne le montre qu\'à des medics que tu connais, en face à face.',
              style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            BigButton(label: 'Terminé', onPressed: () => Navigator.of(context).pop()),
          ],
        ),
      ),
    );
  }
}

class MedicScanScreen extends StatefulWidget {
  const MedicScanScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<MedicScanScreen> createState() => _MedicScanScreenState();
}

class _MedicScanScreenState extends State<MedicScanScreen> {
  String? _message;
  var _error = false;
  var _busy = false;
  var _done = false;

  /// Le code scanné vient d'un autre événement : on attend la décision.
  MedicInvite? _conflict;

  Future<void> _onText(String text) async {
    if (_busy) return;
    final MedicInvite invite;
    try {
      invite = MedicInvite.decode(text);
    } on FormatException {
      setState(() {
        _message = 'Ce QR n\'est pas un code de medic Cortège.';
        _error = true;
      });
      return;
    }
    await _join(invite);
  }

  Future<void> _leaveAndJoin(MedicInvite invite) async {
    setState(() => _busy = true);
    await widget.mesh.leaveEvent();
    if (!mounted) return;
    setState(() => _conflict = null);
    await _join(invite);
  }

  Future<void> _join(MedicInvite invite) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.mesh.medic.join(invite);
      if (mounted) setState(() => _done = true);
    } on DifferentEventException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _conflict = invite;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Rejoindre les medics')),
      body: SafeArea(
        child: _conflict != null
            ? LeaveEventPrompt(
                mesh: widget.mesh,
                busy: _busy,
                onLeave: () => _leaveAndJoin(_conflict!),
                onCancel: () => setState(() => _conflict = null),
              )
            : _done
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Tu es medic de cet événement.', style: theme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Les alertes des blessés arriveront ici tant que le maillage tourne.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 24),
                  BigButton(label: 'Terminé', onPressed: () => Navigator.of(context).pop()),
                ],
              )
            : QrScanner(
                onText: _onText,
                paused: _busy,
                message: _message,
                messageIsError: _error,
                pasteLabel: 'Coller un code copié',
              ),
      ),
    );
  }
}

class AlertDetailScreen extends StatefulWidget {
  const AlertDetailScreen({super.key, required this.mesh, required this.alertId});

  final MeshController mesh;
  final String alertId;

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  GeoPoint? _me;
  var _locating = false;
  var _locationFailed = false;
  Stream<double>? _headings;
  Timer? _refresh;

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locationFailed = false;
    });
    final point = await widget.mesh.medic.location.current(accurate: true);
    if (!mounted) return;
    setState(() {
      _me = point;
      _locating = false;
      _locationFailed = point == null;
    });
    if (point == null) return;
    // Un seul flux de caps pour toute la durée de l'écran, et la position qui
    // se rafraîchit pendant qu'on marche.
    _headings ??= widget.mesh.medic.compass.headings(point).asBroadcastStream();
    _refresh ??= Timer.periodic(const Duration(seconds: 5), (_) => _updatePosition());
  }

  Future<void> _updatePosition() async {
    final point = await widget.mesh.medic.location.current(accurate: true);
    if (!mounted || point == null) return;
    setState(() => _me = point);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _answer() async {
    if (!await ensureDisplayName(context, widget.mesh)) return;
    await widget.mesh.medic.respond(widget.alertId, medicName: widget.mesh.displayName!);
  }

  String _position(GeoPoint point) =>
      '${point.lat.toStringAsFixed(5)}, ${point.lon.toStringAsFixed(5)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        final matches = widget.mesh.medic.alertsForMedic.where((a) => a.id == widget.alertId);
        if (matches.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('Alerte')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Cette alerte a expiré.', style: theme.bodyLarge),
            ),
          );
        }
        final alert = matches.first;
        final target = alert.precise ?? alert.coarse;
        final me = _me;
        return Scaffold(
          appBar: AppBar(title: Text(alert.kind.label)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(agoText(alert.receivedAt, widget.mesh.now()), style: theme.titleMedium),
                const SizedBox(height: 16),
                if (target == null)
                  Text('Pas de position dans cette alerte.', style: theme.bodyLarge)
                else ...[
                  Text(
                    alert.precise != null ? 'Position précise' : 'Position approximative (environ 200 m)',
                    style: theme.titleMedium,
                  ),
                  Text(_position(target), style: theme.headlineSmall),
                  const SizedBox(height: 12),
                  if (me != null) ...[
                    Text(describeOffset(me, target), style: theme.headlineSmall),
                    const SizedBox(height: 16),
                    if (isWithinMargin(me, target, precise: alert.precise != null)) ...[
                      Text(
                        alert.precise != null
                            ? 'Tu es sur place, à quelques dizaines de mètres : la précision du GPS ne suffit plus pour te guider. Cherche à vue, ou passe sur « Chaud / froid » et demande-lui de faire clignoter son téléphone.'
                            : "Tu es dans la zone de l'alerte (la position n'est connue qu'à 150 m près). Cherche à vue ou demande à la personne sa position précise.",
                        style: theme.bodyLarge,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_headings != null)
                      Center(
                        child: CompassView(
                          bearing: bearingDegrees(me, target),
                          headings: _headings!,
                          indicative: isWithinMargin(me, target, precise: alert.precise != null),
                        ),
                      ),
                    if (alert.precise == null &&
                        !isWithinMargin(me, target, precise: false)) ...[
                      const SizedBox(height: 8),
                      Text(
                        'La position n\'est exacte qu\'à 200 m près : la flèche te met dans la bonne zone, pas devant la personne. Demande-lui sa position précise ou cherche-la à vue.',
                        style: theme.bodyMedium?.copyWith(color: Palette.muted),
                      ),
                    ],
                  ] else ...[
                    BigButton(
                      label: _locating ? 'Recherche de ta position...' : 'Voir la direction depuis ici',
                      primary: false,
                      onPressed: _locating ? null : _locate,
                    ),
                    if (_locationFailed) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Ta position est introuvable. Vérifie que la localisation est activée.',
                        style: theme.bodyMedium?.copyWith(color: Palette.danger),
                      ),
                    ],
                  ],
                ],
                const SizedBox(height: 24),
                if (alert.answered) ...[
                  Text(
                    'Tu as répondu. Si la personne décide de t\'envoyer sa position précise, elle apparaîtra ici.',
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  BigButton(
                    label: 'Chaud / froid (signal Bluetooth)',
                    primary: false,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FindScreen(mesh: widget.mesh, alert: alert),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'La personne doit appuyer sur « Aider à me trouver » sur son téléphone.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ] else
                  BigButton(label: 'J\'arrive', onPressed: _answer),
                const SizedBox(height: 8),
                Text(
                  'La personne voit ton pseudo quand tu réponds. Rien ne dit à d\'autres medics que tu y vas : préviens-les toi-même.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
