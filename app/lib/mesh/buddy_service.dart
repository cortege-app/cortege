import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../vault/vault_state.dart';
import 'buddy_invite.dart';
import 'channels.dart';
import 'mesh_errors.dart';
import 'mesh_host.dart';
import 'mesh_node.dart';
import 'names.dart';

enum BuddyScanOutcome {
  /// On vient de rejoindre le binôme de la personne scannée : à elle, maintenant,
  /// de scanner notre code.
  joined,

  /// Une nouvelle personne est ajoutée à un binôme qu'on a déjà.
  added,

  /// Cette personne est déjà dans le binôme.
  alreadyKnown,

  /// On a scanné son propre code.
  ownCode,
}

class BuddyPerson {
  const BuddyPerson({
    required this.name,
    required this.keyTag,
    required this.lastHeard,
    required this.silent,
  });

  final String name;
  final String keyTag;
  final DateTime? lastHeard;
  final bool silent;
}

class BuddyInfo {
  const BuddyInfo({
    required this.id,
    required this.ownName,
    required this.others,
    required this.lastCheckIn,
  });

  /// Identifiant local du binôme (hexadécimal), jamais transmis.
  final String id;
  final String ownName;
  final List<BuddyPerson> others;
  final DateTime? lastCheckIn;

  bool get hasSilent => others.any((p) => p.silent);
}

/// Quelqu'un du binôme ne donne plus de nouvelles ([silent]), ou en redonne.
class BuddyAlert {
  const BuddyAlert({required this.buddyId, required this.name, required this.silent});

  final String buddyId;
  final String name;
  final bool silent;
}

/// Le binôme : 2 à 4 proches appairés en face à face. Chacun a sa chaîne de
/// clés ; on s'envoie un check-in à intervalle régulier, et on prévient quand
/// quelqu'un se tait.
///
/// « Sort de portée » veut dire ici : on n'entend plus rien de cette personne
/// dans le maillage. L'appli ne sait pas où elle est, et ne le saura jamais.
class BuddyService {
  BuddyService(
    this.host, {
    this.silenceTolerance = const Duration(seconds: 30),
    this.watchEvery = const Duration(seconds: 15),
    this.firstCheckInDelay = const Duration(seconds: 3),
  });

  final MeshHost host;

  /// Marge ajoutée à deux intervalles de check-in avant de déclarer un silence.
  final Duration silenceTolerance;

  /// Fréquence à laquelle on regarde qui s'est tu.
  final Duration watchEvery;

  /// Délai avant le premier check-in, une fois la radio démarrée.
  final Duration firstCheckInDelay;

  final _channels = <String, BuddyChannel>{};
  final _records = <String, BuddyRecord>{};
  final _heard = <String, DateTime>{};
  final _watchedSince = <String, DateTime>{};
  final _silent = <String>{};
  final _checkIns = <String, int>{};
  final _lastOwnCheckIn = <String, DateTime>{};
  final _alerts = StreamController<BuddyAlert>.broadcast(sync: true);
  Timer? _checkInTimer;
  Timer? _watchTimer;
  Timer? _firstCheckIn;
  DateTime? _radioSince;

  Stream<BuddyAlert> get alerts => _alerts.stream;

  Iterable<FrameChannel> get channels => _channels.values;

  bool get isEmpty => _records.isEmpty;

  /// Charge les binômes du coffre et prépare leurs canaux.
  void load() {
    for (final channel in _channels.values) {
      channel.dispose();
    }
    _channels.clear();
    _records.clear();
    final now = host.now();
    for (final record in host.session.state.buddies) {
      final channel = BuddyChannel(host.crypto, record);
      _channels[channel.id] = channel;
      _records[channel.id] = record;
      for (final member in record.members) {
        _watchedSince.putIfAbsent(_key(channel.id, member.signPublic), () => now);
      }
    }
  }

  /// Numéros sautés dans notre chaîne d'envoi à chaque réouverture du coffre.
  static const reopenSkip = 8;

  /// À appeler une fois à l'ouverture d'un coffre, après [load].
  void protectSendChains() {
    if (_channels.isEmpty) return;
    for (final channel in _channels.values) {
      channel.advanceSendChain(reopenSkip);
    }
    host.saveVault();
  }

  /// La radio vient de (re)démarrer : pendant qu'elle était coupée, on n'a rien
  /// pu entendre, donc personne n'a le droit d'être déclaré muet à cause de ça.
  void radioStarted() {
    _radioSince = host.now();
  }

