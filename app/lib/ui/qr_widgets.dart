import 'package:flutter/material.dart';

import '../mesh/group.dart';
import '../mesh/mesh_controller.dart';
import '../mesh/qr_codec.dart';
import 'event_prompt.dart';
import 'qr_scanner.dart';
import 'theme.dart';
import 'widgets.dart';

/// Un code QR noir sur blanc avec sa marge, la seule combinaison que tous les
/// lecteurs lisent bien, même en plein soleil.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, this.size = 320});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Code QR',
        image: true,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _QrPainter(encodeQr(data))),
        ),
      );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.matrix);

  final QrMatrix matrix;
  static const _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final cell = size.width / (matrix.size + 2 * _quiet);
    final black = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < matrix.size; y++) {
      for (var x = 0; x < matrix.size; x++) {
        if (!matrix.modules[y][x]) continue;
        canvas.drawRect(
          Rect.fromLTWH((x + _quiet) * cell, (y + _quiet) * cell, cell + 0.6, cell + 0.6),
          black,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.matrix != matrix;
}

/// Scanne le QR d'un groupe avec la caméra. Renvoie l'identifiant du groupe
/// rejoint.
class JoinGroupScreen extends StatefulWidget {
  const JoinGroupScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  GroupInvite? _found;
  String? _message;
  var _joining = false;

  /// Le groupe scanné vient d'un autre événement : on attend la décision.
  var _conflict = false;

  void _onText(String text) {
    try {
      final invite = GroupInvite.decode(text);
      setState(() {
        _found = invite;
        _message = null;
      });
    } on FormatException {
      setState(() => _message = 'Ce QR n\'est pas une invitation de groupe Cortège.');
    }
  }

  void _cancel() => setState(() {
        _found = null;
        _message = null;
      });

  Future<void> _join(GroupInvite invite) async {
    setState(() => _joining = true);
    try {
      final id = await widget.mesh.joinGroup(invite);
      if (mounted) Navigator.of(context).pop(id);
    } on DifferentEventException {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _conflict = true;
      });
    }
  }

  Future<void> _leaveAndJoin(GroupInvite invite) async {
    setState(() => _joining = true);
    await widget.mesh.leaveEvent();
    if (!mounted) return;
    setState(() => _conflict = false);
    await _join(invite);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: const Text('Rejoindre un groupe')),
      body: SafeArea(
        child: found != null && _conflict
            ? LeaveEventPrompt(
                mesh: widget.mesh,
                busy: _joining,
                onLeave: () => _leaveAndJoin(found),
                onCancel: () => setState(() {
                  _conflict = false;
                  _found = null;
                }),
              )
            : found != null
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Groupe trouvé', style: theme.titleMedium),
                  const SizedBox(height: 8),
                  Text(found.name, style: theme.headlineMedium),
                  const SizedBox(height: 16),
                  Text(
                    'Quand tu rejoins, tout le groupe peut lire tes messages, et ton téléphone rejoint le réseau des gens de l\'événement.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 24),
                  BigButton(
                    label: _joining ? 'Un instant...' : 'Rejoindre',
                    onPressed: _joining ? null : () => _join(found),
                  ),
                  const SizedBox(height: 12),
                  BigButton(label: 'Annuler', primary: false, onPressed: _joining ? null : _cancel),
                ],
              )
            : QrScanner(
                onText: _onText,
                message: _message,
                messageIsError: _message != null,
                pasteLabel: 'Coller une invitation copiée',
              ),
      ),
    );
  }
}
