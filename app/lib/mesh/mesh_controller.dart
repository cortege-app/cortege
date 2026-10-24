import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../vault/vault_state.dart';
import '../vault/vault_store.dart';
import 'alert_signal.dart';
import 'buddy_service.dart';
import 'compass.dart';
import 'geo.dart';
import 'group.dart';
import 'medic_service.dart';
import 'mesh_crypto.dart';
import 'mesh_errors.dart';
import 'mesh_host.dart';
import 'mesh_node.dart';
import 'proximity.dart';
import 'torch.dart';
import 'transport.dart';
import '../vault/eraser.dart';

export 'mesh_errors.dart';

enum MeshStatus { stopped, starting, running, unavailable }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.groupId,
    required this.senderName,
    required this.senderTag,
    required this.text,
    required this.sentAt,
    required this.mine,
  });

  final String id;
  final String groupId;
  final String senderName;
  final String senderTag;
  final String text;
  final DateTime sentAt;
  final bool mine;
}

class GroupInfo {
  const GroupInfo({required this.id, required this.name, required this.messageCount});

  final String id;
  final String name;
  final int messageCount;
}

/// Fait le lien entre le coffre (groupes, binômes, clés, messages), le moteur du
/// maillage et la radio. Une instance par coffre ouvert ; elle disparaît au
/// verrouillage complet, et avec elle les clés en mémoire et le maillage.
class MeshController extends ChangeNotifier implements MeshHost {
  MeshController({
    required this.crypto,
    required this.session,
    this.transport,
    DateTime Function()? now,
    bool jitter = true,
    this.retryInterval = const Duration(seconds: 8),
    LocationProvider location = const NoLocation(),
    CompassProvider compass = const NoCompass(),
    Torch torch = const NoTorch(),
    this.signal = const NoSignal(),
    Duration silenceTolerance = const Duration(seconds: 30),
    Duration buddyWatchEvery = const Duration(seconds: 15),
    Duration firstCheckInDelay = const Duration(seconds: 3),
    List<Duration> medicResendDelays = MedicService.defaultResendDelays,
    Duration locationWait = const Duration(seconds: 8),
  })  : _now = now ?? DateTime.now,
        _node = MeshNode(
          crypto: crypto,
          now: now,
          maxMessageAge: session.state.ttl,
          relayDelay: jitter ? _randomRelayDelay : null,
        ) {
    buddies = BuddyService(
      this,
      silenceTolerance: silenceTolerance,
      watchEvery: buddyWatchEvery,
      firstCheckInDelay: firstCheckInDelay,
    );
    medic = MedicService(
      this,
      location: location,
      compass: compass,
      torch: torch,
      resendDelays: medicResendDelays,
      locationWait: locationWait,
    );
  }

  static final _random = Random();
  static Duration _randomRelayDelay() => Duration(milliseconds: 10 + _random.nextInt(110));

  static const kind = 'msg';

  /// Au plus ce nombre de messages en mémoire (voir [_trimMessages]).
  static const maxStoredMessages = 250;

  @override
  final MeshCrypto crypto;
  @override
  final VaultSession session;
  final MeshTransport? transport;
  final AlertSignal signal;

  /// Le binôme : check-in et surveillance du silence.
  late final BuddyService buddies;

  /// Le canal des medics et les alertes de blessés.
  late final MedicService medic;

  /// Quand la radio est indisponible pour une raison qui peut s'arranger seule
  /// (Bluetooth éteint), on réessaie à ce rythme.
  final Duration retryInterval;
  final DateTime Function() _now;
  final MeshNode _node;
  Timer? _retryTimer;
  var _retryable = false;

  final _groups = <String, MeshGroup>{};
  final _records = <String, GroupRecord>{};
  EventKeys? _keys;
  Uint8List? _runningEvent;
  StreamSubscription<ReceivedMessage>? _subscription;
  StreamSubscription<BuddyAlert>? _buddyAlerts;
  StreamSubscription<MedicEvent>? _medicEvents;
  var _status = MeshStatus.stopped;
  String? _statusDetail;
  var _stopped = false;

  MeshStatus get status => _status;
  String? get statusDetail => _statusDetail;
  int get neighborCount => _node.links.length;
  MeshStats get stats => _node.stats;
  String? get displayName => session.state.displayName;

  List<GroupInfo> get groups => [
        for (final entry in _groups.entries)
          GroupInfo(
            id: entry.key,
            name: entry.value.name,
            messageCount: session.state.records
                .where((r) => r.kind == kind && r.data['g'] == entry.key)
                .length,
          ),
      ];

