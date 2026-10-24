import 'dart:io';
import 'dart:typed_data';

/// Trop d'essais de code ratés : il faut attendre [remaining] avant le suivant.
class LockedOut implements Exception {
  LockedOut(this.remaining);

  final Duration remaining;

  @override
  String toString() => 'LockedOut(${remaining.inSeconds} s)';
}

/// Freine les essais de code sur le téléphone : cinq essais, puis une attente qui
/// grandit à chaque échec (30 secondes, 1 minute, 5 minutes, 15 minutes, puis
/// 1 heure entre deux essais). Un code juste, le vrai ou celui de contrainte,
/// remet le compte à zéro. L'attente est la même pour tous les codes ratés : elle
/// ne dit rien d'un éventuel second coffre.
///
/// Le compte est écrit **avant** de vérifier le code : fermer l'appli en plein
/// essai ne permet pas de le rejouer gratuitement.
///
/// Ce que cela ne fait pas : si quelqu'un lit et modifie les fichiers de l'appli
/// (téléphone débloqué au niveau système), il peut remettre le compte à zéro. Il
/// se heurte alors à Argon2id et au secret gardé par le Keystore, qui ne dépendent
/// pas de ce compteur. Avancer l'horloge du téléphone raccourcit aussi l'attente ;
/// la reculer ne la raccourcit pas.
class AttemptLimiter {
  AttemptLimiter({required this.file, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final File file;
  final DateTime Function() _now;

  static const _length = 16;

  /// L'attente imposée après le [failures]-ième essai raté.
  static Duration delayAfter(int failures) {
    const steps = [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ];
    if (failures < 5) return Duration.zero;
    final index = failures - 5;
    return index < steps.length ? steps[index] : const Duration(hours: 1);
  }

  Future<({int failures, DateTime? lockedUntil})> _read() async {
    try {
      if (!await file.exists()) return (failures: 0, lockedUntil: null);
      final bytes = await file.readAsBytes();
      if (bytes.length != _length) return (failures: 0, lockedUntil: null);
      final view = ByteData.sublistView(bytes);
      final millis = view.getInt64(4, Endian.little);
      return (
        failures: view.getUint32(0, Endian.little),
        lockedUntil: millis <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(millis),
      );
    } on FileSystemException {
      return (failures: 0, lockedUntil: null);
    }
  }

  Future<void> _write(int failures, DateTime? lockedUntil) async {
    final bytes = Uint8List(_length);
    ByteData.sublistView(bytes)
      ..setUint32(0, failures, Endian.little)
      ..setInt64(4, lockedUntil?.millisecondsSinceEpoch ?? 0, Endian.little);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  /// Combien de temps attendre avant un nouvel essai (zéro : on peut essayer).
  Future<Duration> remaining() async {
    final state = await _read();
    final until = state.lockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    if (left <= Duration.zero) return Duration.zero;
    // Une horloge reculée ferait paraître l'attente plus longue que prévu : on
    // s'en tient à l'attente prévue, sans la raccourcir ni la rallonger.
    final planned = delayAfter(state.failures);
    return left > planned ? planned : left;
  }

  /// À appeler juste avant de vérifier un code.
  Future<void> recordAttempt() async {
    final state = await _read();
    final failures = state.failures >= 1000000 ? state.failures : state.failures + 1;
    final delay = delayAfter(failures);
    await _write(failures, delay == Duration.zero ? null : _now().add(delay));
  }

  /// Un code a ouvert un coffre : on repart de zéro.
  Future<void> reset() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Un compteur qui reste est sans danger : le prochain bon code le remettra à zéro.
    }
  }
}
