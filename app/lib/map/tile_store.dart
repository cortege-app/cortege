import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'mvt.dart';
import 'pmtiles.dart';
import 'tile_style.dart';

/// Les tuiles déjà lues, décodées et dessinées, avec une réserve de taille
/// limitée. Les tuiles sont demandées par l'écran à chaque image ; on les charge
/// trois à la fois, les plus utiles d'abord, sans bloquer l'interface.
class TileStore extends ChangeNotifier {
  TileStore(this.archive, {this.capacity = 140, this.parallel = 3});

  final PmtilesArchive archive;
  final int capacity;
  final int parallel;

  // Un numéro de tuile unique pour (zoom, x, y).
  final _ready = <int, RenderedTile>{};
  final _absent = <int>{};
  final _loading = <int>{};
  var _wanted = <int, (int, int, int)>{};
  var _disposed = false;

  /// La tuile si elle est prête, sinon null.
  RenderedTile? peek(int z, int x, int y) {
    final id = zxyToTileId(z, x, y);
    final tile = _ready.remove(id);
    if (tile != null) _ready[id] = tile; // la plus récemment utilisée en dernier
    return tile;
  }

  /// Vrai si le fichier ne contient pas cette tuile (inutile de la redemander).
  bool isAbsent(int z, int x, int y) => _absent.contains(zxyToTileId(z, x, y));

  /// Dit quelles tuiles sont visibles. Celles qui ne le sont plus ne sont plus
  /// chargées.
  void want(Iterable<(int, int, int)> tiles) {
    final next = <int, (int, int, int)>{};
    for (final t in tiles) {
      final id = zxyToTileId(t.$1, t.$2, t.$3);
      if (_ready.containsKey(id) || _absent.contains(id)) continue;
      next[id] = t;
    }
    _wanted = next;
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    for (final entry in _wanted.entries.toList()) {
      if (_loading.length >= parallel) return;
      if (_loading.contains(entry.key)) continue;
      _loading.add(entry.key);
      unawaited(_load(entry.key, entry.value));
    }
  }

  Future<void> _load(int id, (int, int, int) t) async {
    try {
      final bytes = await archive.tile(t.$1, t.$2, t.$3);
      if (_disposed) return;
      if (bytes == null) {
        _absent.add(id);
      } else {
        // Le décodage est un calcul pur : il se fait ailleurs que dans
        // l'interface. Le dessin, lui, doit se faire ici.
        final MvtTile decoded = await Isolate.run(() => decodeMvt(bytes));
        if (_disposed) return;
        _ready[id] = renderTile(decoded, t.$1, t.$2, t.$3);
        while (_ready.length > capacity) {
          _ready.remove(_ready.keys.first)?.dispose();
        }
      }
    } on Object catch (error) {
      // Une tuile abîmée ne doit pas empêcher d'afficher les autres.
      if (kDebugMode) debugPrint('cortege: tuile illisible ($error)');
      _absent.add(id);
    } finally {
      _loading.remove(id);
      _wanted.remove(id);
    }
    if (_disposed) return;
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tile in _ready.values) {
      tile.dispose();
    }
    _ready.clear();
    super.dispose();
  }
}