  void dispose() {
    stopTimers();
    for (final channel in _channels.values) {
      channel.dispose();
    }
    _channels.clear();
    _records.clear();
    unawaited(_alerts.close());
  }

  // Appairage

  /// Crée un binôme dont on est la seule personne pour l'instant.
  Future<BuddyInvite> create() async {
    final state = host.session.state;
    final name = state.displayName;
    if (name == null) throw NeedsDisplayNameException();
    state.eventSecret ??= host.crypto.randomBytes(32);
    final record = _newRecord(
      id: host.crypto.randomBytes(8),
      tagKey: host.crypto.randomBytes(32),
      ownName: name,
    );
    await _store(record);
    return inviteFor(_idOf(record));
  }

  /// L'identifiant local du binôme d'un code.
  String idForInvite(BuddyInvite invite) => _idFromBytes(invite.binomeId);

  /// Notre propre code, avec l'état actuel de notre chaîne.
  BuddyInvite inviteFor(String buddyId) {
    final record = _records[buddyId]!;
    final state = host.session.state;
    return BuddyInvite(
      binomeId: record.id,
      eventSecret: state.eventSecret!,
      tagKey: record.tagKey,
      name: record.ownName,
      signPublic: record.signPublic,
      chainKey: record.sendChainKey,
      chainIndex: record.sendIndex,
      medicPublicKey: state.medicPublicKey,
    );
  }

  /// Traite le code scanné d'un proche.
  Future<({BuddyScanOutcome outcome, String buddyId})> accept(BuddyInvite invite) async {
    final state = host.session.state;
    final current = state.eventSecret;
    if (current != null && !_sameBytes(current, invite.eventSecret)) {
      throw DifferentEventException();
    }
    final buddyId = _idFromBytes(invite.binomeId);
    final existing = _records[buddyId];

    // Même si la personne est déjà dans le binôme, son code peut nous apprendre
    // le canal des medics.
    final medicKey = invite.medicPublicKey;
    if (medicKey != null) host.learnMedicKey(medicKey);

    if (existing != null) {
      if (_sameBytes(existing.signPublic, invite.signPublic)) {
        return (outcome: BuddyScanOutcome.ownCode, buddyId: buddyId);
      }
      final known = existing.members.any((m) => _sameBytes(m.signPublic, invite.signPublic));
      if (known) return (outcome: BuddyScanOutcome.alreadyKnown, buddyId: buddyId);
      if (existing.isFull) throw BuddyFullException();
      existing.members.add(
        BuddyMemberRecord(
          name: invite.name,
          signPublic: invite.signPublic,
          chainKey: Uint8List.fromList(invite.chainKey),
          nextIndex: invite.chainIndex,
        ),
      );
      _watchedSince[_key(buddyId, invite.signPublic)] = host.now();
      existing.lastActivity = host.now();
      host.saveVault();
      host.changed();
      // Les autres connaissent maintenant cette personne grâce à nous.
      sendRoster(buddyId);
      return (outcome: BuddyScanOutcome.added, buddyId: buddyId);
    }

    final name = state.displayName;
    if (name == null) throw NeedsDisplayNameException();
    state.eventSecret ??= invite.eventSecret;
    final record = _newRecord(
      id: invite.binomeId,
      tagKey: invite.tagKey,
      ownName: name,
    )..members.add(
        BuddyMemberRecord(
          name: invite.name,
          signPublic: invite.signPublic,
          chainKey: Uint8List.fromList(invite.chainKey),
          nextIndex: invite.chainIndex,
        ),
      );
    await _store(record);
    return (outcome: BuddyScanOutcome.joined, buddyId: buddyId);
  }

  /// Quitte tous les binômes d'un coup (changement d'événement). Ne touche ni à
  /// la radio ni au coffre : l'appelant s'en charge.
  void leaveAll() {
    stopTimers();
    for (final channel in _channels.values) {
      channel.dispose();
    }
    _channels.clear();
    _records.clear();
    _heard.clear();
    _watchedSince.clear();
    _silent.clear();
    _checkIns.clear();
    _lastOwnCheckIn.clear();
    host.session.state.buddies.clear();
  }

  Future<void> leave(String buddyId) async {
    final channel = _channels.remove(buddyId);
    final record = _records.remove(buddyId);
    if (channel == null || record == null) return;
    channel.dispose();
    final state = host.session.state;
    state.buddies.remove(record);
    _heard.removeWhere((k, _) => k.startsWith('$buddyId/'));
    _watchedSince.removeWhere((k, _) => k.startsWith('$buddyId/'));
    _silent.removeWhere((k) => k.startsWith('$buddyId/'));
    // Le dernier binôme quitté, sans groupe, termine l'événement : le secret et
    // la clé du canal des medics ne restent pas dans le coffre.
    host.endEventIfUnused();
    host.saveVault(removal: true);
    host.refreshChannels();
    await host.syncTransport();
    host.changed();
  }