  // MeshHost

  @override
  MeshNode get node => _node;

  @override
  DateTime now() => _now();

  @override
  bool get transportRunning => _status == MeshStatus.running;

  @override
  void saveVault({bool removal = false}) =>
      unawaited(session.save(removal: removal).then((_) {}, onError: (_) {}));

  @override
  void refreshChannels() {
    if (_stopped) return;
    _node.setChannels([...buddies.channels, ...medic.channels]);
  }

  @override
  Future<void> syncTransport() => _syncTransport();

  @override
  void learnMedicKey(Uint8List publicKey) => medic.learnPublicKey(publicKey);

  @override
  void medicKeyChanged() => buddies.sendRosterToAll();

  @override
  void endEventIfUnused() {
    final state = session.state;
    if (state.groups.isEmpty && state.buddies.isEmpty && state.medicSecretKey == null) {
      endEvent(state);
      medic.rebuild();
    }
  }

  @override
  Future<bool> setBeacon(Uint8List? beacon) async =>
      beacon == null ? (await transport?.setBeacon(null) ?? true) : (await transport?.setBeacon(beacon) ?? false);

  @override
  Stream<ProximityReading> get proximity => transport?.proximity ?? const Stream.empty();

  @override
  void changed() => notifyListeners();

  // Cycle de vie

  Future<void> start() async {
    _loadGroups();
    buddies.load();
    buddies.protectSendChains();
    medic.rebuild();
    refreshChannels();
    _subscription = _node.messages.listen(_onMessage);
    _buddyAlerts = buddies.alerts.listen((alert) {
      if (alert.silent) unawaited(signal.urgent());
    });
    _medicEvents = medic.events.listen((event) {
      if (event.type == MedicEventType.incoming) {
        unawaited(signal.urgent());
      } else {
        unawaited(signal.notice());
      }
    });
    await _syncTransport();
  }

