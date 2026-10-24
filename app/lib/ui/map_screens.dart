import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../map/map_view.dart';
import '../map/pmtiles.dart';
import '../map/tile_store.dart';
import '../mesh/geo.dart';
import '../organizer/organizer_packet.dart';
import '../organizer/organizer_service.dart';
import 'organizer_screens.dart';
import 'theme.dart';
import 'widgets.dart';

Color pointColor(PointKind kind) => switch (kind) {
      PointKind.water => const Color(0xFF5DADE2),
      PointKind.toilets => const Color(0xFFD7BDE2),
      PointKind.meeting => const Color(0xFFFFD60A),
      PointKind.dispersal => const Color(0xFFFF9F0A),
      PointKind.medic => const Color(0xFFFF6B5E),
      PointKind.legal => const Color(0xFFC9A0DC),
      PointKind.exit => const Color(0xFFFFFFFF),
      PointKind.info => const Color(0xFFBDBDBD),
    };

/// La carte hors ligne : fond de carte, parcours et lieux des organisateurs, et
/// la position de l'utilisateur s'il le demande. Aucune requête réseau.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  PmtilesArchive? _archive;
  TileStore? _store;
  MapCamera? _camera;
  var _loading = true;
  String? _error;

  // Ce qui est affiché : de quoi voir si un nouvel import change la carte.
  String? _loadedHash;
  var _loadedPoints = 0;
  OrganizerService? _watched;

  StreamSubscription<GeoPoint>? _updates;
  GeoPoint? _me;
  var _locating = false;
  String? _locationMessage;

  LocationProvider get _location =>
      widget.controller.mesh?.medic.location ?? const NoLocation();

  @override
  void initState() {
    super.initState();
    _watched = widget.controller.organizer?..addListener(_onOrganizerChange);
    unawaited(_load());
  }

  @override
  void dispose() {
    _watched?.removeListener(_onOrganizerChange);
    unawaited(_updates?.cancel());
    _store?.dispose();
    unawaited(_archive?.close());
    super.dispose();
  }

  /// Les parcours et les lieux de tous les événements valables.
  List<(double, double)> _points() {
    final packets = widget.controller.organizer?.packets ?? const [];
    return [
      for (final p in packets) ...p.payload.route,
      for (final p in packets)
        for (final point in p.payload.points) (point.lat, point.lon),
    ];
  }

  /// Un événement ou une carte vient d'arriver pendant que l'écran est ouvert.
  void _onOrganizerChange() {
    if (_loading) return;
    final hash = widget.controller.organizer?.mapInfo?.hash;
    final needsFrame = _store == null && _points().length != _loadedPoints;
    if (hash != _loadedHash || needsFrame || (_camera == null && _points().isNotEmpty)) {
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    _store?.dispose();
    final archive = _archive;
    _store = null;
    _archive = null;
    _camera = null;
    if (mounted) setState(() => _loading = true);
    await archive?.close();
    if (mounted) await _load();
  }

  Future<void> _load() async {
    try {
      final organizer = widget.controller.organizer;
      final archive = await organizer?.openMap();
      if (!mounted) {
        await archive?.close();
        return;
      }
      _loadedHash = organizer?.mapInfo?.hash;
      final points = _points();
      _loadedPoints = points.length;
      if (archive != null) {
        _archive = archive;
        _store = TileStore(archive);
        _camera = MapCamera.forArchive(archive);
      } else if (points.isNotEmpty) {
        // Pas de carte : le parcours et les lieux, sur un quadrillage.
        _camera = MapCamera.forPoints(points);
      }
      setState(() => _loading = false);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  MapOverlay _overlay() {
    final packets = widget.controller.organizer?.packets ?? const [];
    return MapOverlay(
      routes: [
        for (final p in packets)
          if (p.payload.route.length >= 2) p.payload.route,
      ],
      markers: [
        for (final p in packets)
          for (final point in p.payload.points)
            MapMarker(
              lat: point.lat,
              lon: point.lon,
              symbol: point.kind.symbol,
              label: point.name,
              color: pointColor(point.kind),
            ),
      ],
      meLat: _me?.lat,
      meLon: _me?.lon,
      meAccuracyMeters: _me?.accuracyMeters,
    );
  }

  Future<void> _toggleLocation() async {
    if (_updates != null) {
      await _updates!.cancel();
      setState(() {
        _updates = null;
        _me = null;
        _locationMessage = null;
      });
      return;
    }
    setState(() {
      _locating = true;
      _locationMessage = null;
    });
    // La première demande ouvre l'autorisation d'Android, et donne une position
    // tout de suite ; la suite arrive en continu.
    final first = await _location.current();
    if (!mounted) return;
    if (first == null) {
      setState(() {
        _locating = false;
        _locationMessage =
            'Position introuvable : la localisation est éteinte, refusée, ou le GPS ne capte pas.';
      });
      return;
    }
    final camera = _camera;
    setState(() {
      _locating = false;
      _me = first;
    });
    camera?.centerOn(first.lat, first.lon, zoom: camera.zoom < 14 ? 15 : camera.zoom);
    _updates = _location.updates().listen((point) {
      if (mounted) setState(() => _me = point);
    });
  }

  void _recenter() {
    final me = _me;
    if (me != null) _camera?.centerOn(me.lat, me.lon);
  }

  void _showMarker(MapMarker marker) {
    final packets = widget.controller.organizer?.packets ?? const [];
    OrganizerPoint? point;
    for (final p in packets) {
      for (final candidate in p.payload.points) {
        if (candidate.lat == marker.lat && candidate.lon == marker.lon && candidate.name == marker.label) {
          point = candidate;
        }
      }
    }
    final me = _me;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Palette.background,
      shape: const RoundedRectangleBorder(side: BorderSide(color: Palette.line, width: 2)),
      builder: (context) {
        final theme = Theme.of(context).textTheme;
        final distance = me == null ? null : describeOffset(me, GeoPoint(marker.lat, marker.lon));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(point?.kind.label ?? 'Lieu', style: theme.bodyMedium?.copyWith(color: Palette.muted)),
                Text(marker.label.isEmpty ? (point?.kind.label ?? 'Lieu') : marker.label, style: theme.headlineSmall),
                if (distance != null) ...[
                  const SizedBox(height: 4),
                  Text(distance, style: theme.titleMedium),
                ],
                if (point != null && point.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(point.note, style: theme.bodyLarge),
                ],
                const SizedBox(height: 12),
                BigButton(label: 'Fermer', primary: false, onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final organizer = widget.controller.organizer;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Carte'),
            if (!_loading && _store == null && _camera != null)
              Text(
                'Sans fond de carte',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Palette.muted),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => OrganizationScreen(controller: widget.controller)),
            ),
            child: const Text('Organisation'),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _camera == null
                ? _NoMap(error: _error, controller: widget.controller)
                : organizer == null
                    ? const SizedBox.shrink()
                    : ListenableBuilder(
                        listenable: organizer,
                        builder: (context, _) => Stack(
                          children: [
                            Positioned.fill(
                              child: MapView(
                                store: _store,
                                camera: _camera!,
                                overlay: _overlay(),
                                onMarkerTap: _showMarker,
                              ),
                            ),
                            Positioned(
                              right: 12,
                              top: 12,
                              child: Column(
                                children: [
                                  _MapButton(label: '+', onPressed: () => _camera!.zoomBy(1), tooltip: 'Zoom avant'),
                                  const SizedBox(height: 8),
                                  _MapButton(label: '-', onPressed: () => _camera!.zoomBy(-1), tooltip: 'Zoom arrière'),
                                  const SizedBox(height: 8),
                                  _MapButton(
                                    label: _locating ? '...' : (_updates == null ? 'GPS' : 'GPS'),
                                    selected: _updates != null,
                                    onPressed: _toggleLocation,
                                    tooltip: _updates == null ? 'Afficher ma position' : 'Masquer ma position',
                                  ),
                                  if (_updates != null) ...[
                                    const SizedBox(height: 8),
                                    _MapButton(label: '><', onPressed: _recenter, tooltip: 'Me centrer'),
                                  ],
                                ],
                              ),
                            ),
                            if (_locationMessage != null)
                              Positioned(
                                left: 12,
                                right: 72,
                                top: 12,
                                child: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Palette.background,
                                    border: Border.all(color: Palette.danger, width: 2),
                                  ),
                                  child: Text(_locationMessage!),
                                ),
                              ),
                          ],
                        ),
                      ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.label,
    required this.onPressed,
    required this.tooltip,
    this.selected = false,
  });

  final String label;
  final VoidCallback onPressed;
  final String tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? Palette.accent : Palette.background,
              border: Border.all(color: selected ? Colors.black : Palette.text, width: 2),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: label.length > 1 ? 16 : 28,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.black : Palette.text,
              ),
            ),
          ),
        ),
      );
}

class _NoMap extends StatelessWidget {
  const _NoMap({required this.error, required this.controller});

  final String? error;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          error == null ? 'Pas d\'événement sur ce téléphone' : 'La carte ne s\'ouvre pas',
          style: theme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          error == null
              ? 'L\'organisateur t\'envoie un fichier d\'événement : ouvre-le avec Cortège depuis ta messagerie, ou importe-le depuis « Organisation ». L\'appli ne télécharge rien, tout se passe sur le téléphone.'
              : 'Le fichier est abîmé ou n\'a pas la bonne clé. Réimporte l\'événement depuis « Organisation ».',
          style: theme.bodyLarge,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: theme.bodyMedium?.copyWith(color: Palette.muted)),
        ],
        const SizedBox(height: 24),
        if (error == null) ...[
          BigButton(
            label: 'Importer un événement (fichier)',
            onPressed: () async {
              final picked = await controller.filePicker.pick();
              if (picked == null || !context.mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EventImportScreen(controller: controller, picked: picked),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
        ],
        BigButton(
          label: 'Organisation',
          primary: error != null,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => OrganizationScreen(controller: controller)),
          ),
        ),
      ],
    );
  }
}