  BuddyRecord _newRecord({
    required Uint8List id,
    required Uint8List tagKey,
    required String ownName,
  }) {
    final pair = host.crypto.newSigningKeyPair();
    final secret = pair.secretKey.extractBytes();
    pair.secretKey.dispose();
    final now = host.now();
    return BuddyRecord(
      id: id,
      tagKey: Uint8List.fromList(tagKey),
      ownName: ownName,
      signPublic: pair.publicKey,
      signSecret: secret,
      sendChainKey: host.crypto.randomBytes(32),
      sendIndex: 0,
      members: [],
      createdAt: now,
      lastActivity: now,
    );
  }

  Future<void> _store(BuddyRecord record) async {
    host.session.state.buddies.add(record);
    final channel = BuddyChannel(host.crypto, record);
    _channels[channel.id] = channel;
    _records[channel.id] = record;
    final now = host.now();
    for (final member in record.members) {
      _watchedSince[_key(channel.id, member.signPublic)] = now;
    }
    host.saveVault();
    host.refreshChannels();
    await host.syncTransport();
    host.changed();
  }

  // Messages

  /// Traite un message reçu sur un canal de binôme. Faux s'il ne vient pas d'un
  /// de nos binômes.
  bool handle(ReceivedMessage message) {
    final record = _records[message.channelId];
    if (record == null) return false;
    final now = host.now();
    _heard[_key(message.channelId, message.senderKey)] = now;
    record.lastActivity = now;
    if (message.type == MessageType.roster) _readRoster(message.channelId, record, message.body);
    host.saveVault(); // la chaîne de clés a avancé
    _evaluate();
    host.changed();
    return true;
  }

  Future<void> checkIn(String buddyId, {int status = 0}) async {
    final channel = _channels[buddyId];
    final record = _records[buddyId];
    if (channel == null || record == null || record.members.isEmpty) return;
    host.node.sendOn(
      channel,
      type: MessageType.checkIn,
      body: Uint8List.fromList([status]),
      senderName: record.ownName,
    );
    final now = host.now();
    _lastOwnCheckIn[buddyId] = now;
    record.lastActivity = now;
    host.saveVault();
    final count = (_checkIns[buddyId] ?? 0) + 1;
    _checkIns[buddyId] = count;
    // Un check-in sur trois repasse la liste des proches, pour que ceux qui
    // l'ont manquée la rattrapent.
    if (count % 3 == 0) sendRoster(buddyId);
    host.changed();
  }

  void sendRosterToAll() {
    for (final id in _records.keys.toList()) {
      sendRoster(id);
    }
  }

  /// La liste des proches, suivie de la clé publique du canal des medics si on la
  /// connaît : les binômes se la passent entre eux, sans avoir à rescanner.
  void sendRoster(String buddyId) {
    final channel = _channels[buddyId];
    final record = _records[buddyId];
    if (channel == null || record == null || record.members.isEmpty) return;
    final body = BytesBuilder(copy: false)..addByte(record.members.length);
    for (final member in record.members) {
      final name = utf8.encode(member.name);
      body
        ..addByte(name.length)
        ..add(name)
        ..add(member.signPublic)
        ..add(member.chainKey)
        ..add((ByteData(4)..setUint32(0, member.nextIndex)).buffer.asUint8List());
    }
    host.node.sendOn(
      channel,
      type: MessageType.roster,
      body: body.toBytes(),
      senderName: record.ownName,
    );
    // La clé du canal des medics part dans un message à part (zéro proche, puis
    // la clé) : la liste de trois proches aux pseudos longs remplit déjà le
    // message.
    final medicKey = host.session.state.medicPublicKey;
    if (medicKey != null) {
      host.node.sendOn(
        channel,
        type: MessageType.roster,
        body: (BytesBuilder(copy: false)
              ..addByte(0)
              ..add(medicKey))
            .toBytes(),
        senderName: record.ownName,
      );
    }
    host.saveVault();
  }

