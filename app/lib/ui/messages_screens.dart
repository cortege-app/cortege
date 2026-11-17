import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/language.dart';
import '../mesh/group.dart';
import '../mesh/mesh_controller.dart';
import '../mesh/mesh_node.dart';
import 'qr_widgets.dart';
import 'screen_brightness.dart';
import 'theme.dart';
import 'widgets.dart';

String meshStatusLine(MeshController mesh) {
  switch (mesh.status) {
    case MeshStatus.stopped:
      final nothingToServe =
          mesh.groups.isEmpty && mesh.buddies.isEmpty && !mesh.medic.hasChannel;
      return nothingToServe ? tr('nothing to relay', 'rien à relayer') : tr('stopped', 'arrêté');
    case MeshStatus.starting:
      return tr('starting...', 'démarrage...');
    case MeshStatus.running:
      final n = mesh.neighborCount;
      return n == 0
          ? tr('active, no neighbors', 'actif, aucun voisin')
          : tr('active, $n neighbor${n > 1 ? 's' : ''}', 'actif, $n voisin${n > 1 ? 's' : ''}');
    case MeshStatus.unavailable:
      return mesh.statusDetail ?? tr('unavailable', 'indisponible');
  }
}

/// Liste des groupes, état du maillage, création et ajout de groupes.
class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key, required this.mesh});

  final MeshController mesh;

  void _push(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _join(BuildContext context) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => JoinGroupScreen(mesh: mesh)),
    );
    if (id != null && context.mounted) _push(context, GroupScreen(mesh: mesh, groupId: id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
                child: Column(
                  children: [
                    InfoRow(tr('Mesh', 'Maillage'), meshStatusLine(mesh)),
                    InfoRow(tr('Nickname', 'Pseudo'), mesh.displayName ?? tr('not set', 'à choisir')),
                  ],
                ),
              ),
              if (mesh.status == MeshStatus.unavailable) ...[
                const SizedBox(height: 12),
                BigButton(label: tr('Try again', 'Réessayer'), primary: false, onPressed: mesh.retryTransport),
              ],
              const SizedBox(height: 8),
              Text(
                tr(
                  'Behind the lock screen, the mesh keeps running for the time set in Settings, then it stops: you receive and relay nothing until you unlock again.',
                  'Derrière l\'écran de code, le maillage continue pendant le délai réglé dans les réglages, puis il s\'arrête : tu ne reçois et tu ne relaies plus rien jusqu\'au prochain déverrouillage.',
                ),
                style: theme.bodyMedium?.copyWith(color: Palette.muted),
              ),
              const SizedBox(height: 16),
              for (final group in mesh.groups) ...[
                NavTile(
                  title: group.name,
                  subtitle: '${group.messageCount} message${group.messageCount > 1 ? 's' : ''}',
                  onTap: () => _push(context, GroupScreen(mesh: mesh, groupId: group.id)),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              BigButton(
                label: tr('Create a group', 'Créer un groupe'),
                onPressed: () => _push(context, NewGroupScreen(mesh: mesh)),
              ),
              const SizedBox(height: 12),
              BigButton(
                label: tr('Join with a QR code', 'Rejoindre avec un QR'),
                primary: false,
                onPressed: () => _join(context),
              ),
              const SizedBox(height: 12),
              BigButton(
                label: tr('Change my nickname', 'Changer mon pseudo'),
                primary: false,
                onPressed: () => _push(context, DisplayNameScreen(mesh: mesh)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DisplayNameScreen extends StatefulWidget {
  const DisplayNameScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<DisplayNameScreen> createState() => _DisplayNameScreenState();
}

class _DisplayNameScreenState extends State<DisplayNameScreen> {
  late final _controller = TextEditingController(text: widget.mesh.displayName ?? '');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.mesh.setDisplayName(_controller.text);
      if (mounted) Navigator.of(context).pop(true);
    } on ArgumentError {
      setState(() => _error = tr(
        'Enter a nickname of 1 to ${MeshNode.maxNameBytes} letters.',
        'Entre un pseudo de 1 à ${MeshNode.maxNameBytes} lettres.',
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Nickname', 'Pseudo'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              tr(
                "It's the name others see next to your messages. Pick one that doesn't identify you.",
                'C\'est le nom que les autres voient à côté de tes messages. Choisis-en un qui ne te désigne pas.',
              ),
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: MeshNode.maxNameBytes,
              textInputAction: TextInputAction.done,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              style: theme.bodyLarge,
              decoration: InputDecoration(
                border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
                labelText: tr('Nickname', 'Pseudo'),
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            BigButton(label: tr('Save', 'Enregistrer'), onPressed: _save),
          ],
        ),
      ),
    );
  }
}

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _controller = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.mesh.createGroup(_controller.text);
      if (!mounted) return;
      final id = widget.mesh.groups.last.id;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => InviteScreen(mesh: widget.mesh, groupId: id)),
      );
    } on FormatException {
      setState(() {
        _busy = false;
        _error = tr(
          'Give the group a name (${GroupInvite.maxNameBytes} letters at most).',
          'Donne un nom au groupe (${GroupInvite.maxNameBytes} lettres au plus).',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('New group', 'Nouveau groupe'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              tr(
                "You'll get a QR code for the people you invite to scan.",
                'Tu recevras un QR à faire scanner par les personnes que tu invites.',
              ),
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: GroupInvite.maxNameBytes,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              style: theme.bodyLarge,
              decoration: InputDecoration(
                border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
                labelText: tr('Group name', 'Nom du groupe'),
                errorText: _error,
              ),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: _busy ? tr('One moment...', 'Un instant...') : tr('Create', 'Créer'),
              onPressed: _busy ? null : _create,
            ),
          ],
        ),
      ),
    );
  }
}

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.mesh, required this.groupId});

  final MeshController mesh;
  final String groupId;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _copied;

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

  /// Secours quand le scan ne marche pas. Le presse-papiers est lisible par
  /// les autres applis : on le vide au bout d'une minute.
  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = tr(
          'Copied. It will be cleared from the clipboard in one minute.',
          'Copié. Il sera effacé du presse-papiers dans une minute.',
        ));
    Timer(const Duration(minutes: 1), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    // Le groupe peut avoir été effacé pendant que cet écran était ouvert.
    if (!widget.mesh.groups.any((g) => g.id == widget.groupId)) return const Scaffold();
    final invite = widget.mesh.inviteFor(widget.groupId);
    final width = MediaQuery.sizeOf(context).width - 32;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Invite', 'Inviter'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(invite.name, style: theme.headlineMedium),
            const SizedBox(height: 16),
            Center(child: QrCodeView(data: invite.encode(), size: width.clamp(200, 640))),
            const SizedBox(height: 16),
            Text(
              tr(
                'Have the people you invite scan this QR code, face to face. The screen is at full brightness for this.',
                'Fais scanner ce QR par les personnes à inviter, en face de toi. L\'écran est au maximum de luminosité pour ça.',
              ),
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                "Anyone who scans it can read and write in the group. Don't post it and don't photograph it.",
                'Quiconque le scanne peut lire et écrire dans le groupe. Ne le publie pas et ne le photographie pas.',
              ),
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: tr('Open the group', 'Ouvrir le groupe'),
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => GroupScreen(mesh: widget.mesh, groupId: widget.groupId),
                ),
              ),
            ),
            const SizedBox(height: 12),
            BigButton(
              label: tr('Copy the invitation as text', 'Copier l\'invitation en texte'),
              primary: false,
              onPressed: () => _copy(invite.encode()),
            ),
            if (_copied != null) ...[
              const SizedBox(height: 8),
              Text(_copied!, style: theme.bodyMedium?.copyWith(color: Palette.muted)),
            ],
          ],
        ),
      ),
    );
  }
}

