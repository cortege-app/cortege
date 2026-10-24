import 'dart:async';

import 'vault_state.dart';
import 'vault_store.dart';

/// Retire de [state] les enregistrements périmés et renvoie leur nombre.
int sweepExpired(VaultState state, DateTime now) {
  final before = state.records.length;
  state.records.removeWhere((r) => r.isExpired(now, state.ttl));
  return before - state.records.length;
}

/// Retire les groupes sans activité depuis la durée d'effacement, avec leurs
/// clés. Quand le dernier groupe part, le secret d'événement part aussi : plus
/// rien ne permet de reconnaître les autres téléphones. Renvoie le nombre de
/// groupes retirés.
int sweepExpiredGroups(VaultState state, DateTime now) {
  final before = state.groups.length + state.buddies.length;
  state.groups.removeWhere((g) => g.isExpired(now, state.ttl));
  state.buddies.removeWhere((b) => b.isExpired(now, state.ttl));
  if (state.groups.isEmpty && state.buddies.isEmpty) {
    // Un canal des medics encore récent garde l'événement en vie.
    final last = state.medicActivity;
    final medicAlive =
        state.medicPublicKey != null && last != null && now.isBefore(last.add(state.ttl));
    if (!medicAlive) endEvent(state);
  }
  return before - (state.groups.length + state.buddies.length);
}

/// Retire les organisateurs de confiance qui n'ont rien donné depuis la durée
/// d'effacement. Renvoie leur nombre.
int sweepExpiredOrganizers(VaultState state, DateTime now) {
  final before = state.organizers.length;
  state.organizers.removeWhere((o) => o.isExpired(now, state.ttl));
  return before - state.organizers.length;
}

/// Oublie tout ce qui rattache ce téléphone à l'événement : plus de secret pour
/// reconnaître les autres téléphones, plus de clé du canal des medics, plus de
/// rôle medic.
void endEvent(VaultState state) {
  state.eventSecret = null;
  state.medicPublicKey = null;
  state.medicSecretKey = null;
  state.medicActive = false;
  state.medicActivity = null;
}

/// Balaye le coffre ouvert : au déverrouillage, au retour au premier plan, et
/// une fois par minute tant que l'appli est ouverte.
///
/// Chaque effacement est suivi d'un renouvellement du secret matériel (au plus
/// toutes les dix minutes) : les anciennes copies du coffre, restées dans la
/// mémoire flash, ne se relisent plus même avec le bon code.
///
/// Limite connue : si l'appli reste fermée plus longtemps que la durée choisie,
/// rien n'est effacé avant la prochaine ouverture (le contenu reste chiffré par
/// le PIN et le secret matériel entre-temps).
class AutoEraser {
  AutoEraser(
    this.session, {
    DateTime Function()? now,
    this.interval = const Duration(minutes: 1),
    this.onGroupsRemoved,
    this.onRecordsRemoved,
  }) : _now = now ?? DateTime.now;

  final VaultSession session;
  final Duration interval;
  final DateTime Function() _now;

  /// Appelé quand des groupes (donc des clés) viennent d'être effacés : le
  /// maillage doit les oublier aussi.
  void Function()? onGroupsRemoved;

  /// Appelé quand des enregistrements ou des organisateurs viennent d'être
  /// effacés : les fichiers qui en dépendent (la carte chiffrée) doivent suivre.
  void Function()? onRecordsRemoved;

  Timer? _timer;

  Future<int> sweepNow() async {
    final now = _now();
    final hadEvent = session.state.eventSecret != null;
    final records = sweepExpired(session.state, now);
    final organizers = sweepExpiredOrganizers(session.state, now);
    final groups = sweepExpiredGroups(session.state, now);
    // L'événement peut finir sans qu'aucun groupe ne soit retiré à ce tour : il
    // faut quand même couper la radio et enregistrer.
    final eventEnded = hadEvent && session.state.eventSecret == null;
    if (groups > 0 || eventEnded) onGroupsRemoved?.call();
    if (records + organizers > 0) onRecordsRemoved?.call();
    final removed = records + organizers + groups + (eventEnded ? 1 : 0);
    if (removed > 0) {
      await session.save();
      await _renewQuietly(session.renewSecret);
    } else if (session.renewalDue) {
      await _renewQuietly(session.flushRenewal);
    }
    return removed;
  }

  /// Un renouvellement raté n'empêche pas d'effacer : la session le retentera.
  Future<void> _renewQuietly(Future<void> Function() renew) async {
    try {
      await renew();
    } on Object {
      // Retenté au prochain passage.
    }
  }

  void start() {
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(sweepNow().then((_) {}, onError: (_) {}));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
