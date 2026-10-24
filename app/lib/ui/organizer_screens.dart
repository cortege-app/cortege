import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../organizer/file_picker.dart';
import '../organizer/organizer_packet.dart';
import '../organizer/organizer_service.dart';
import '../vault/vault_state.dart';
import 'map_screens.dart';
import 'qr_scanner.dart';
import 'theme.dart';
import 'time_text.dart';
import 'widgets.dart';

/// Le message qui explique pourquoi un fichier d'événement ou une carte est refusé.
String describePacketProblem(PacketRejected rejected) => switch (rejected.problem) {
      PacketProblem.malformed => 'Ce fichier n\'est pas un événement Cortège lisible.',
      PacketProblem.tooBig => 'Ce fichier est trop gros pour un événement.',
      PacketProblem.badSignature =>
        'La signature ne correspond pas : le fichier a été modifié, ou il ne vient pas de la clé qu\'il annonce. Ne l\'utilise pas.',
      PacketProblem.unknownOrganizer =>
        'Ce fichier est signé par un organisateur que tu n\'as pas encore accepté (empreinte ${rejected.detail ?? '?'}).',
      PacketProblem.expired => 'Cet événement est expiré.',
      PacketProblem.notYetValid =>
        'La date de cet événement est dans le futur. Vérifie l\'heure de ton téléphone.',
      PacketProblem.older => 'Tu as déjà cet événement, ou une version plus récente.',
      PacketProblem.mapNotExpected =>
        'Cette carte n\'est annoncée par aucun de tes événements. Ouvre d\'abord le fichier de l\'événement.',
      PacketProblem.mapCorrupted =>
        'La carte ne correspond pas à celle que l\'organisateur a signée : elle est abîmée ou modifiée.',
    };

String megabytesText(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb < 1 ? '${(bytes / 1024).round()} Ko' : '${mb.toStringAsFixed(1)} Mo';
}

/// Événements reçus, organisateurs de confiance, carte hors ligne.
class OrganizationScreen extends StatefulWidget {
  const OrganizationScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  OrganizerService get _service => widget.controller.organizer!;

