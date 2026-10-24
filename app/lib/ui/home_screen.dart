import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../content/catalog.dart';
import '../mesh/mesh_controller.dart';
import 'buddy_screens.dart';
import 'fiches_screen.dart';
import 'medic_screens.dart';
import 'map_screens.dart';
import 'messages_screens.dart';
import 'organizer_screens.dart';
import 'placeholder_screen.dart';
import 'report_screen.dart';
import 'settings_screen.dart';
import 'share_screens.dart';
import 'theme.dart';
import 'widgets.dart';

/// Même écran pour le vrai coffre et pour le leurre : rien ici ne dit lequel
/// est ouvert.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  void _open(BuildContext context, String title) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PlaceholderScreen(title: title)),
      );

  void _openMesh(BuildContext context, String title, Widget Function(MeshController) build) {
    final mesh = controller.mesh;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => mesh == null ? PlaceholderScreen(title: title) : build(mesh),
      ),
    );
  }

  String _buddySubtitle(MeshController mesh) {
    final infos = mesh.buddies.infos;
    if (infos.isEmpty) return 'Check-in avec tes proches';
    final people = infos.expand((i) => i.others).length;
    final silent = infos.expand((i) => i.others).where((p) => p.silent).length;
    if (silent > 0) return silent == 1 ? '1 personne ne répond plus' : '$silent personnes ne répondent plus';
    if (people == 0) return "En attente d'un proche";
    return people == 1 ? '1 proche suivi' : '$people proches suivis';
  }

  void _openFiches(BuildContext context, FicheCategory category, String title) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FicheListScreen(
            category: category,
            title: title,
            catalog: ContentCatalog(bundle: DefaultAssetBundle.of(context)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = controller.session!.state;
    final mesh = controller.mesh;
    final hours = state.ttl.inHours;
    final count = state.records.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Cortège')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Palette.line, width: 2),
              ),
              child: Column(
                children: [
                  InfoRow('Effacement auto', '$hours h'),
                  InfoRow('Éléments en mémoire', '$count'),
                  if (mesh == null)
                    const InfoRow('Maillage', 'inactif')
                  else
                    ListenableBuilder(
                      listenable: mesh,
                      builder: (_, _) => InfoRow('Maillage', meshStatusLine(mesh)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (mesh != null)
              ListenableBuilder(
                listenable: mesh,
                builder: (context, _) => Column(
                  children: [
                    SilenceBanner(mesh: mesh),
                    MedicAlertBanner(
                      mesh: mesh,
                      onTap: () => _openMesh(context, 'Rôle medic', (m) => MedicScreen(mesh: m)),
                    ),
                  ],
                ),
              ),
            NavTile(
              title: 'Signaler un blessé',
              subtitle: 'Prévenir les medics',
              urgent: true,
              onTap: () => _openMesh(context, 'Signaler un blessé', (m) => ReportScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Messages',
              subtitle: 'Groupes et maillage',
              onTap: () => _openMesh(context, 'Messages', (m) => MessagesScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            if (mesh == null)
              NavTile(
                title: 'Binôme',
                subtitle: 'Check-in avec tes proches',
                onTap: () => _open(context, 'Binôme'),
              )
            else
              ListenableBuilder(
                listenable: mesh,
                builder: (context, _) => NavTile(
                  title: 'Binôme',
                  subtitle: _buddySubtitle(mesh),
                  onTap: () => _openMesh(context, 'Binôme', (m) => BuddyScreen(mesh: m)),
                ),
              ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Droits',
              subtitle: 'Contrôle, fouille, garde à vue',
              onTap: () => _openFiches(context, FicheCategory.droits, 'Droits'),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Secours',
              subtitle: 'Gestes de premiers secours',
              onTap: () => _openFiches(context, FicheCategory.secours, 'Secours'),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Rôle medic',
              subtitle: 'Recevoir les alertes de blessés',
              onTap: () => _openMesh(context, 'Rôle medic', (m) => MedicScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Carte',
              subtitle: 'Parcours et points utiles',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => MapScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Organisation',
              subtitle: 'Importer un événement, organisateurs',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => OrganizationScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Partager l\'appli',
              subtitle: 'Passer l\'appli à un proche, sans internet',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ShareAppScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Réglages',
              subtitle: 'Effacement, codes, verrouillage',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(controller: controller),
                ),
              ),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: 'Écran de code',
              primary: false,
              onPressed: controller.lockScreen,
            ),
          ],
        ),
      ),
    );
  }
}
