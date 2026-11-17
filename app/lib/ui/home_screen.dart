import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../content/catalog.dart';
import '../l10n/language.dart';
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
    if (infos.isEmpty) return tr('Check in with your people', 'Check-in avec tes proches');
    final people = infos.expand((i) => i.others).length;
    final silent = infos.expand((i) => i.others).where((p) => p.silent).length;
    if (silent > 0) {
      return silent == 1
          ? tr('1 person stopped answering', '1 personne ne répond plus')
          : tr('$silent people stopped answering', '$silent personnes ne répondent plus');
    }
    if (people == 0) return tr('Waiting for someone', "En attente d'un proche");
    return people == 1 ? tr('Following 1 person', '1 proche suivi') : tr('Following $people people', '$people proches suivis');
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
                  InfoRow(tr('Auto-erase', 'Effacement auto'), '$hours h'),
                  InfoRow(tr('Items in memory', 'Éléments en mémoire'), '$count'),
                  if (mesh == null)
                    InfoRow(tr('Mesh', 'Maillage'), tr('inactive', 'inactif'))
                  else
                    ListenableBuilder(
                      listenable: mesh,
                      builder: (_, _) => InfoRow(tr('Mesh', 'Maillage'), meshStatusLine(mesh)),
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
                      onTap: () => _openMesh(context, tr('Medic role', 'Rôle medic'), (m) => MedicScreen(mesh: m)),
                    ),
                  ],
                ),
              ),
            NavTile(
              title: tr('Report an injury', 'Signaler un blessé'),
              subtitle: tr('Alert the medics', 'Prévenir les medics'),
              urgent: true,
              onTap: () => _openMesh(context, tr('Report an injury', 'Signaler un blessé'), (m) => ReportScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: 'Messages',
              subtitle: tr('Groups and mesh', 'Groupes et maillage'),
              onTap: () => _openMesh(context, 'Messages', (m) => MessagesScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            if (mesh == null)
              NavTile(
                title: tr('Buddy', 'Binôme'),
                subtitle: tr('Check in with your people', 'Check-in avec tes proches'),
                onTap: () => _open(context, tr('Buddy', 'Binôme')),
              )
            else
              ListenableBuilder(
                listenable: mesh,
                builder: (context, _) => NavTile(
                  title: tr('Buddy', 'Binôme'),
                  subtitle: _buddySubtitle(mesh),
                  onTap: () => _openMesh(context, tr('Buddy', 'Binôme'), (m) => BuddyScreen(mesh: m)),
                ),
              ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Rights', 'Droits'),
              subtitle: tr('ID checks, searches, custody', 'Contrôle, fouille, garde à vue'),
              onTap: () => _openFiches(context, FicheCategory.droits, tr('Rights', 'Droits')),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('First aid', 'Secours'),
              subtitle: tr('First aid basics', 'Gestes de premiers secours'),
              onTap: () => _openFiches(context, FicheCategory.secours, tr('First aid', 'Secours')),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Medic role', 'Rôle medic'),
              subtitle: tr('Receive injury alerts', 'Recevoir les alertes de blessés'),
              onTap: () => _openMesh(context, tr('Medic role', 'Rôle medic'), (m) => MedicScreen(mesh: m)),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Map', 'Carte'),
              subtitle: tr('Route and useful places', 'Parcours et points utiles'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => MapScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Organization', 'Organisation'),
              subtitle: tr('Import an event, organizers', 'Importer un événement, organisateurs'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => OrganizationScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Share the app', 'Partager l\'appli'),
              subtitle: tr('Pass the app to someone, no internet needed', 'Passer l\'appli à un proche, sans internet'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ShareAppScreen(controller: controller)),
              ),
            ),
            const SizedBox(height: 8),
            NavTile(
              title: tr('Settings', 'Réglages'),
              subtitle: tr('Erasing, codes, locking', 'Effacement, codes, verrouillage'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(controller: controller),
                ),
              ),
            ),
            const SizedBox(height: 16),
            BigButton(
              label: tr('Lock screen', 'Écran de code'),
              primary: false,
              onPressed: controller.lockScreen,
            ),
          ],
        ),
      ),
    );
  }
}