  void _readRoster(String buddyId, BuddyRecord record, Uint8List body) {
    if (body.isEmpty) return;
    final view = ByteData.sublistView(body);
    var offset = 1;
    for (var i = 0; i < body[0]; i++) {
      if (offset >= body.length) return;
      final nameLength = body[offset++];
      if (offset + nameLength + 32 + 32 + 4 > body.length) return;
      final String name;
      try {
        name = cleanName(utf8.decode(body.sublist(offset, offset + nameLength)));
      } on FormatException {
        return;
      }
      offset += nameLength;
      final signPublic = Uint8List.fromList(body.sublist(offset, offset + 32));
      offset += 32;
      final chainKey = Uint8List.fromList(body.sublist(offset, offset + 32));
      offset += 32;
      final nextIndex = view.getUint32(offset);
      offset += 4;

      if (_sameBytes(signPublic, record.signPublic)) continue; // c'est nous
      if (record.members.any((m) => _sameBytes(m.signPublic, signPublic))) continue;
      if (record.isFull) continue;
      record.members.add(
        BuddyMemberRecord(
          name: name,
          signPublic: signPublic,
          chainKey: chainKey,
          nextIndex: nextIndex,
        ),
      );
      _watchedSince[_key(buddyId, signPublic)] = host.now();
    }
    if (body.length - offset == 32) {
      host.learnMedicKey(Uint8List.fromList(body.sublist(offset)));
    }
  }

  // Présence

  List<BuddyInfo> get infos {
    final now = host.now();
    return [
      for (final entry in _records.entries)
        BuddyInfo(
          id: entry.key,
          ownName: entry.value.ownName,
          lastCheckIn: _lastOwnCheckIn[entry.key],
          others: [
            for (final member in entry.value.members)
              BuddyPerson(
                name: member.name,
                keyTag: _tag(member.signPublic),
                lastHeard: _heard[_key(entry.key, member.signPublic)],
                silent: _isSilent(entry.key, member, now),
              ),
          ],
        ),
    ];
  }

  Duration get _silenceAfter => host.session.state.checkInEvery * 2 + silenceTolerance;

  bool _isSilent(String buddyId, BuddyMemberRecord member, DateTime now) {
    // Si notre propre radio est coupée (Bluetooth éteint), le silence ne dit
    // rien sur les autres.
    if (!host.transportRunning) return false;
    final key = _key(buddyId, member.signPublic);
    var since = _heard[key] ?? _watchedSince[key] ?? now;
    final radio = _radioSince;
    if (radio != null && radio.isAfter(since)) since = radio;
    return now.difference(since) > _silenceAfter;
  }

  /// Compare l'heure du dernier signe de vie de chacun au délai toléré, et
  /// prévient une fois quand quelqu'un se tait, une fois quand il revient.
  void _evaluate() {
    final now = host.now();
    for (final entry in _records.entries) {
      for (final member in entry.value.members) {
        final key = _key(entry.key, member.signPublic);
        final silent = _isSilent(entry.key, member, now);
        if (silent && _silent.add(key)) {
          _alerts.add(BuddyAlert(buddyId: entry.key, name: member.name, silent: true));
          host.changed();
        } else if (!silent && _silent.remove(key)) {
          _alerts.add(BuddyAlert(buddyId: entry.key, name: member.name, silent: false));
          host.changed();
        }
      }
    }
  }

  // Minuteurs

  /// À appeler quand la radio tourne : check-in régulier, surveillance du silence.
  void startTimers() {
    stopTimers();
    if (_records.isEmpty) return;
    final every = host.session.state.checkInEvery;
    _checkInTimer = Timer.periodic(every, (_) => _checkInAll());
    _watchTimer = Timer.periodic(watchEvery, (_) => _evaluate());
    // Un premier signe de vie tout de suite, pour que les proches sachent qu'on est là.
    _firstCheckIn = Timer(firstCheckInDelay, _checkInAll);
  }

  void stopTimers() {
    _checkInTimer?.cancel();
    _watchTimer?.cancel();
    _firstCheckIn?.cancel();
    _checkInTimer = null;
    _watchTimer = null;
    _firstCheckIn = null;
  }

  void _checkInAll() {
    if (!host.transportRunning) return;
    for (final id in _records.keys.toList()) {
      unawaited(checkIn(id).then((_) {}, onError: (_) {}));
    }
  }

  // Outils

  String _key(String buddyId, Uint8List signPublic) => '$buddyId/${_hex(signPublic)}';

  String _idOf(BuddyRecord record) => 'buddy:${_hex(record.id)}';

  String _idFromBytes(Uint8List id) => 'buddy:${_hex(id)}';

  String _tag(Uint8List key) => _hex(key.sublist(0, 3));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