  Future<void> _importEvent() async {
    final picked = await widget.controller.filePicker.pick();
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EventImportScreen(controller: widget.controller, picked: picked),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final organizer = widget.controller.organizer;
    if (organizer == null) return const Scaffold();
    return ListenableBuilder(
      listenable: organizer,
      builder: (context, _) {
        final now = DateTime.now();
        final packets = _service.packets;
        final map = _service.mapInfo;
        return Scaffold(
          appBar: AppBar(title: const Text('Organisation')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'L\'organisateur envoie un seul fichier : parcours, points d\'eau, toilettes, rendez-vous, contacts, et la carte s\'il en joint une. Ouvre-le depuis ta messagerie, ou importe-le ici. Il est signé : l\'appli vérifie qui l\'a écrit avant de l\'afficher.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 24),
                Text('Événements', style: theme.titleLarge),
                const SizedBox(height: 8),
                if (packets.isEmpty)
                  Text(
                    'Aucun événement valable.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                for (final p in packets) ...[
                  NavTile(
                    title: p.payload.name,
                    subtitle:
                        '${p.payload.points.length} lieu${p.payload.points.length > 1 ? 'x' : ''}, jusqu\'à ${clockText(p.payload.expires.toLocal(), now)}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => PacketScreen(packet: p, organizerName: _nameOf(p))),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
                BigButton(
                  label: 'Importer un événement (fichier)',
                  primary: packets.isEmpty,
                  onPressed: _importEvent,
                ),
                const SizedBox(height: 24),
                Text('Carte hors ligne', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  map == null
                      ? 'Pas de carte. Sans elle, le parcours et les lieux s\'affichent quand même, sur un fond vide.'
                      : '${map.name}, ${megabytesText(map.size)}. Chiffrée sur le téléphone : elle disparaît avec l\'effacement automatique.',
                  style: theme.bodyMedium?.copyWith(color: map == null ? Palette.muted : Palette.text),
                ),
                const SizedBox(height: 8),
                BigButton(
                  label: 'Ouvrir la carte',
                  primary: false,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => MapScreen(controller: widget.controller)),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Organisateurs de confiance', style: theme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Un organisateur est ajouté quand tu compares son empreinte en important son fichier, ou en scannant son code QR.',
                  style: theme.bodyMedium?.copyWith(color: Palette.muted),
                ),
                const SizedBox(height: 8),
                if (_service.organizers.isEmpty)
                  Text(
                    'Aucun pour l\'instant.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                for (final o in _service.organizers) ...[
                  _OrganizerTile(
                    record: o,
                    onForget: () => unawaited(_service.forget(o.publicKey)),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
                BigButton(
                  label: 'Ajouter un organisateur (scanner)',
                  primary: false,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => OrganizerScanScreen(service: _service),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _nameOf(OrganizerPacket packet) {
    for (final o in _service.organizers) {
      if (o.publicKey.length == packet.organizerKey.length &&
          OrganizerPacket.fingerprintOf(o.publicKey) == packet.fingerprint) {
        return o.name;
      }
    }
    return 'organisateur inconnu';
  }
}

class _OrganizerTile extends StatelessWidget {
  const _OrganizerTile({required this.record, required this.onForget});

  final OrganizerRecord record;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.name, style: theme.titleMedium),
          Text(
            'Empreinte ${OrganizerPacket.fingerprintOf(record.publicKey)}',
            style: theme.bodyMedium?.copyWith(color: Palette.muted),
          ),
          const SizedBox(height: 8),
          HoldToConfirmButton(
            label: 'Ne plus faire confiance',
            duration: const Duration(seconds: 2),
            onConfirmed: onForget,
          ),
        ],
      ),
    );
  }
}

enum _ImportStage { reading, ready, importing, done, refused }

/// Ce que la personne s'apprête à accepter, puis le résultat. On arrive ici en
/// ouvrant un fichier avec Cortège depuis une messagerie, ou par « Importer un
/// événement ». Un organisateur inconnu n'est accepté qu'après avoir montré son
/// empreinte et reçu un appui explicite.
class EventImportScreen extends StatefulWidget {
  const EventImportScreen({super.key, required this.controller, required this.picked});

  final AppController controller;
  final PickedFile picked;

  @override
  State<EventImportScreen> createState() => _EventImportScreenState();
}

class _EventImportScreenState extends State<EventImportScreen> {
  var _stage = _ImportStage.reading;
  IncomingEvent? _event;
  PacketRejected? _problem;
  EventImported? _result;
  double? _progress;

  OrganizerService get _service => widget.controller.organizer!;

  @override
  void initState() {
    super.initState();
    unawaited(_inspect());
  }

  @override
  void dispose() {
    unawaited(_discard());
    super.dispose();
  }

  Future<void> _discard() async {
    try {
      if (await widget.picked.file.exists()) await widget.picked.file.delete();
    } on FileSystemException {
      // La copie temporaire sera nettoyée à la prochaine ouverture du coffre.
    }
  }

  Future<void> _inspect() async {
    try {
      final event = await _service.inspect(widget.picked.file);
      if (!mounted) return;
      setState(() {
        _event = event;
        _stage = _ImportStage.ready;
      });
    } on PacketRejected catch (rejected) {
      _refuse(rejected);
    } on FileSystemException {
      _refuse(PacketRejected(PacketProblem.malformed, 'lecture impossible'));
    }
  }

  void _refuse(PacketRejected rejected) {
    if (!mounted) return;
    setState(() {
      _problem = rejected;
      _stage = _ImportStage.refused;
    });
  }

  Future<void> _import({required bool trust}) async {
    final event = _event;
    if (event == null) return;
    setState(() {
      _stage = _ImportStage.importing;
      _progress = event.hasMap ? 0 : null;
    });
    try {
      final result = await _service.importEvent(
        event,
        trustSigner: trust,
        onProgress: (done, total) {
          if (mounted && total > 0) setState(() => _progress = done / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _ImportStage.done;
      });
    } on PacketRejected catch (rejected) {
      _refuse(rejected);
    } on FileSystemException {
      _refuse(PacketRejected(PacketProblem.malformed, 'écriture impossible'));
    }
  }

  String _mapLine(IncomingEvent e) {
    final announced = e.packet?.payload.map;
    if (e.hasMap) {
      if (announced == null) return 'jointe mais non annoncée : ignorée';
      if (!e.mapWanted) return 'déjà en place';
      return '${megabytesText(e.mapLength)}, jointe';
    }
    return announced == null ? 'aucune' : 'annoncée, non jointe';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return PopScope(
      canPop: _stage != _ImportStage.importing,
      child: Scaffold(
        appBar: AppBar(title: const Text('Événement')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: switch (_stage) {
              _ImportStage.reading => [
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 16),
                  Center(child: Text('Lecture du fichier...', style: theme.bodyLarge)),
                ],
              _ImportStage.refused => _refused(theme),
              _ImportStage.ready => _ready(theme),
              _ImportStage.importing => [
                  Text('Import en cours', style: theme.headlineSmall),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress, minHeight: 8),
                  const SizedBox(height: 12),
                  Text(
                    _event?.hasMap ?? false
                        ? 'La carte est vérifiée puis chiffrée sur le téléphone. Ça peut prendre un moment : ne quitte pas cet écran.'
                        : 'Un instant.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                ],
              _ImportStage.done => _done(theme),
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _refused(TextTheme theme) => [
        Text('Import impossible', style: theme.headlineSmall),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: Palette.danger, width: 2)),
          child: Text(describePacketProblem(_problem!), style: theme.bodyLarge),
        ),
        const SizedBox(height: 24),
        BigButton(label: 'Fermer', onPressed: () => Navigator.of(context).pop()),
      ];

  List<Widget> _ready(TextTheme theme) {
    final event = _event!;
    final packet = event.packet;
    if (packet == null) {
      return [
        Text('Carte hors ligne', style: theme.headlineSmall),
        const SizedBox(height: 8),
        InfoRow('Taille', megabytesText(event.mapLength)),
        const SizedBox(height: 8),
        Text(
          'Cette carte est comparée à ce que tes événements annoncent. Si elle n\'est pas la bonne, elle est refusée.',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
        ),
        const SizedBox(height: 24),
        BigButton(label: 'Importer la carte', onPressed: () => _import(trust: false)),
        const SizedBox(height: 12),
        BigButton(label: 'Annuler', primary: false, onPressed: () => Navigator.of(context).pop()),
      ];
    }
    final payload = packet.payload;
    final now = DateTime.now();
    return [
      Text(payload.name, style: theme.headlineSmall),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
        child: Column(
          children: [
            InfoRow('Valable jusqu\'à', clockText(payload.expires.toLocal(), now)),
            InfoRow('Lieux', '${payload.points.length}'),
            InfoRow('Contacts', '${payload.contacts.length}'),
            InfoRow('Carte', _mapLine(event)),
          ],
        ),
      ),
      if (!event.packetIsNew) ...[
        const SizedBox(height: 8),
        Text(
          'Tu as déjà cet événement. Ce fichier apporte la carte.',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
        ),
      ],
      if (payload.medicKey != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: Palette.accent, width: 2)),
          child: Text(
            'Cet événement fixe aussi la clé des medics : tes alertes de blessé, avec ta position, seront chiffrées pour cette clé. Ne l\'importe que si tu fais confiance à son organisateur.',
            style: theme.bodyLarge,
          ),
        ),
      ],
      const SizedBox(height: 16),
      if (event.trusted) ...[
        Text('Organisateur de confiance', style: theme.titleMedium),
        Text('${event.knownName}, empreinte ${packet.fingerprint}', style: theme.bodyLarge),
        const SizedBox(height: 24),
        BigButton(label: 'Importer', onPressed: () => _import(trust: false)),
        const SizedBox(height: 12),
        BigButton(label: 'Annuler', primary: false, onPressed: () => Navigator.of(context).pop()),
      ] else ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: Palette.accent, width: 2)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Organisateur inconnu', style: theme.titleLarge),
              const SizedBox(height: 8),
              Text('Empreinte', style: theme.bodyMedium?.copyWith(color: Palette.muted)),
              Text(packet.fingerprint, style: theme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                payload.organizerName.isEmpty
                    ? 'Il ne donne pas de nom.'
                    : 'Il se présente comme « ${payload.organizerName} ». C\'est lui qui l\'écrit : ça ne prouve rien.',
                style: theme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Compare l\'empreinte avec celle que l\'organisateur te donne de vive voix, sur son téléphone ou sur son papier. Si elle est différente, ou si tu ne peux pas la vérifier, n\'importe pas ce fichier : tout ce qu\'il signe s\'affichera comme sûr.',
                style: theme.bodyLarge,
              ),
            ],
          ),
        ),
        if (event.sameNameOtherKey) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(color: Palette.danger, width: 2)),
            child: Text(
              'Attention : tu as déjà un organisateur de ce nom, avec une autre empreinte. Quelqu\'un se fait peut-être passer pour lui.',
              style: theme.bodyLarge,
            ),
          ),
        ],
        const SizedBox(height: 24),
        BigButton(label: 'Faire confiance et importer', onPressed: () => _import(trust: true)),
        const SizedBox(height: 12),
        BigButton(label: 'Annuler', primary: false, onPressed: () => Navigator.of(context).pop()),
      ],
    ];
  }

  List<Widget> _done(TextTheme theme) {
    final result = _result!;
    final map = result.map;
    return [
      Text(result.packetAdded ? 'Événement en place' : 'Carte en place', style: theme.headlineSmall),
      if (result.packet != null) ...[
        const SizedBox(height: 4),
        Text(result.packet!.payload.name, style: theme.titleMedium),
      ],
      const SizedBox(height: 12),
      if (result.mapProblem != null)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: Palette.danger, width: 2)),
          child: Text(
            'L\'événement est en place, mais pas sa carte. ${describePacketProblem(result.mapProblem!)}',
            style: theme.bodyLarge,
          ),
        )
      else if (map != null)
        Text('Carte hors ligne en place : ${map.name}.', style: theme.bodyLarge)
      else
        Text(
          'Pas de carte avec cet événement : le parcours et les lieux s\'affichent sur un fond vide.',
          style: theme.bodyLarge,
        ),
      const SizedBox(height: 24),
      BigButton(
        label: 'Ouvrir la carte',
        onPressed: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => MapScreen(controller: widget.controller)),
        ),
      ),
      const SizedBox(height: 12),
      BigButton(label: 'Terminé', primary: false, onPressed: () => Navigator.of(context).pop()),
    ];
  }
}

