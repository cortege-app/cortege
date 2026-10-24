import 'dart:typed_data';

import 'package:cortege/vault/hardware_secret.dart';

/// Remplace le Keystore dans les tests, avec les mêmes générations qu'Android :
/// un emplacement garde un secret, ou deux le temps d'un renouvellement.
class MemoryHardwareSecretStore implements HardwareSecretStore {
  final Map<int, List<_Entry>> _slots = {};

  /// Le secret le plus récent de chaque emplacement, pour les tests qui veulent
  /// savoir quels emplacements existent.
  Map<int, Uint8List> get secrets => {
        for (final e in _slots.entries)
          if (e.value.isNotEmpty) e.key: Uint8List.fromList(_newest(e.value).bytes),
      };

  /// Toutes les générations gardées pour un emplacement, pour vérifier qu'un
  /// ancien secret a bien disparu.
  List<int> generations(int slot) => [for (final e in _slots[slot] ?? const <_Entry>[]) e.generation];

  List<Uint8List> allSecretBytes(int slot) =>
      [for (final e in _slots[slot] ?? const <_Entry>[]) Uint8List.fromList(e.bytes)];

  _Entry _newest(List<_Entry> entries) => entries.reduce((a, b) => a.counter >= b.counter ? a : b);

  @override
  Future<List<StoredSecret>> loadAll(int slot) async {
    final entries = [...?_slots[slot]]..sort((a, b) => b.counter.compareTo(a.counter));
    return [for (final e in entries) StoredSecret(e.generation, Uint8List.fromList(e.bytes))];
  }

  @override
  Future<int> store(int slot, Uint8List secret) async {
    _slots[slot] = [_Entry(0, 1, Uint8List.fromList(secret))];
    return 0;
  }

  @override
  Future<int> rotate(int slot, Uint8List secret) async {
    final entries = _slots[slot] ?? [];
    if (entries.length != 1) throw StateError('un seul secret attendu');
    final current = entries.single;
    final generation = current.generation == 0 ? 1 : 0;
    entries.add(_Entry(generation, current.counter + 1, Uint8List.fromList(secret)));
    return generation;
  }

  @override
  Future<void> keepOnly(int slot, int generation) async {
    _slots[slot]?.removeWhere((e) => e.generation != generation);
  }

  @override
  Future<void> eraseAll() async => _slots.clear();
}

class _Entry {
  _Entry(this.generation, this.counter, this.bytes);

  final int generation;
  final int counter;
  final Uint8List bytes;
}
