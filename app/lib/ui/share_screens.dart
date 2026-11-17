import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/language.dart';
import '../mesh/mesh_crypto.dart';
import '../share/app_sharer.dart';
import 'organizer_screens.dart' show megabytesText;
import 'theme.dart';
import 'widgets.dart';

/// Les 8 premiers octets de l'empreinte, en quatre groupes de quatre signes :
/// assez court pour être lu à voix haute ou comparé sur deux écrans.
String shortFingerprint(List<int> hash) {
  final hex = hash.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
}

/// Passer l'appli à un proche sans internet : Bluetooth, Quick Share, clé USB.
/// L'appli copie son propre fichier d'installation, Android l'envoie.
class ShareAppScreen extends StatefulWidget {
  const ShareAppScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ShareAppScreen> createState() => _ShareAppScreenState();
}

class _ShareAppScreenState extends State<ShareAppScreen> {
  AppPackage? _package;
  String? _fingerprint;
  String? _problem;
  String? _sendProblem;

  AppSharer get _sharer => widget.controller.appSharer;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final package = await _sharer.prepare();
      final hash = await MeshCrypto(widget.controller.store.crypto).hashFile(package.file);
      if (!mounted) return;
      setState(() {
        _package = package;
        _fingerprint = shortFingerprint(hash);
      });
    } on AppShareException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    }
  }

  Future<void> _send() async {
    setState(() => _sendProblem = null);
    final opened = await _sharer.send();
    if (!opened && mounted) {
      setState(() => _sendProblem = tr("Can't open Android's share menu.", 'Impossible d\'ouvrir le partage d\'Android.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final package = _package;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Share the app', 'Partager l\'appli'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              tr(
                "You can pass Cortège to someone without internet: over Bluetooth, Quick Share or a USB stick. What you send is the app's file, the same one you were given. Your code, messages and groups aren't in it.",
                'Tu peux passer Cortège à un proche sans internet : par Bluetooth, Quick Share ou une clé USB. Ce que tu envoies est le fichier de l\'appli, le même qu\'on t\'a donné. Ton code, tes messages et tes groupes n\'y sont pas.',
              ),
              style: theme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(tr('For the person receiving it', 'Pour la personne qui reçoit'), style: theme.titleLarge),
            const SizedBox(height: 8),
            _Step(tr(
              'They open the file they received. Android asks them to allow installing from this source: they accept.',
              'Elle ouvre le fichier reçu. Android lui demande d\'autoriser l\'installation depuis cette source : elle accepte.',
            )),
            _Step(tr('They open Cortège and create their own code.', 'Elle ouvre Cortège et se crée son propre code.')),
            _Step(tr(
              'To check it\'s the same file, compare the fingerprint below: it also shows on their phone, under "Share the app".',
              'Pour vérifier que c\'est le même fichier, vous comparez l\'empreinte ci-dessous : elle s\'affiche aussi chez elle, dans « Partager l\'appli ».',
            )),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Palette.danger, width: 6)),
              ),
              child: Text(
                tr(
                  'Only accept the app from someone you trust. A modified file could read your messages.',
                  'Ne reçois l\'appli que d\'une personne en qui tu as confiance. Un fichier modifié pourrait lire tes messages.',
                ),
                style: theme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 24),
            if (_problem != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(border: Border.all(color: Palette.danger, width: 2)),
                child: Text(_problem!, style: theme.bodyLarge),
              )
            else if (package == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
                child: Column(
                  children: [
                    InfoRow(tr('Size', 'Taille'), megabytesText(package.size)),
                    InfoRow(tr('Fingerprint', 'Empreinte'), _fingerprint ?? ''),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'The file is copied for sending, then deleted the next time the vault is opened.',
                  'Le fichier est copié le temps de l\'envoi, puis supprimé à la prochaine ouverture du coffre.',
                ),
                style: theme.bodyMedium?.copyWith(color: Palette.muted),
              ),
              const SizedBox(height: 16),
              BigButton(label: tr('Send the app', 'Envoyer l\'appli'), onPressed: _send),
              if (_sendProblem != null) ...[
                const SizedBox(height: 8),
                Text(_sendProblem!, style: theme.bodyMedium?.copyWith(color: Palette.danger)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 12),
              child: Container(width: 10, height: 10, color: Palette.accent),
            ),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
          ],
        ),
      );
}
