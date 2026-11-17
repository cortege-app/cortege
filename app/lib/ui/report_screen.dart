import 'package:flutter/material.dart';

import '../l10n/language.dart';
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
      _error = tr("This phone doesn't know the medics' channel.", 'Ce téléphone ne connaît pas le canal des medics.');
    } catch (_) {
      _error = tr(
        "The alert couldn't be sent. Try again, or call 15 or 112.",
        'L\'alerte n\'a pas pu partir. Réessaie, ou appelle le 15 ou le 112.',
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _share(SentAlert alert, AlertResponder responder) async {
    final shared = await widget.mesh.medic.sharePosition(alert.id, responder);
    if (!mounted || shared) return;
    setState(() {
      _error = tr(
        'Position not found. Check that location is on and allowed, then try again outdoors.',
        'Position introuvable. Vérifie que la localisation est activée et autorisée, puis réessaie dehors.',
      );
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
          appBar: AppBar(title: Text(tr('Report an injury', 'Signaler un blessé'))),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!mesh.medic.hasChannel) ...[
                  Text(
                    tr("This phone doesn't know the medics' channel.", 'Ce téléphone ne connaît pas le canal des medics.'),
                    style: theme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      "It comes from someone close to you who knows it. If you're buddies with them, it reaches you on its own as soon as you're in range of each other. Otherwise, join a group created by a medic, or scan their buddy code again.",
                      "Elle arrive par un proche qui la connaît. Si tu as un binôme avec lui, elle te parvient toute seule dès que vous êtes à portée l'un de l'autre. Sinon, rejoins un groupe créé par un medic, ou scanne à nouveau son code de binôme.",
                    ),
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr("Meanwhile, call emergency services if it's serious: 15 or 112.", 'En attendant, appelle les secours si c\'est grave : 15 ou 112.'),
                    style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ] else ...[
                  Text(
                    tr('Hold your finger on the button to alert the medics.', 'Maintiens le doigt sur le bouton pour prévenir les medics.'),
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  for (final kind in AlertKind.values) ...[
                    HoldToConfirmButton(
                      label: _sending ? tr('Sending...', 'Envoi...') : kind.label,
                      duration: const Duration(milliseconds: 1500),
                      onConfirmed: () => _report(kind),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    tr(
                      'Medics receive your position rounded to about 200 m, without your name. Your exact position is only sent if you send it yourself to a medic who has answered.',
                      'Les medics reçoivent ta position arrondie à environ 200 m, sans ton nom. Ta position précise ne part que si tu l\'envoies toi-même à un medic qui a répondu.',
                    ),
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  Text(
                    tr(
                      "The alert hops from phone to phone. If no medic is within reach of the mesh, it won't get to one: there's no way to know it arrived until a medic answers.",
                      'L\'alerte passe de téléphone en téléphone. Si aucun medic n\'est à portée du maillage, elle ne l\'atteindra pas : on ne peut pas savoir si elle est arrivée avant qu\'un medic réponde.',
                    ),
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
          Text(tr('${alert.kind.label} reported', '${alert.kind.label} signalé'), style: theme.titleLarge),
          Text(
            '${agoText(alert.sentAt, now)}${alert.hadPosition ? '' : tr(', no position', ', sans position')}',
            style: theme.bodyMedium?.copyWith(color: Palette.muted),
          ),
          const SizedBox(height: 8),
          if (alert.responders.isEmpty)
            Text(tr('No medic has answered yet.', 'Aucun medic n\'a encore répondu.'), style: theme.bodyLarge)
          else
            for (final responder in alert.responders) ...[
              Text(tr('${responder.name} is coming', '${responder.name} arrive'), style: theme.titleMedium),
              const SizedBox(height: 4),
              if (responder.positionShared)
                Text(
                  tr('Your exact position was sent to them.', 'Ta position précise lui a été envoyée.'),
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                )
              else
                BigButton(
                  label: tr('Send my exact position to ${responder.name}', 'Envoyer ma position précise à ${responder.name}'),
                  primary: false,
                  onPressed: () => onShare(responder),
                ),
              const SizedBox(height: 8),
            ],
          if (alert.responders.isNotEmpty) ...[
            BigButton(label: tr('Help them find me', 'Aider à me trouver'), primary: false, onPressed: onHelp),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          BigButton(label: tr('Withdraw this alert', 'Retirer cette alerte'), primary: false, onPressed: onCancel),
          const SizedBox(height: 4),
          Text(
            tr(
              "Withdrawing the alert doesn't recall it from medics who already received it. It disappears from this phone.",
              'Retirer l\'alerte ne la rappelle pas chez les medics qui l\'ont déjà reçue. Elle disparaît de ce téléphone.',
            ),
            style: theme.bodySmall?.copyWith(color: Palette.muted),
          ),
        ],
      ),
    );
  }
}
