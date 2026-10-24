import 'package:flutter/material.dart';

import '../mesh/mesh_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// Un téléphone n'est que dans un événement à la fois. Quand on scanne le code
/// d'un autre événement, on dit ce qui serait quitté et on laisse le choix.
class LeaveEventPrompt extends StatelessWidget {
  const LeaveEventPrompt({
    super.key,
    required this.mesh,
    required this.busy,
    required this.onLeave,
    required this.onCancel,
  });

  final MeshController mesh;
  final bool busy;
  final VoidCallback onLeave;
  final VoidCallback onCancel;

  String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final parts = [
      if (mesh.groups.isNotEmpty) _count(mesh.groups.length, 'groupe', 'groupes'),
      if (mesh.buddies.infos.isNotEmpty) _count(mesh.buddies.infos.length, 'binôme', 'binômes'),
      if (mesh.medic.hasChannel) 'le canal des medics',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Ce code vient d\'un autre événement', style: theme.headlineSmall),
        const SizedBox(height: 12),
        Text(
          'Un téléphone ne peut être que dans un événement à la fois. Pour rejoindre celui-ci, ton téléphone doit quitter l\'actuel${parts.isEmpty ? '' : ' : ${parts.join(', ')}'}.',
          style: theme.bodyLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Les messages de tes groupes sont effacés de ce téléphone. Les autres personnes gardent leurs copies jusqu\'à leur propre effacement.',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
        ),
        const SizedBox(height: 24),
        BigButton(
          label: busy ? 'Un instant...' : 'Quitter et rejoindre',
          onPressed: busy ? null : onLeave,
        ),
        const SizedBox(height: 12),
        BigButton(label: 'Annuler', primary: false, onPressed: busy ? null : onCancel),
      ],
    );
  }
}
