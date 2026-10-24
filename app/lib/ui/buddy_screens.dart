import 'dart:async';

import 'package:flutter/material.dart';

import '../mesh/buddy_invite.dart';
import '../mesh/buddy_service.dart';
import '../mesh/mesh_controller.dart';
import 'messages_screens.dart';
import 'event_prompt.dart';
import 'qr_scanner.dart';
import 'qr_widgets.dart';
import 'screen_brightness.dart';
import 'theme.dart';
import 'time_text.dart';
import 'widgets.dart';

/// Un binôme exige un pseudo : sinon on le demande d'abord.
Future<bool> ensureDisplayName(BuildContext context, MeshController mesh) async {
  if (mesh.displayName != null) return true;
  await Navigator.of(context).push(
    MaterialPageRoute<bool>(builder: (_) => DisplayNameScreen(mesh: mesh)),
  );
  return mesh.displayName != null;
}

/// Bandeau rouge quand quelqu'un du binôme ne donne plus de nouvelles.
class SilenceBanner extends StatelessWidget {
  const SilenceBanner({super.key, required this.mesh});

  final MeshController mesh;

  @override
  Widget build(BuildContext context) {
    final now = mesh.now();
    final silent = [
      for (final info in mesh.buddies.infos)
        for (final person in info.others)
          if (person.silent) person,
    ];
    if (silent.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      color: Palette.danger,
      child: Text(
        silent
            .map((p) => 'Plus de nouvelles de ${p.name} ${sinceText(p.lastHeard, now)}')
            .join('\n'),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.black),
      ),
    );
  }
}

class BuddyScreen extends StatelessWidget {
  const BuddyScreen({super.key, required this.mesh});

