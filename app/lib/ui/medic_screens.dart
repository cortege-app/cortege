import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/language.dart';
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
            open == 1 ? tr('An injured person is waiting for a medic', 'Un blessé attend un medic') : tr('$open injured people are waiting for a medic', '$open blessés attendent un medic'),
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
        title: Text(tr('Create the medic channel', 'Créer le canal des medics')),
        content: Text(
          tr('You become the first medic of this event. The other medics will have to scan your code to read the alerts. Only give it to medics you know.', 'Tu deviens le premier medic de cet événement. Les autres medics devront scanner ton code pour lire les alertes. À ne remettre qu\'à des medics que tu connais.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel', 'Annuler'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Create', 'Créer'))),
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
          appBar: AppBar(title: Text(tr('Medic role', 'Rôle medic'))),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!medic.canInviteMedics) ...[
                  Text(
                    tr("If you're a first aider or street medic, you can receive the event's injury alerts.", 'Si tu es secouriste ou street medic, tu peux recevoir les alertes de blessés de l\'événement.'),
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    medic.hasChannel
                        ? tr('This phone can send an alert to the medics, but not read one.', 'Ce téléphone sait envoyer une alerte aux medics, mais pas la lire.')
                        : tr('Only medics can read the alerts: they are encrypted for them. So one medic has to create the channel, then give their code to the others.', 'Les alertes sont lisibles par les seuls medics : elles sont chiffrées pour eux. Il faut donc qu\'un medic crée le canal, puis donne son code aux autres.'),
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 16),
                  if (!medic.hasChannel) ...[
                    BigButton(label: tr('Create the medic channel', 'Créer le canal des medics'), onPressed: () => _create(context)),
                    const SizedBox(height: 12),
                  ],
                  BigButton(
                    label: tr("Join a medic's channel", 'Rejoindre le canal d\'un medic'),
                    primary: medic.hasChannel,
                    onPressed: () => _push(context, MedicScanScreen(mesh: mesh)),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
                    child: Column(
                      children: [
                        InfoRow(tr('Receiving alerts', 'Réception des alertes'), medic.isMedic ? tr('on', 'activée') : tr('off', 'coupée')),
                        InfoRow(tr('Pending alerts', 'Alertes en attente'), '${alerts.where((a) => !a.answered).length}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  BigButton(
                    label: medic.isMedic ? tr('Stop receiving', 'Couper la réception') : tr('Start receiving', 'Activer la réception'),
                    primary: false,
                    onPressed: () => medic.setActive(!medic.isMedic),
                  ),
                  const SizedBox(height: 16),
                  if (medic.isMedic) ...[
                    Text(tr('Alerts received', 'Alertes reçues'), style: theme.titleLarge),
                    const SizedBox(height: 8),
                    if (alerts.isEmpty)
                      Text(
                        tr('No alerts yet. They disappear within 2 h and when you lock everything.', 'Aucune alerte pour l\'instant. Elles disparaissent d\'ici 2 h et quand tu verrouilles tout.'),
                        style: theme.bodyMedium?.copyWith(color: Palette.muted),
                      ),
                    for (final alert in alerts) ...[
                      NavTile(
                        title: alert.answered
                            ? tr('${alert.kind.label}, reply sent', '${alert.kind.label}, réponse envoyée')
                            : alert.kind.label,
                        subtitle: agoText(alert.receivedAt, now),
                        onTap: () => _push(context, AlertDetailScreen(mesh: mesh, alertId: alert.id)),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 8),
                  ],
                  BigButton(
                    label: tr('Show the medic code', 'Montrer le code des medics'),
                    primary: false,
                    onPressed: () => _push(context, MedicCodeScreen(mesh: mesh)),
                  ),
                  const SizedBox(height: 24),
                  HoldToConfirmButton(
                    label: tr('Leave the medic role', 'Quitter le rôle de medic'),
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
      appBar: AppBar(title: Text(tr('Medic code', 'Code des medics'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_code != null) ...[
              Center(child: QrCodeView(data: _code, size: width.clamp(200, 640))),
              const SizedBox(height: 16),
            ],
            Text(
              tr('Whoever scans this code can read every injury alert, with its approximate location. Only show it to medics you know, face to face.', 'Celui qui scanne ce code lit toutes les alertes de blessés, avec leur position approximative. Ne le montre qu\'à des medics que tu connais, en face à face.'),
              style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            BigButton(label: tr('Done', 'Terminé'), onPressed: () => Navigator.of(context).pop()),
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
        _message = tr('This QR is not a Cortège medic code.', 'Ce QR n\'est pas un code de medic Cortège.');
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
      appBar: AppBar(title: Text(tr('Join the medics', 'Rejoindre les medics'))),
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
                  Text(tr("You're a medic for this event.", 'Tu es medic de cet événement.'), style: theme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    tr('Injury alerts will arrive here while the mesh is running.', 'Les alertes des blessés arriveront ici tant que le maillage tourne.'),
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 24),
                  BigButton(label: tr('Done', 'Terminé'), onPressed: () => Navigator.of(context).pop()),
                ],
              )
            : QrScanner(
                onText: _onText,
                paused: _busy,
                message: _message,
                messageIsError: _error,
                pasteLabel: tr('Paste a copied code', 'Coller un code copié'),
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
            appBar: AppBar(title: Text(tr('Alert', 'Alerte'))),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr('This alert has expired.', 'Cette alerte a expiré.'), style: theme.bodyLarge),
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
                  Text(tr('No location in this alert.', 'Pas de position dans cette alerte.'), style: theme.bodyLarge)
                else ...[
                  Text(
                    alert.precise != null ? tr('Precise location', 'Position précise') : tr('Approximate location (about 200 m)', 'Position approximative (environ 200 m)'),
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
                            ? tr("You're there, within a few dozen meters: GPS is no longer precise enough to guide you. Look around, or switch to “Hot / cold” and ask them to flash their phone.", 'Tu es sur place, à quelques dizaines de mètres : la précision du GPS ne suffit plus pour te guider. Cherche à vue, ou passe sur « Chaud / froid » et demande-lui de faire clignoter son téléphone.')
                            : tr("You're in the alert's area (the location is only known to within 150 m). Look around or ask the person for their precise location.", "Tu es dans la zone de l'alerte (la position n'est connue qu'à 150 m près). Cherche à vue ou demande à la personne sa position précise."),
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
                        tr('The location is only accurate to within 200 m: the arrow gets you to the right area, not in front of the person. Ask them for their precise location or look around.', 'La position n\'est exacte qu\'à 200 m près : la flèche te met dans la bonne zone, pas devant la personne. Demande-lui sa position précise ou cherche-la à vue.'),
                        style: theme.bodyMedium?.copyWith(color: Palette.muted),
                      ),
                    ],
                  ] else ...[
                    BigButton(
                      label: _locating ? tr('Finding your location...', 'Recherche de ta position...') : tr('Show the direction from here', 'Voir la direction depuis ici'),
                      primary: false,
                      onPressed: _locating ? null : _locate,
                    ),
                    if (_locationFailed) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr("Your location can't be found. Check that location is turned on.", 'Ta position est introuvable. Vérifie que la localisation est activée.'),
                        style: theme.bodyMedium?.copyWith(color: Palette.danger),
                      ),
                    ],
                  ],
                ],
                const SizedBox(height: 24),
                if (alert.answered) ...[
                  Text(
                    tr('You answered. If the person decides to send you their precise location, it will appear here.', 'Tu as répondu. Si la personne décide de t\'envoyer sa position précise, elle apparaîtra ici.'),
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  BigButton(
                    label: tr('Hot / cold (Bluetooth signal)', 'Chaud / froid (signal Bluetooth)'),
                    primary: false,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FindScreen(mesh: widget.mesh, alert: alert),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('The person has to press “Help me get found” on their phone.', 'La personne doit appuyer sur « Aider à me trouver » sur son téléphone.'),
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ] else
                  BigButton(label: tr("I'm coming", 'J\'arrive'), onPressed: _answer),
                const SizedBox(height: 8),
                Text(
                  tr("The person sees your nickname when you answer. Nothing tells other medics you're going: let them know yourself.", 'La personne voit ton pseudo quand tu réponds. Rien ne dit à d\'autres medics que tu y vas : préviens-les toi-même.'),
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
