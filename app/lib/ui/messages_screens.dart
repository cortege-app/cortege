import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      return nothingToServe ? 'rien à relayer' : 'arrêté';
    case MeshStatus.starting:
      return 'démarrage...';
    case MeshStatus.running:
      final n = mesh.neighborCount;
      return n == 0 ? 'actif, aucun voisin' : 'actif, $n voisin${n > 1 ? 's' : ''}';
    case MeshStatus.unavailable:
      return mesh.statusDetail ?? 'indisponible';
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
                    InfoRow('Maillage', meshStatusLine(mesh)),
                    InfoRow('Pseudo', mesh.displayName ?? 'à choisir'),
                  ],
                ),
              ),
              if (mesh.status == MeshStatus.unavailable) ...[
                const SizedBox(height: 12),
                BigButton(label: 'Réessayer', primary: false, onPressed: mesh.retryTransport),
              ],
              const SizedBox(height: 8),
              Text(
                'Derrière l\'écran de code, le maillage continue pendant le délai réglé dans les réglages, puis il s\'arrête : tu ne reçois et tu ne relaies plus rien jusqu\'au prochain déverrouillage.',
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
                label: 'Créer un groupe',
                onPressed: () => _push(context, NewGroupScreen(mesh: mesh)),
              ),
              const SizedBox(height: 12),
              BigButton(
                label: 'Rejoindre avec un QR',
                primary: false,
                onPressed: () => _join(context),
              ),
              const SizedBox(height: 12),
              BigButton(
                label: 'Changer mon pseudo',
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
      setState(() => _error = 'Entre un pseudo de 1 à ${MeshNode.maxNameBytes} lettres.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Pseudo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'C\'est le nom que les autres voient à côté de tes messages. Choisis-en un qui ne te désigne pas.',
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
                labelText: 'Pseudo',
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            BigButton(label: 'Enregistrer', onPressed: _save),
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
        _error = 'Donne un nom au groupe (${GroupInvite.maxNameBytes} lettres au plus).';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau groupe')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Tu recevras un QR à faire scanner par les personnes que tu invites.',
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
                labelText: 'Nom du groupe',
                errorText: _error,
              ),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 16),
            BigButton(label: _busy ? 'Un instant...' : 'Créer', onPressed: _busy ? null : _create),
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
    setState(() => _copied = 'Copié. Il sera effacé du presse-papiers dans une minute.');
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
      appBar: AppBar(title: const Text('Inviter')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(invite.name, style: theme.headlineMedium),
            const SizedBox(height: 16),
            Center(child: QrCodeView(data: invite.encode(), size: width.clamp(200, 640))),
            const SizedBox(height: 16),
            Text(
              'Fais scanner ce QR par les personnes à inviter, en face de toi. L\'écran est au maximum de luminosité pour ça.',
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Quiconque le scanne peut lire et écrire dans le groupe. Ne le publie pas et ne le photographie pas.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: 'Ouvrir le groupe',
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => GroupScreen(mesh: widget.mesh, groupId: widget.groupId),
                ),
              ),
            ),
            const SizedBox(height: 12),
            BigButton(
              label: 'Copier l\'invitation en texte',
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
                child: const Text('Inviter'),
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
                    'Maillage : ${meshStatusLine(widget.mesh)}',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ),
                Expanded(
                  child: messages.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Aucun message. Les messages disparaissent tout seuls (réglage d\'effacement).',
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
                              child: const Text('Envoyer'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tooLong
                            ? 'Trop long : $_bytes sur ${MeshNode.maxBodyBytes} octets.'
                            : (_error ?? '$_bytes / ${MeshNode.maxBodyBytes} octets'),
                        style: theme.bodyMedium?.copyWith(
                          color: tooLong ? Palette.danger : Palette.muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      HoldToConfirmButton(
                        label: 'Quitter le groupe',
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
    final who = message.mine ? 'Toi' : '${message.senderName} (${message.senderTag})';
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
