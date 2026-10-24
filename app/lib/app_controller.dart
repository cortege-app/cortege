import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dart:io';

import 'mesh/mesh_controller.dart';
import 'mesh/mesh_crypto.dart';
import 'organizer/file_picker.dart';
import 'organizer/organizer_service.dart';
import 'share/app_sharer.dart';
import 'vault/attempt_limiter.dart';
import 'vault/eraser.dart';
import 'vault/pin_policy.dart';
import 'vault/vault_store.dart';

enum AppPhase { starting, needsSetup, locked, unlocked, unrecoverable, failed }

/// État de l'appli : coffre fermé ou ouvert, verrouillage à deux niveaux,
/// effacement automatique, maillage. L'interface ne touche au coffre que par
/// ici.
///
/// Deux niveaux de verrouillage :
/// 1. **Écran de code** ([lockScreen]) : l'interface demande le code et ne
///    montre plus rien. Derrière, la clé du coffre et le maillage restent en
///    mémoire, pour que le téléphone continue de recevoir et de relayer dans
///    la poche, écran éteint.
/// 2. **Verrouillage complet** ([lock]) : la clé est détruite en mémoire et le
///    maillage s'arrête. Il se déclenche tout seul après la durée choisie
///    (`closeAfter`), ou à la demande.
///
/// Le prix du premier niveau : tant que la clé reste en mémoire, quelqu'un qui
/// saisit le téléphone allumé et sait extraire la mémoire pourrait la
/// récupérer. L'écran de code, lui, protège d'un simple regard.
class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    DateTime Function()? now,
    this.backgroundGrace = const Duration(seconds: 30),
    this.meshFactory,
    this.mapsDirectory,
    this.filePicker = const NoFilePicker(),
    this.appSharer = const NoAppSharer(),
  }) : _now = now ?? DateTime.now;

  final VaultStore store;

  /// Délai avant l'écran de code, tant qu'aucun coffre n'est ouvert pour en
  /// dire plus (le réglage vit dans le coffre).
  final Duration backgroundGrace;

  /// Fabrique le maillage d'un coffre qui vient de s'ouvrir. Null dans les
  /// tests qui n'ont pas besoin de radio.
  final MeshController Function(VaultSession session)? meshFactory;
  final DateTime Function() _now;

  /// Où vivent les cartes chiffrées. Null dans les tests sans carte.
  final Directory? mapsDirectory;

  /// Choix d'un fichier (paquet, carte).
  final FilePicker filePicker;

  /// Passer l'appli à un proche, de téléphone à téléphone.
  final AppSharer appSharer;

  OrganizerService? _organizer;

  AppPhase _phase = AppPhase.starting;
  VaultSession? _session;
  AutoEraser? _eraser;
  MeshController? _mesh;
  Object? _failure;
  DateTime? _backgroundedAt;
  DateTime? _screenLockedAt;
  Timer? _screenLockTimer;
  Timer? _closeTimer;

  AppPhase get phase => _phase;

  /// Non null aussi derrière l'écran de code, tant que le coffre est en mémoire.
  VaultSession? get session => _session;
  MeshController? get mesh => _mesh;

  /// Les organisateurs, leurs paquets et la carte. Null derrière un coffre fermé.
  OrganizerService? get organizer => _organizer;
  Object? get failure => _failure;

  /// Vrai quand l'écran de code est affiché mais que le coffre et le maillage
  /// tournent encore en mémoire.
  bool get runningBehindLock => _phase == AppPhase.locked && _session != null;

  Duration get _screenLockDelay => _session?.state.lockAfter ?? backgroundGrace;

  Future<void> start() async {
    try {
      _phase = await store.isInitialized() ? AppPhase.locked : AppPhase.needsSetup;
    } catch (error) {
      _fail(error);
      return;
    }
    notifyListeners();
  }

  /// Lève [PinRejected] si un code ne passe pas la politique.
  Future<void> setUp({required String pin, String? duressPin}) async {
    final VaultSession session;
    try {
      session = await store.create(pin: pin, duressPin: duressPin);
    } on PinRejected {
      rethrow;
    } catch (error) {
      _fail(error);
      return;
    }
    await _open(session);
  }

  /// Combien de temps attendre avant de retaper un code, après trop d'essais ratés.
  Future<Duration> lockoutRemaining() => store.lockoutRemaining();

  /// Vrai si le code ouvre un coffre (le vrai ou le leurre, l'appli ne dit pas
  /// lequel).
  ///
  /// Si un coffre est déjà en mémoire derrière l'écran de code et que le code
  /// ouvre le même, on le réutilise tel quel : le maillage n'est pas coupé. Si
  /// le code ouvre l'autre coffre (le code de contrainte, par exemple), le
  /// premier est fermé tout de suite.
  Future<bool> unlock(String pin) async {
    final VaultSession? opened;
    try {
      opened = await store.unlock(pin);
    } on LockedOut {
      // Trop d'essais ratés : l'écran de code affiche l'attente ([lockoutRemaining]).
      return false;
    } on VaultUnrecoverable {
      _closeSession();
      _phase = AppPhase.unrecoverable;
      notifyListeners();
      return false;
    } catch (error) {
      // Une panne passagère du Keystore ne doit pas détruire un coffre qui
      // tourne déjà derrière l'écran de code : on refuse simplement ce code.
      if (_session != null) return false;
      _fail(error);
      return false;
    }
    if (opened == null) return false;

    final live = _session;
    if (live != null && live.slot == opened.slot) {
      // Même coffre : la copie ouverte à l'instant n'a plus d'utilité.
      opened.lock();
      _screenLockTimer?.cancel();
      _screenLockTimer = null;
      _closeTimer?.cancel();
      _closeTimer = null;
      _screenLockedAt = null;
      _backgroundedAt = null;
      _phase = AppPhase.unlocked;
      notifyListeners();
      unawaited(_eraser?.sweepNow().then((_) {}, onError: (_) {}));
      return true;
    }
    _closeSession();
    await _open(opened);
    return true;
  }

  Future<void> _open(VaultSession session) async {
    final eraser = AutoEraser(session, now: _now);
    try {
      await eraser.sweepNow();
    } catch (_) {
      // Un échec d'écriture ne doit pas empêcher d'ouvrir ; le balayage
      // suivant réessaiera.
    }
    final mesh = meshFactory?.call(session);
    eraser.onGroupsRemoved = () {
      if (mesh != null) unawaited(mesh.reloadGroups());
    };
    final directory = mapsDirectory;
    if (directory != null) {
      // Un dossier par coffre : ouvrir le coffre leurre ne doit pas effacer les
      // cartes du vrai, qui ne figurent pas dans ses enregistrements.
      final organizer = OrganizerService(
        session: session,
        crypto: MeshCrypto(store.crypto),
        mapsDirectory: Directory('${directory.path}${Platform.pathSeparator}coffre${session.slot}'),
        now: _now,
        learnMedicKey: (key) => mesh?.learnMedicKey(key),
      );
      eraser.onRecordsRemoved = () => unawaited(organizer.cleanFiles().then((_) {}, onError: (_) {}));
      _organizer = organizer;
      unawaited(organizer.cleanFiles().then((_) {}, onError: (_) {}));
      unawaited(_dropLegacyMaps(directory));
      unawaited(filePicker.clean());
    }
    eraser.start();
    _session = session;
    _eraser = eraser;
    _mesh = mesh;
    _phase = AppPhase.unlocked;
    notifyListeners();
    // La radio démarre en arrière-plan : elle peut attendre une réponse à une
    // demande de permission, l'écran d'accueil ne doit pas attendre.
    if (mesh != null) unawaited(mesh.start());
  }

  /// Avant les dossiers par coffre, les cartes chiffrées étaient posées à la
  /// racine : aucune ne s'y retrouve plus, on les supprime.
  Future<void> _dropLegacyMaps(Directory root) async {
    try {
      if (!await root.exists()) return;
      await for (final entry in root.list()) {
        if (entry is File) await entry.delete();
      }
    } on FileSystemException {
      // Un fichier encore ouvert partira au prochain passage.
    }
  }

  /// Niveau 1 : affiche l'écran de code. Le coffre et le maillage restent en
  /// mémoire jusqu'à la fin de `closeAfter`, sauf si ce délai est nul.
  void lockScreen() {
    final session = _session;
    if (session == null || _phase != AppPhase.unlocked) return;
    final closeAfter = session.state.closeAfter;
    if (closeAfter <= Duration.zero) {
      lock();
      return;
    }
    _screenLockTimer?.cancel();
    _screenLockTimer = null;
    _backgroundedAt = null;
    _screenLockedAt = _now();
    _closeTimer?.cancel();
    _closeTimer = Timer(closeAfter, lock);
    _phase = AppPhase.locked;
    notifyListeners();
  }

  /// Niveau 2 : détruit la clé en mémoire et arrête le maillage. Il faudra le
  /// code pour tout rouvrir.
  void lock() {
    if (_session == null) return;
    _closeSession();
    _phase = AppPhase.locked;
    notifyListeners();
  }

  Future<void> setTtl(Duration ttl) async {
    final session = _session;
    if (session == null) return;
    session.state.ttl = ttl;
    await session.save();
    await _eraser?.sweepNow();
    _mesh?.refreshSettings();
    notifyListeners();
  }

  Future<void> setLockAfter(Duration lockAfter) async {
    final session = _session;
    if (session == null) return;
    session.state.lockAfter = lockAfter;
    await session.save();
    notifyListeners();
  }

  Future<void> setCheckInEvery(Duration every) async {
    final session = _session;
    if (session == null) return;
    session.state.checkInEvery = every;
    await session.save();
    _mesh?.refreshSettings();
    notifyListeners();
  }

  Future<void> setCloseAfter(Duration closeAfter) async {
    final session = _session;
    if (session == null) return;
    session.state.closeAfter = closeAfter;
    await session.save();
    notifyListeners();
  }

  /// Détruit le coffre, les codes et tous les secrets. Sans retour.
  Future<void> wipeEverything() async {
    _closeSession();
    try {
      await store.wipe();
      final maps = mapsDirectory;
      if (maps != null && await maps.exists()) await maps.delete(recursive: true);
      await filePicker.clean(all: true);
    } catch (error) {
      _fail(error);
      return;
    }
    _phase = AppPhase.needsSetup;
    notifyListeners();
  }

  void didEnterBackground() {
    if (_session == null || _phase != AppPhase.unlocked) return;
    _backgroundedAt ??= _now();
    _screenLockTimer ??= Timer(_screenLockDelay, lockScreen);
  }

  void didReturnToForeground() {
    final left = _backgroundedAt;
    final delay = _screenLockDelay;
    _backgroundedAt = null;
    _screenLockTimer?.cancel();
    _screenLockTimer = null;
    final session = _session;
    if (session == null) return;
    final now = _now();

    // Les minuteurs peuvent être retardés quand le téléphone dort : on
    // recompte avec l'horloge.
    final lockedAt = _screenLockedAt;
    if (_phase == AppPhase.locked &&
        lockedAt != null &&
        now.difference(lockedAt) >= session.state.closeAfter) {
      lock();
      return;
    }
    if (_phase == AppPhase.unlocked && left != null && now.difference(left) >= delay) {
      lockScreen();
      return;
    }
    unawaited(_eraser?.sweepNow().then((_) {}, onError: (_) {}));
  }

  void _closeSession() {
    _eraser?.stop();
    _eraser = null;
    _mesh?.dispose();
    _mesh = null;
    _organizer?.dispose();
    _organizer = null;
    _session?.lock();
    _session = null;
    _screenLockTimer?.cancel();
    _screenLockTimer = null;
    _closeTimer?.cancel();
    _closeTimer = null;
    _backgroundedAt = null;
    _screenLockedAt = null;
  }

  void _fail(Object error) {
    _closeSession();
    _failure = error;
    _phase = AppPhase.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _closeSession();
    super.dispose();
  }
}