  /// Arrête tout et oublie les clés en mémoire. À appeler avant de fermer le
  /// coffre.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _retryTimer?.cancel();
    _subscription?.cancel();
    _buddyAlerts?.cancel();
    _medicEvents?.cancel();
    buddies.dispose();
    medic.dispose();
    final active = transport;
    if (active != null) unawaited(active.stop().then((_) {}, onError: (_) {}));
    _keys?.dispose();
    _keys = null;
    _runningEvent = null;
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
    _records.clear();
    _node.setGroups(const []);
    _node.setChannels(const []);
    unawaited(_node.close());
    _status = MeshStatus.stopped;
  }

  /// Un réglage a changé (durée d'effacement, intervalle des check-ins).
  void refreshSettings() {
    _node.maxMessageAge = session.state.ttl;
    if (_status == MeshStatus.running) buddies.startTimers();
  }

  /// Des groupes viennent d'être effacés par l'effacement automatique.
  Future<void> reloadGroups() async {
    if (_stopped) return;
    _loadGroups();
    buddies.load();
    medic.rebuild();
    refreshChannels();
    await _syncTransport();
    notifyListeners();
  }

  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    final bytes = utf8.encode(trimmed);
    if (bytes.isEmpty || bytes.length > MeshNode.maxNameBytes) {
      throw ArgumentError('pseudo de 1 à ${MeshNode.maxNameBytes} octets attendu');
    }
    session.state.displayName = trimmed;
    await session.save();
    notifyListeners();
  }

  // Groupes

  /// Crée un groupe. Si ce téléphone n'est dans aucun événement, il en ouvre
  /// un nouveau (nouveau secret) ; sinon le groupe rejoint l'événement en cours.
  Future<GroupInvite> createGroup(String name) async {
    final state = session.state;
    final secret = state.eventSecret ?? crypto.randomBytes(32);
    final invite = GroupInvite(
      name: name.trim(),
      groupKey: crypto.randomBytes(32),
      eventSecret: secret,
      medicPublicKey: state.medicPublicKey,
    );
    await _join(invite);
    return invite;
  }

  /// Rejoint le groupe d'un QR. Lève [DifferentEventException] si ce
  /// téléphone est déjà dans un autre événement.
  Future<String> joinGroup(GroupInvite invite) async {
    final current = session.state.eventSecret;
    if (current != null && !_same(current, invite.eventSecret)) {
      throw DifferentEventException();
    }
    return _join(invite);
  }

  GroupInvite inviteFor(String groupId) {
    final group = _groups[groupId]!;
    return GroupInvite(
      name: group.name,
      groupKey: group.groupKey,
      eventSecret: session.state.eventSecret!,
      medicPublicKey: session.state.medicPublicKey,
    );
  }

  Future<void> leaveGroup(String groupId) async {
    final group = _groups.remove(groupId);
    final record = _records.remove(groupId);
    if (group == null || record == null) return;
    group.dispose();
    final state = session.state;
    state.groups.remove(record);
    state.records.removeWhere((r) => r.kind == kind && r.data['g'] == groupId);
    // Un medic garde son événement même sans groupe ; sinon, plus de groupe ni
    // de binôme, plus d'événement.
    endEventIfUnused();
    refreshChannels();
    _node.setGroups(_groups.values);
    await session.save(removal: true);
    await _syncTransport();
    notifyListeners();
  }

  /// Quitte l'événement en cours : tous les groupes (avec leurs messages), tous
  /// les binômes et le canal des medics. À faire avant de rejoindre un autre
  /// événement. Les autres membres gardent leurs copies jusqu'à leur propre
  /// effacement.
  Future<void> leaveEvent() async {
    final state = session.state;
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
    _records.clear();
    state.groups.clear();
    state.records.removeWhere((r) => r.kind == kind);
    buddies.leaveAll();
    medic.forgetAlerts();
    endEvent(state);
    medic.rebuild();
    _node.setGroups(const []);
    refreshChannels();
    await session.save(removal: true);
    await _syncTransport();
    notifyListeners();
  }

  /// Envoie [text] dans le groupe. Lève [NeedsDisplayNameException] tant qu'il
  /// n'y a pas de pseudo.
  Future<void> sendMessage(String groupId, String text) async {
    final name = session.state.displayName;
    if (name == null) throw NeedsDisplayNameException();
    final group = _groups[groupId];
    if (group == null) throw StateError('groupe inconnu');
    final message = _node.send(group, senderName: name, text: text.trim());
    _store(message);
  }

  List<ChatMessage> messagesOf(String groupId) {
    final records = session.state.records
        .where((r) => r.kind == kind && r.data['g'] == groupId)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return [
      for (final r in records)
        ChatMessage(
          id: r.id,
          groupId: groupId,
          senderName: r.data['n']! as String,
          senderTag: r.data['k']! as String,
          text: r.data['t']! as String,
          sentAt: r.createdAt,
          mine: r.data['m']! as bool,
        ),
    ];
  }

  // Interne

  void _loadGroups() {
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
    _records.clear();
    for (final record in session.state.groups) {
      final group = MeshGroup.create(
        crypto,
        name: record.name,
        groupKey: record.groupKey,
        signPublic: record.signPublic,
        signSecret: record.signSecret,
      );
      _groups[group.id] = group;
      _records[group.id] = record;
    }
    _node.setGroups(_groups.values);
  }

  Future<String> _join(GroupInvite invite) async {
    final state = session.state;
    state.eventSecret ??= invite.eventSecret;
    medic.learnPublicKey(invite.medicPublicKey);

    final fresh = MeshGroup.fromInvite(crypto, invite);
    final existing = _groups[fresh.id];
    if (existing != null) {
      fresh.dispose();
      return existing.id;
    }
    final now = _now();
    final record = GroupRecord(
      name: invite.name,
      groupKey: Uint8List.fromList(invite.groupKey),
      signPublic: fresh.signPublic,
      signSecret: fresh.signSecret.extractBytes(),
      joinedAt: now,
      lastActivity: now,
    );
    state.groups.add(record);
    _groups[fresh.id] = fresh;
    _records[fresh.id] = record;
    _node.setGroups(_groups.values);
    await session.save();
    await _syncTransport();
    notifyListeners();
    return fresh.id;
  }

  /// Aiguille un message reçu vers celui qui sait s'en servir.
  void _onMessage(ReceivedMessage message) {
    if (_stopped) return;
    if (message.type == MessageType.chat && _groups.containsKey(message.groupId)) {
      _store(message);
      return;
    }
    if (buddies.handle(message)) return;
    medic.handle(message);
  }

  void _store(ReceivedMessage message) {
    if (_stopped) return;
    final state = session.state;
    if (state.records.any((r) => r.id == message.id)) return;
    state.records.add(
      VaultRecord(
        id: message.id,
        kind: kind,
        createdAt: message.sentAt,
        data: {
          'g': message.groupId,
          'n': message.senderName,
          'k': message.senderTag,
          't': message.text,
          'm': message.mine,
        },
      ),
    );
    _records[message.groupId]?.lastActivity = _now();
    _trimMessages();
    unawaited(session.save().then((_) {}, onError: (_) {}));
    notifyListeners();
  }

  /// Le coffre a une taille fixe (256 Kio) : un groupe très bavard le remplirait,
  /// et plus aucune écriture ne passerait, y compris celle des chaînes de clés
  /// du binôme. On garde donc les messages les plus récents seulement.
  void _trimMessages() {
    final chat = session.state.records.where((r) => r.kind == kind).toList();
    final excess = chat.length - maxStoredMessages;
    if (excess <= 0) return;
    chat.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final drop = chat.take(excess).toSet();
    session.state.records.removeWhere(drop.contains);
  }

  var _syncChain = Future<void>.value();

  /// Met la radio en accord avec l'état du coffre : allumée s'il y a au moins
  /// un groupe, un binôme ou un canal des medics, éteinte sinon, redémarrée si
  /// l'événement a changé. Les mises en accord se font l'une après l'autre :
  /// démarrer la radio peut attendre une réponse à une demande de permission.
  Future<void> _syncTransport() {
    final next = _syncChain.then((_) => _doSyncTransport());
    _syncChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _doSyncTransport() async {
    final active = transport;
    if (active == null || _stopped) return;
    final state = session.state;
    final event = state.eventSecret;
    final wanted = event != null &&
        (_groups.isNotEmpty || state.buddies.isNotEmpty || state.medicPublicKey != null);

    if (_runningEvent != null && (!wanted || !_same(_runningEvent!, event))) {
      buddies.stopTimers();
      await active.stop();
      _node.clearLinks();
      _keys?.dispose();
      _keys = null;
      _runningEvent = null;
      _status = MeshStatus.stopped;
      notifyListeners();
    }
    if (!wanted || _runningEvent != null) return;

    _status = MeshStatus.starting;
    _statusDetail = null;
    notifyListeners();
    final keys = EventKeys(crypto, event);
    try {
      await active.start(
        keys,
        MeshTransportEvents(
          onFrame: _node.onFrame,
          onLinkUp: (link) {
            _node.addLink(link);
            notifyListeners();
          },
          onLinkDown: (id) {
            _node.removeLink(id);
            notifyListeners();
          },
          onFailure: _transportFailed,
        ),
      );
      if (_stopped) {
        // Le coffre s'est verrouillé pendant que la radio démarrait.
        keys.dispose();
        await active.stop();
        return;
      }
      _keys = keys;
      _runningEvent = Uint8List.fromList(event);
      _status = MeshStatus.running;
      _retryTimer?.cancel();
      buddies.radioStarted();
      buddies.startTimers();
    } on MeshTransportUnavailable catch (e) {
      keys.dispose();
      _status = MeshStatus.unavailable;
      _statusDetail = e.reason;
      _retryable = e.retryable;
      _scheduleRetry();
    } catch (e) {
      keys.dispose();
      _status = MeshStatus.unavailable;
      _statusDetail = 'erreur radio';
      _retryable = true;
      _scheduleRetry();
    }
    notifyListeners();
  }

  /// La radio s'est arrêtée pendant l'usage (Bluetooth éteint). On libère ce
  /// qu'elle tenait et on réessaie à intervalle régulier : dès que le Bluetooth
  /// revient, le maillage repart sans que l'utilisateur ait rien à faire.
  void _transportFailed(String reason, bool retryable) {
    final next = _syncChain.then((_) => _doTransportFailed(reason, retryable));
    _syncChain = next.then((_) {}, onError: (_) {});
  }

  Future<void> _doTransportFailed(String reason, bool retryable) async {
    final active = transport;
    if (active == null || _stopped || _runningEvent == null) return;
    buddies.stopTimers();
    try {
      await active.stop();
    } catch (_) {}
    _node.clearLinks();
    _keys?.dispose();
    _keys = null;
    _runningEvent = null;
    _status = MeshStatus.unavailable;
    _statusDetail = reason;
    _retryable = retryable;
    _scheduleRetry();
    notifyListeners();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (!_retryable || _stopped) return;
    _retryTimer = Timer(retryInterval, () {
      if (!_stopped && _status == MeshStatus.unavailable) unawaited(_syncTransport());
    });
  }

  /// Une opération qui se termine après l'arrêt du maillage (radio qui démarrait
  /// au moment du verrouillage) ne doit plus rien signaler.
  @override
  void notifyListeners() {
    if (_stopped) return;
    super.notifyListeners();
  }

  /// Relance la radio après un échec (Bluetooth rallumé, permission accordée).
  Future<void> retryTransport() => _syncTransport();

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