class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key, required this.mesh, required this.groupId});

  final MeshController mesh;
  final String groupId;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _bytes => utf8.encode(_controller.text.trim()).length;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _bytes > MeshNode.maxBodyBytes) return;
    try {
      await widget.mesh.sendMessage(widget.groupId, text);
      _controller.clear();
      setState(() => _error = null);
    } on NeedsDisplayNameException {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(builder: (_) => DisplayNameScreen(mesh: widget.mesh)),
      );
      if (mounted && widget.mesh.displayName != null) await _send();
    }
  }

  Future<void> _leave() async {
    await widget.mesh.leaveGroup(widget.groupId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        final info = widget.mesh.groups.where((g) => g.id == widget.groupId).firstOrNull;
        if (info == null) return const Scaffold();
        final messages = widget.mesh.messagesOf(widget.groupId).reversed.toList();
        final tooLong = _bytes > MeshNode.maxBodyBytes;
        return Scaffold(
          appBar: AppBar(
            title: Text(info.name),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => InviteScreen(mesh: widget.mesh, groupId: widget.groupId),
                  ),
                ),
                child: Text(tr('Invite', 'Inviter')),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Palette.line, width: 1)),
                  ),
                  child: Text(
                    tr('Mesh: ${meshStatusLine(widget.mesh)}', 'Maillage : ${meshStatusLine(widget.mesh)}'),
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ),
                Expanded(
                  child: messages.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            tr(
                              'No messages. Messages disappear on their own (auto-erase setting).',
                              'Aucun message. Les messages disparaissent tout seuls (réglage d\'effacement).',
                            ),
                            style: theme.bodyLarge?.copyWith(color: Palette.muted),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.all(16),
                          itemCount: messages.length,
                          itemBuilder: (_, i) => _MessageTile(messages[i]),
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              minLines: 1,
                              maxLines: 4,
                              keyboardType: TextInputType.multiline,
                              textCapitalization: TextCapitalization.sentences,
                              enableIMEPersonalizedLearning: false,
                              style: theme.bodyLarge,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                                hintText: 'Message',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 120,
                            height: 56,
                            child: FilledButton(
                              onPressed: _controller.text.trim().isEmpty || tooLong ? null : _send,
                              child: Text(tr('Send', 'Envoyer')),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tooLong
                            ? tr(
                                'Too long: $_bytes of ${MeshNode.maxBodyBytes} bytes.',
                                'Trop long : $_bytes sur ${MeshNode.maxBodyBytes} octets.',
                              )
                            : (_error ?? tr('$_bytes / ${MeshNode.maxBodyBytes} bytes', '$_bytes / ${MeshNode.maxBodyBytes} octets')),
                        style: theme.bodyMedium?.copyWith(
                          color: tooLong ? Palette.danger : Palette.muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      HoldToConfirmButton(
                        label: tr('Leave the group', 'Quitter le groupe'),
                        onConfirmed: _leave,
                        duration: const Duration(seconds: 2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile(this.message);

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final time = '${message.sentAt.toLocal().hour.toString().padLeft(2, '0')}:'
        '${message.sentAt.toLocal().minute.toString().padLeft(2, '0')}';
    final who = message.mine ? tr('You', 'Toi') : '${message.senderName} (${message.senderTag})';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        label: '$who, $time : ${message.text}',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: message.mine ? Palette.accent : Palette.line,
                width: 4,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$who  $time', style: theme.bodyMedium?.copyWith(color: Palette.muted)),
              SelectableText(message.text, style: theme.bodyLarge),
            ],
          ),
        ),
      ),
    );
  }
}
