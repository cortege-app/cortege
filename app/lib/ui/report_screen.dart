import 'package:flutter/material.dart';

import '../mesh/mesh_controller.dart';
import '../mesh/medic_service.dart';
import 'theme.dart';
import 'beacon_screens.dart';
import 'time_text.dart';
import 'widgets.dart';

/// Signaler un blessé aux medics de l'événement. Trois gestes, pas de menu : la
/// personne qui appuie a peut-être des gants et du stress.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  var _sending = false;
  String? _error;

  Future<void> _report(AlertKind kind) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.mesh.medic.report(kind);
    } on NoMedicChannelException {
      _error = 'Ce téléphone ne connaît pas le canal des medics.';
    } catch (_) {
      _error = 'L\'alerte n\'a pas pu partir. Réessaie, ou appelle le 15 ou le 112.';
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _share(SentAlert alert, AlertResponder responder) async {
    final shared = await widget.mesh.medic.sharePosition(alert.id, responder);
    if (!mounted || shared) return;
    setState(() {
      _error =
          'Position introuvable. Vérifie que la localisation est activée et autorisée, puis réessaie dehors.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final mesh = widget.mesh;
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final now = mesh.now();
        final alerts = mesh.medic.sentAlerts;
        return Scaffold(
          appBar: AppBar(title: const Text('Signaler un blessé')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!mesh.medic.hasChannel) ...[
                  Text(
                    'Ce téléphone ne connaît pas le canal des medics.',
                    style: theme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Elle arrive par un proche qui la connaît. Si tu as un binôme avec lui, elle te parvient toute seule dès que vous êtes à portée l'un de l'autre. Sinon, rejoins un groupe créé par un medic, ou scanne à nouveau son code de binôme.",
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'En attendant, appelle les secours si c\'est grave : 15 ou 112.',
                    style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ] else ...[
                  Text(
                    'Maintiens le doigt sur le bouton pour prévenir les medics.',
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  for (final kind in AlertKind.values) ...[
                    HoldToConfirmButton(
                      label: _sending ? 'Envoi...' : kind.label,
                      duration: const Duration(milliseconds: 1500),
                      onConfirmed: () => _report(kind),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    'Les medics reçoivent ta position arrondie à environ 200 m, sans ton nom. Ta position précise ne part que si tu l\'envoies toi-même à un medic qui a répondu.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  Text(
                    'L\'alerte passe de téléphone en téléphone. Si aucun medic n\'est à portée du maillage, elle ne l\'atteindra pas : on ne peut pas savoir si elle est arrivée avant qu\'un medic réponde.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: theme.bodyLarge?.copyWith(color: Palette.danger)),
                ],
                for (final alert in alerts) ...[
                  const SizedBox(height: 24),
                  _SentAlertCard(
                    alert: alert,
                    now: now,
                    onShare: (responder) => _share(alert, responder),
                    onHelp: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ImHereScreen(mesh: mesh, alertId: alert.id),
                      ),
                    ),
                    onCancel: () => mesh.medic.cancel(alert.id),
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

class _SentAlertCard extends StatelessWidget {
  const _SentAlertCard({
    required this.alert,
    required this.now,
    required this.onShare,
    required this.onHelp,
    required this.onCancel,
  });

  final SentAlert alert;
  final DateTime now;
  final void Function(AlertResponder responder) onShare;
  final VoidCallback onHelp;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Palette.danger, width: 2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${alert.kind.label} signalé', style: theme.titleLarge),
          Text(
            '${agoText(alert.sentAt, now)}${alert.hadPosition ? '' : ', sans position'}',
            style: theme.bodyMedium?.copyWith(color: Palette.muted),
          ),
          const SizedBox(height: 8),
          if (alert.responders.isEmpty)
            Text('Aucun medic n\'a encore répondu.', style: theme.bodyLarge)
          else
            for (final responder in alert.responders) ...[
              Text('${responder.name} arrive', style: theme.titleMedium),
              const SizedBox(height: 4),
              if (responder.positionShared)
                Text(
                  'Ta position précise lui a été envoyée.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                )
              else
                BigButton(
                  label: 'Envoyer ma position précise à ${responder.name}',
                  primary: false,
                  onPressed: () => onShare(responder),
                ),
              const SizedBox(height: 8),
            ],
          if (alert.responders.isNotEmpty) ...[
            BigButton(label: 'Aider à me trouver', primary: false, onPressed: onHelp),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          BigButton(label: 'Retirer cette alerte', primary: false, onPressed: onCancel),
          const SizedBox(height: 4),
          Text(
            'Retirer l\'alerte ne la rappelle pas chez les medics qui l\'ont déjà reçue. Elle disparaît de ce téléphone.',
            style: theme.bodySmall?.copyWith(color: Palette.muted),
          ),
        ],
      ),
    );
  }
}
