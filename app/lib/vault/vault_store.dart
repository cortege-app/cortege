import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import '../crypto/vault_crypto.dart';
import 'attempt_limiter.dart';
import 'hardware_secret.dart';
import 'pin_policy.dart';
import 'vault_state.dart';

class VaultFullException implements Exception {
  @override
  String toString() => 'VaultFullException';
}

/// Les secrets matériels ont disparu (téléphone réinitialisé, Keystore vidé,
/// effacement fait) : les fichiers sont là mais plus personne ne peut les lire.
class VaultUnrecoverable implements Exception {
  @override
  String toString() => 'VaultUnrecoverable';
}

/// Deux fichiers de même taille, `v0.bin` et `v1.bin`. L'un est le vrai coffre,
/// l'autre le leurre, ou du bruit aléatoire tant qu'aucun code de contrainte
/// n'est défini. Rien dans les noms, les tailles ou les en-têtes ne dit lequel
/// est lequel.
///
/// Fichier = sel | nonce | chiffré(contenu rempli jusqu'à une taille fixe) | tag.
class VaultStore {
  VaultStore({
    required this.crypto,
    required this.hardware,
    required this.directory,
    this.kdf = KdfParams.standard,
    this.renewalInterval = const Duration(minutes: 10),
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        _limiter = AttemptLimiter(
          file: File('${directory.path}${Platform.pathSeparator}t.bin'),
          now: now,
        );

  static const plainSize = 256 * 1024;
  static const _lengthPrefix = 4;
  static final _aad = utf8.encode('cortege/vault/1');

  final VaultCrypto crypto;
  final HardwareSecretStore hardware;
  final Directory directory;
  final KdfParams kdf;

  /// Au plus un renouvellement du secret matériel par cet intervalle : changer
  /// une clé du Keystore coûte, et des messages périment sans cesse.
  final Duration renewalInterval;
  final DateTime Function() _now;
  final AttemptLimiter _limiter;

  /// Combien de temps attendre avant de pouvoir retaper un code (zéro : tout de suite).
  Future<Duration> lockoutRemaining() => _limiter.remaining();

  int get fileSize => crypto.saltBytes + crypto.nonceBytes + plainSize + crypto.tagBytes;

  File slotFile(int slot) =>
      File('${directory.path}${Platform.pathSeparator}v$slot.bin');

  Future<bool> isInitialized() async =>
      await slotFile(0).exists() && await slotFile(1).exists();

  /// Crée les deux emplacements. Le vrai coffre prend au hasard le 0 ou le 1.
  Future<VaultSession> create({required String pin, String? duressPin}) async {
    PinPolicy.require(pin);
    if (duressPin != null) {
      PinPolicy.require(duressPin);
      if (duressPin == pin) throw PinRejected(PinProblem.alreadyUsed);
    }
    await wipe();
    final realSlot = crypto.randomBytes(1)[0] & 1;
    final decoySlot = 1 - realSlot;
    final session = await _writeFresh(
      realSlot,
      pin,
      VaultState(role: VaultRole.real),
    );
    if (duressPin != null) {
      final decoy = await _writeFresh(
        decoySlot,
        duressPin,
        VaultState(role: VaultRole.decoy),
      );
      decoy.lock();
    } else {
      await _writeFiller(decoySlot);
    }
    return session;
  }

  /// Essaie le PIN sur les deux emplacements, toujours les deux, pour que le
  /// temps de réponse ne dise rien. Null si le code ne correspond à aucun.
  ///
  /// Après quelques essais ratés, lève [LockedOut] avec le temps à attendre, même
  /// pour un code juste : l'attente ne dépend pas du code tapé.
  Future<VaultSession?> unlock(String pin) async {
    final wait = await _limiter.remaining();
    if (wait > Duration.zero) throw LockedOut(wait);
    final candidates = [await hardware.loadAll(0), await hardware.loadAll(1)];
    if (candidates[0].isEmpty && candidates[1].isEmpty) throw VaultUnrecoverable();
    await _limiter.recordAttempt();
    final attempts = await Future.wait([
      _tryOpen(0, pin, candidates[0]),
      _tryOpen(1, pin, candidates[1]),
    ]);
    final opened = attempts.whereType<_Opened>().toList()
      ..sort((a, b) => a.state.role.index.compareTo(b.state.role.index));
    if (opened.isEmpty) return null;
    for (final extra in opened.skip(1)) {
      extra.dispose();
    }
    await _limiter.reset();
    final winner = opened.first;
    if (candidates[winner.slot].length > 1) {
      // Un renouvellement a été interrompu : on ne garde que le secret qui ouvre
      // le fichier présent, l'autre n'a plus de raison d'exister.
      await hardware.keepOnly(winner.slot, winner.generation);
    }
    return VaultSession._(
      this,
      winner.slot,
      winner.salt,
      winner.pinKey,
      winner.key,
      winner.generation,
      winner.state,
    );
  }

  /// Détruit les secrets matériels d'abord (le coffre devient illisible tout de
  /// suite), puis supprime les fichiers.
  Future<void> wipe() async {
    await hardware.eraseAll();
    await _limiter.reset();
    for (final slot in [0, 1]) {
      final file = slotFile(slot);
      final tmp = File('${file.path}.tmp');
      if (await file.exists()) await file.delete();
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<VaultSession> _writeFresh(int slot, String pin, VaultState state) async {
    final secret = crypto.randomBytes(32);
    final generation = await hardware.store(slot, secret);
    final salt = crypto.randomBytes(crypto.saltBytes);
    final pinKey = await crypto.derivePinKey(pin: pin, salt: salt, params: kdf);
    final key = crypto.mixHardwareSecret(pinKey, secret);
    secret.fillRange(0, secret.length, 0);
    final session = VaultSession._(this, slot, salt, pinKey, key, generation, state);
    await _save(session);
    return session;
  }

  Future<void> _writeFiller(int slot) async {
    final secret = crypto.randomBytes(32);
    await hardware.store(slot, secret);
    secret.fillRange(0, secret.length, 0);
    await _writeAtomically(slotFile(slot), crypto.randomBytes(fileSize));
  }

  /// Ouvre un emplacement avec le PIN, en essayant ses secrets du plus récent au
  /// plus ancien (deux au plus : un renouvellement a pu être interrompu). Argon2id
  /// ne se calcule qu'une fois, il ne dépend pas du secret.
  Future<_Opened?> _tryOpen(int slot, String pin, List<StoredSecret> secrets) async {
    if (secrets.isEmpty) return null;
    final file = slotFile(slot);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length != fileSize) return null;
    final salt = Uint8List.fromList(Uint8List.sublistView(bytes, 0, crypto.saltBytes));
    final pinKey = await crypto.derivePinKey(pin: pin, salt: salt, params: kdf);
    for (final secret in secrets) {
      final key = crypto.mixHardwareSecret(pinKey, secret.bytes);
      final plain = crypto.open(
        key,
        Uint8List.sublistView(bytes, crypto.saltBytes),
        associatedData: Uint8List.fromList(_aad),
      );
      if (plain == null) {
        key.dispose();
        continue;
      }
      final state = _unframe(plain);
      plain.fillRange(0, plain.length, 0);
      return _Opened(slot, salt, pinKey, key, secret.generation, state);
    }
    pinKey.dispose();
    return null;
  }

  Future<bool> _pinOpens(int slot, String pin) async {
    final opened = await _tryOpen(slot, pin, await hardware.loadAll(slot));
    opened?.dispose();
    return opened != null;
  }

  Future<void> _save(VaultSession session) async {
    // Pendant un renouvellement du secret, on attend la nouvelle clé : un fichier
    // scellé avec l'ancienne, écrit après le nouveau, deviendrait illisible dès
    // que l'ancien secret est détruit.
    final gate = session._renewal;
    if (gate != null) await gate;
    // Se servir de la clé d'un coffre verrouillé ferait planter l'appli.
    if (session._locked) throw StateError('coffre verrouillé');
    return _write(session, session._key);
  }

  /// Scelle l'état avec [key] et l'écrit. Le chiffrement a lieu tout de suite, clé
  /// en main : on peut verrouiller (détruire la clé) sans attendre la fin de
  /// l'écriture. Les écritures partent l'une après l'autre, dans l'ordre, pour ne
  /// jamais se marcher dessus.
  Future<void> _write(VaultSession session, SecureKey key, {Uint8List? salt}) {
    final framed = _frame(session.state);
    final sealed = crypto.seal(
      key,
      framed,
      associatedData: Uint8List.fromList(_aad),
    );
    framed.fillRange(0, framed.length, 0);
    final file = (BytesBuilder(copy: false)
          ..add(salt ?? session._salt)
          ..add(sealed))
        .toBytes();
    final write = session._writes.then((_) => _writeAtomically(slotFile(session.slot), file));
    session._writes = write.then((_) {}, onError: (_) {});
    return write;
  }

  /// Change le secret matériel de l'emplacement et réécrit le coffre avec la
  /// clé qui en découle ; l'ancien secret est ensuite détruit, et avec lui toute
  /// possibilité de relire les anciennes copies du fichier restées dans la
  /// mémoire flash.
  ///
  /// Sans [force], au plus une fois par [renewalInterval] : une demande trop
  /// rapprochée est gardée en attente (voir [VaultSession.flushRenewal]).
  Future<void> _renew(VaultSession session, {required bool force}) async {
    if (session._locked) return;
    final now = _now();
    final last = session._lastRenewal;
    if (!force && last != null && now.difference(last) < renewalInterval) {
      session._renewalDue = true;
      return;
    }
    session._renewalDue = false;
    session._lastRenewal = now;
    try {
      await _exclusive(session, () async {
        await _renewNow(session);
        session.lastRenewed = _now();
      });
    } catch (_) {
      session._renewalDue = true;
      rethrow;
    }
  }

  /// Fait passer, l'une après l'autre, les opérations qui changent les clés d'une
  /// session (renouvellement du secret, changement de code), et fait attendre
  /// les enregistrements pendant ce temps (voir [_save]). Sans cela, un changement
  /// de code qui croise un renouvellement réécrirait le coffre avec un secret déjà
  /// détruit : le coffre serait perdu (trouvé par un test).
  Future<T> _exclusive<T>(VaultSession session, Future<T> Function() body) async {
    final done = Completer<void>();
    final previous = session._renewal;
    session._renewal = done.future;
    try {
      if (previous != null) await previous;
      return await body();
    } finally {
      if (identical(session._renewal, done.future)) session._renewal = null;
      done.complete();
    }
  }

  /// L'ordre des gestes garantit qu'une coupure à n'importe quel moment laisse un
  /// secret qui ouvre le fichier présent :
  /// 1. le nouveau secret s'ajoute à l'ancien, le fichier est encore sous l'ancien ;
  /// 2. le fichier est réécrit sous le nouveau (renommage atomique) ;
  /// 3. l'ancien secret est détruit.
  /// À l'ouverture, le plus récent est essayé en premier, puis l'autre.
  ///
  /// Les clés d'une session verrouillée sont détruites : s'en servir planterait
  /// l'appli. On vérifie donc [VaultSession._locked] juste avant chaque usage, sans
  /// attente entre la vérification et l'usage. Si le coffre se verrouille en
  /// route, on s'arrête là : le fichier reste lisible par l'un ou l'autre des deux
  /// secrets, et l'ouverture suivante garde celui qui convient.
  Future<void> _renewNow(VaultSession session) async {
    if (session._locked) return;
    await session._writes;
    await hardware.keepOnly(session.slot, session.generation);
    final secret = crypto.randomBytes(32);
    SecureKey? key;
    int? generation;
    try {
      generation = await hardware.rotate(session.slot, secret);
      if (session._locked) return;
      key = crypto.mixHardwareSecret(session._pinKey, secret);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
    try {
      await _write(session, key);
    } catch (_) {
      key.dispose();
      rethrow;
    }
    // Le fichier est maintenant sous la nouvelle clé : c'est elle que la session
    // doit tenir, même si la suite échoue.
    if (session._locked) {
      key.dispose();
    } else {
      session._key.dispose();
      session._key = key;
      session.generation = generation;
    }
    await hardware.keepOnly(session.slot, generation);
  }

  Future<void> _changePin(VaultSession session, String newPin) async {
    PinPolicy.require(newPin);
    await _exclusive(session, () async {
      if (session._locked) throw StateError('coffre verrouillé');
      // La vérification lit les fichiers : elle se fait ici, à l'abri d'un
      // renouvellement qui les réécrirait au même moment.
      final other = 1 - session.slot;
      if (await _pinOpens(other, newPin) || await _pinOpens(session.slot, newPin)) {
        throw PinRejected(PinProblem.alreadyUsed);
      }
      final current = (await hardware.loadAll(session.slot))
          .where((s) => s.generation == session.generation)
          .toList();
      if (current.isEmpty) throw VaultUnrecoverable();
      final salt = crypto.randomBytes(crypto.saltBytes);
      final pinKey = await crypto.derivePinKey(pin: newPin, salt: salt, params: kdf);
      final SecureKey key;
      try {
        if (session._locked) throw StateError('coffre verrouillé');
        key = crypto.mixHardwareSecret(pinKey, current.first.bytes);
      } catch (_) {
        pinKey.dispose();
        rethrow;
      }
      // Le fichier est écrit sous le nouveau code d'abord : si l'écriture échoue,
      // la session garde l'ancien code et rien n'a changé.
      try {
        await _write(session, key, salt: salt);
      } catch (_) {
        pinKey.dispose();
        key.dispose();
        rethrow;
      }
      if (session._locked) {
        pinKey.dispose();
        key.dispose();
        return;
      }
      session._key.dispose();
      session._pinKey.dispose();
      session._key = key;
      session._pinKey = pinKey;
      session._salt = salt;
    });
  }

  Future<void> _setDuressPin(VaultSession session, String duressPin) async {
    if (session.role != VaultRole.real) {
      throw StateError('le code de contrainte se règle depuis le vrai coffre');
    }
    PinPolicy.require(duressPin);
    if (await _pinOpens(session.slot, duressPin)) {
      throw PinRejected(PinProblem.alreadyUsed);
    }
    final decoy = await _writeFresh(
      1 - session.slot,
      duressPin,
      VaultState(role: VaultRole.decoy),
    );
    decoy.lock();
  }

  Future<void> _writeAtomically(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  Uint8List _frame(VaultState state) {
    final body = utf8.encode(jsonEncode(state.toJson()));
    if (body.length + _lengthPrefix > plainSize) throw VaultFullException();
    final out = Uint8List(plainSize);
    ByteData.sublistView(out).setUint32(0, body.length, Endian.little);
    out.setRange(_lengthPrefix, _lengthPrefix + body.length, body);
    return out;
  }

  VaultState _unframe(Uint8List plain) {
    final length = ByteData.sublistView(plain).getUint32(0, Endian.little);
    if (length > plain.length - _lengthPrefix) {
      throw const FormatException('coffre corrompu');
    }
    final json = jsonDecode(
      utf8.decode(Uint8List.sublistView(plain, _lengthPrefix, _lengthPrefix + length)),
    );
    return VaultState.fromJson(Map<String, Object?>.from(json as Map));
  }
}

class _Opened {
  _Opened(this.slot, this.salt, this.pinKey, this.key, this.generation, this.state);

  final int slot;
  final Uint8List salt;
  final SecureKey pinKey;
  final SecureKey key;
  final int generation;
  final VaultState state;

  void dispose() {
    pinKey.dispose();
    key.dispose();
  }
}

/// Un coffre ouvert. Les clés n'existent qu'en mémoire native, jusqu'à [lock].
class VaultSession {
  VaultSession._(
    this._store,
    this.slot,
    this._salt,
    this._pinKey,
    this._key,
    this.generation,
    this.state,
  );

  final VaultStore _store;
  final int slot;
  Uint8List _salt;

  /// Argon2id(PIN, sel), gardé pour pouvoir renouveler le secret matériel.
  SecureKey _pinKey;
  SecureKey _key;

  /// Génération du secret matériel qui a servi à la clé actuelle.
  int generation;

  /// Quand le secret matériel a été renouvelé pour la dernière fois depuis
  /// l'ouverture de ce coffre (null : pas encore).
  DateTime? lastRenewed;
  Future<void> _writes = Future.value();
  Future<void>? _renewal;
  DateTime? _lastRenewal;
  var _renewalDue = false;
  var _locked = false;
  final VaultState state;

  VaultRole get role => state.role;

  /// Enregistre le coffre. [removal] dit que quelque chose vient d'être retiré
  /// (un groupe quitté, un organisateur oublié) : le secret matériel est alors
  /// renouvelé, pour que les anciennes copies du fichier ne se relisent plus. Un
  /// échec du renouvellement n'empêche rien : il sera retenté.
  Future<void> save({bool removal = false}) async {
    await _store._save(this);
    if (removal) {
      try {
        await renewSecret();
      } on Object {
        // Retenté par le balayage suivant (voir [flushRenewal]).
      }
    }
  }

  /// À appeler après avoir effacé quelque chose : change le secret matériel, ce
  /// qui rend illisibles les anciennes copies du coffre. Au plus une fois toutes
  /// les dix minutes (sauf [force]) ; le reste attend [flushRenewal].
  Future<void> renewSecret({bool force = false}) => _store._renew(this, force: force);

  /// Une demande de renouvellement attend-elle son tour ?
  bool get renewalDue => _renewalDue;

  /// Fait le renouvellement mis en attente, si l'intervalle est écoulé.
  Future<void> flushRenewal() => _renewalDue ? renewSecret() : Future.value();

  Future<void> changePin(String newPin) => _store._changePin(this, newPin);

  /// Seulement depuis le vrai coffre. Remplace l'ancien code de contrainte.
  Future<void> setDuressPin(String duressPin) =>
      _store._setDuressPin(this, duressPin);

  void lock() {
    _locked = true;
    _key.dispose();
    _pinKey.dispose();
  }
}