  final MeshController mesh;

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _create(BuildContext context) async {
    if (!await ensureDisplayName(context, mesh)) return;
    if (!context.mounted) return;
    try {
      final invite = await mesh.buddies.create();
      if (!context.mounted) return;
      _push(
        context,
        BuddyCodeScreen(
          mesh: mesh,
          buddyId: mesh.buddies.idForInvite(invite),
          instruction:
              'Fais scanner ce code par ton proche. Ensuite, scanne le sien avec « Scanner un proche ».',
        ),
      );
    } on DifferentEventException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tu es déjà dans un autre événement.')),
      );
    }
  }

  Future<void> _join(BuildContext context) async {
    if (!await ensureDisplayName(context, mesh)) return;
    if (!context.mounted) return;
    _push(context, BuddyScanScreen(mesh: mesh));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final infos = mesh.buddies.infos;
        final now = mesh.now();
        return Scaffold(
          appBar: AppBar(title: const Text('Binôme')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SilenceBanner(mesh: mesh),
                Text(
                  'Tu t\'appaires avec 1 à 3 proches, en face à face, en scannant vos codes. Ensuite, vos téléphones s\'envoient un signe de vie à intervalle régulier, et l\'appli te prévient si l\'un d\'eux se tait.',
                  style: theme.bodyLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '« Se taire » veut dire qu\'on n\'entend plus rien de la personne dans le maillage. L\'appli ne sait pas où elle est.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 16),
                for (final info in infos) ...[
                  NavTile(
                    title: info.others.isEmpty
                        ? 'Binôme en attente'
                        : 'Avec ${info.others.map((p) => p.name).join(', ')}',
                    subtitle: info.hasSilent
                        ? 'Plus de nouvelles de ${info.others.firstWhere((p) => p.silent).name}'
                        : info.others.isEmpty
                            ? 'Scanne le code d\'un proche'
                            : 'Dernier signe : ${agoText(info.others.map((p) => p.lastHeard).whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a), now)}',
                    onTap: () => _push(context, BuddyDetailScreen(mesh: mesh, buddyId: info.id)),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
                BigButton(label: 'Créer un binôme', onPressed: () => _create(context)),
                const SizedBox(height: 12),
                BigButton(
                  label: 'Rejoindre le binôme d\'un proche',
                  primary: false,
                  onPressed: () => _join(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class BuddyDetailScreen extends StatefulWidget {
  const BuddyDetailScreen({super.key, required this.mesh, required this.buddyId});

  final MeshController mesh;
  final String buddyId;

  @override
  State<BuddyDetailScreen> createState() => _BuddyDetailScreenState();
}

class _BuddyDetailScreenState extends State<BuddyDetailScreen> {
  String? _sent;

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _checkIn() async {
    await widget.mesh.buddies.checkIn(widget.buddyId);
    if (mounted) setState(() => _sent = 'Envoyé. Tes proches savent que tu vas bien.');
  }

  Future<void> _leave() async {
    await widget.mesh.buddies.leave(widget.buddyId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        final matches = widget.mesh.buddies.infos.where((i) => i.id == widget.buddyId);
        if (matches.isEmpty) return const Scaffold();
        final info = matches.first;
        final now = widget.mesh.now();
        final minutes = widget.mesh.session.state.checkInEvery.inMinutes;
        return Scaffold(
          appBar: AppBar(title: const Text('Binôme')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SilenceBanner(mesh: widget.mesh),
                Text('Les personnes', style: theme.titleLarge),
                const SizedBox(height: 8),
                if (info.others.isEmpty)
                  Text(
                    'Personne d\'autre pour l\'instant. Montre ton code à un proche, puis scanne le sien.',
                    style: theme.bodyLarge?.copyWith(color: Palette.muted),
                  ),
                for (final person in info.others) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: person.silent ? Palette.danger : Palette.line,
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${person.name} (${person.keyTag})', style: theme.titleMedium),
                              Text(
                                person.silent
                                    ? 'Plus de nouvelles ${sinceText(person.lastHeard, now)}'
                                    : person.lastHeard == null
                                        ? 'Pas encore de signe'
                                        : 'Signe de vie ${agoText(person.lastHeard, now)}',
                                style: theme.bodyMedium?.copyWith(
                                  color: person.silent ? Palette.danger : Palette.muted,
                                  fontWeight: person.silent ? FontWeight.w800 : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 16),
                if (info.others.isNotEmpty) ...[
                  BigButton(label: 'Je vais bien', onPressed: _checkIn),
                  if (_sent != null) ...[
                    const SizedBox(height: 8),
                    Text(_sent!, style: theme.bodyMedium?.copyWith(color: Palette.muted)),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    info.lastCheckIn == null
                        ? 'Un signe de vie part tout seul toutes les $minutes min tant que le maillage tourne.'
                        : 'Ton dernier signe : ${agoText(info.lastCheckIn, now)}. Il en part un tout seul toutes les $minutes min.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 16),
                ],
                BigButton(
                  label: 'Montrer mon code',
                  primary: false,
                  onPressed: () => _push(BuddyCodeScreen(
                    mesh: widget.mesh,
                    buddyId: widget.buddyId,
                    instruction: 'Fais scanner ce code par la personne à ajouter.',
                  )),
                ),
                const SizedBox(height: 8),
                BigButton(
                  label: 'Scanner un proche',
                  primary: false,
                  onPressed: () => _push(BuddyScanScreen(mesh: widget.mesh)),
                ),
                const SizedBox(height: 24),
                HoldToConfirmButton(
                  label: 'Quitter le binôme',
                  onConfirmed: _leave,
                  duration: const Duration(seconds: 2),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Montre notre code de binôme. On le photographie une fois à l'ouverture : le
/// code ne doit pas changer sous la caméra de l'autre.
class BuddyCodeScreen extends StatefulWidget {
  const BuddyCodeScreen({
    super.key,
    required this.mesh,
    required this.buddyId,
    required this.instruction,
  });

  final MeshController mesh;
  final String buddyId;
  final String instruction;

  @override
  State<BuddyCodeScreen> createState() => _BuddyCodeScreenState();
}

class _BuddyCodeScreenState extends State<BuddyCodeScreen> {
  late final String? _code = widget.mesh.buddies.infos.any((i) => i.id == widget.buddyId)
      ? widget.mesh.buddies.inviteFor(widget.buddyId).encode()
      : null;

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
    final code = _code;
    if (code == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mon code')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Ce binôme n\'existe plus.', style: theme.bodyLarge),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Mon code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: QrCodeView(data: code, size: width.clamp(200, 640))),
            const SizedBox(height: 16),
            Text(widget.instruction, style: theme.bodyLarge),
            const SizedBox(height: 8),
            Text(
              'Ce code ne sert qu\'à lire tes prochains messages dans le binôme. Ne le photographie pas.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 16),
            BigButton(label: 'Terminé', onPressed: () => Navigator.of(context).pop()),
          ],
        ),
      ),
    );
  }
}

/// Scanne le code d'un proche et l'ajoute au binôme.
class BuddyScanScreen extends StatefulWidget {
  const BuddyScanScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<BuddyScanScreen> createState() => _BuddyScanScreenState();
}

class _BuddyScanScreenState extends State<BuddyScanScreen> {
  String? _message;
  var _error = false;
  var _busy = false;
  String? _done;

  /// Le code scanné vient d'un autre événement : on attend la décision.
  BuddyInvite? _conflict;

  Future<void> _onText(String text) async {
    if (_busy) return;
    final BuddyInvite invite;
    try {
      invite = BuddyInvite.decode(text);
    } on FormatException {
      setState(() {
        _message = 'Ce QR n\'est pas un code de binôme Cortège.';
        _error = true;
      });
      return;
    }
    await _accept(invite);
  }

  Future<void> _leaveAndJoin(BuddyInvite invite) async {
    setState(() => _busy = true);
    await widget.mesh.leaveEvent();
    if (!mounted) return;
    setState(() => _conflict = null);
    await _accept(invite);
  }

  Future<void> _accept(BuddyInvite invite) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.mesh.buddies.accept(invite);
      if (!mounted) return;
      switch (result.outcome) {
        case BuddyScanOutcome.joined:
          await Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => BuddyCodeScreen(
                mesh: widget.mesh,
                buddyId: result.buddyId,
                instruction:
                    'Tu as rejoint le binôme de ${invite.name}. Maintenant, ${invite.name} doit scanner ce code.',
              ),
            ),
          );
          return;
        case BuddyScanOutcome.added:
          setState(() => _done = '${invite.name} est ajouté au binôme.');
        case BuddyScanOutcome.alreadyKnown:
          setState(() {
            _busy = false;
            _message = '${invite.name} est déjà dans ton binôme.';
            _error = false;
          });
        case BuddyScanOutcome.ownCode:
          setState(() {
            _busy = false;
            _message = 'C\'est ton propre code. Scanne celui de ton proche.';
            _error = true;
          });
      }
    } on DifferentEventException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _conflict = invite;
      });
    } on BuddyFullException {
      _fail('Un binôme tient au plus à quatre personnes.');
    } on NeedsDisplayNameException {
      _fail('Choisis d\'abord un pseudo.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
      _error = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final conflict = _conflict;
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un proche')),
      body: SafeArea(
        child: conflict != null
            ? LeaveEventPrompt(
                mesh: widget.mesh,
                busy: _busy,
                onLeave: () => _leaveAndJoin(conflict),
                onCancel: () => setState(() => _conflict = null),
              )
            : _done != null
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(_done!, style: theme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Les autres personnes du binôme le recevront par le maillage.',
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