/// Un événement : qui l'a signé, jusqu'à quand, ses lieux et ses contacts.
class PacketScreen extends StatelessWidget {
  const PacketScreen({super.key, required this.packet, required this.organizerName});

  final OrganizerPacket packet;
  final String organizerName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final payload = packet.payload;
    final now = DateTime.now();
    final byKind = <PointKind, List<OrganizerPoint>>{};
    for (final point in payload.points) {
      byKind.putIfAbsent(point.kind, () => []).add(point);
    }
    return Scaffold(
      appBar: AppBar(title: Text(payload.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
              child: Column(
                children: [
                  InfoRow('Signé par', organizerName),
                  InfoRow('Empreinte', packet.fingerprint),
                  InfoRow('Publié', clockText(payload.issued.toLocal(), now)),
                  InfoRow('Valable jusqu\'à', clockText(payload.expires.toLocal(), now)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Le contenu est vérifié par la signature avant d\'être affiché. Cela prouve qui l\'a écrit, pas que ce qu\'il dit est juste.',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
            for (final entry in byKind.entries) ...[
              const SizedBox(height: 24),
              Text('${entry.key.label} (${entry.value.length})', style: theme.titleLarge),
              const SizedBox(height: 8),
              for (final point in entry.value) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: pointColor(point.kind), width: 6)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(point.name.isEmpty ? entry.key.label : point.name, style: theme.titleMedium),
                      if (point.note.isNotEmpty) Text(point.note, style: theme.bodyLarge),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ],
            if (payload.contacts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Contacts', style: theme.titleLarge),
              const SizedBox(height: 8),
              for (final contact in payload.contacts) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(border: Border.all(color: Palette.line, width: 2)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(contact.name, style: theme.titleMedium),
                      SelectableText(contact.phone, style: theme.headlineSmall),
                      if (contact.note.isNotEmpty) Text(contact.note, style: theme.bodyMedium),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Scanne le code d'un organisateur, montre son nom et son empreinte, et ne fait
/// confiance qu'après confirmation.
class OrganizerScanScreen extends StatefulWidget {
  const OrganizerScanScreen({super.key, required this.service});

  final OrganizerService service;

  @override
  State<OrganizerScanScreen> createState() => _OrganizerScanScreenState();
}

class _OrganizerScanScreenState extends State<OrganizerScanScreen> {
  OrganizerInvite? _found;
  String? _message;
  var _done = false;

  void _onText(String text) {
    try {
      final invite = OrganizerInvite.decode(text);
      setState(() {
        _found = invite;
        _message = null;
      });
    } on FormatException {
      setState(() => _message = 'Ce QR n\'est pas un code d\'organisateur Cortège.');
    }
  }

  Future<void> _trust(OrganizerInvite invite) async {
    await widget.service.trust(invite);
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter un organisateur')),
      body: SafeArea(
        child: _done
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Organisateur ajouté.', style: theme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Tu peux maintenant ouvrir ses fichiers d\'événement.',
                    style: theme.bodyMedium?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 24),
                  BigButton(label: 'Terminé', onPressed: () => Navigator.of(context).pop()),
                ],
              )
            : found != null
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text('Faire confiance à cet organisateur ?', style: theme.titleLarge),
                      const SizedBox(height: 12),
                      Text(found.name, style: theme.headlineMedium),
                      Text('Empreinte ${found.fingerprint}', style: theme.titleMedium),
                      const SizedBox(height: 12),
                      Text(
                        'Compare cette empreinte avec celle que l\'organisateur te donne de vive voix, sur son téléphone ou sur son papier. Tout ce qu\'il signe sera affiché sur ta carte et dans tes infos.',
                        style: theme.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      BigButton(label: 'Faire confiance', onPressed: () => _trust(found)),
                      const SizedBox(height: 12),
                      BigButton(
                        label: 'Annuler',
                        primary: false,
                        onPressed: () => setState(() => _found = null),
                      ),
                    ],
                  )
                : QrScanner(
                    onText: _onText,
                    message: _message,
                    messageIsError: _message != null,
                    pasteLabel: 'Coller un code copié',
                  ),
      ),
    );
  }
}
