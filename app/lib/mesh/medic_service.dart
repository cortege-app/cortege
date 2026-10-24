import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../vault/eraser.dart';
import 'channels.dart';
import 'compass.dart';
import 'geo.dart';
import 'medic_invite.dart';
import 'mesh_errors.dart';
import 'mesh_host.dart';
import 'mesh_node.dart';
import 'names.dart';
import 'torch.dart';

enum AlertKind {
  injury(1, 'Blessure'),
  faint(2, 'Malaise'),
  gas(3, 'Gaz');

  const AlertKind(this.code, this.label);

  final int code;
  final String label;

  static AlertKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// Une alerte reçue par un medic. La position est floue (grille de 200 m) et ne
/// vit qu'en mémoire.
class MedicAlert {
  MedicAlert({
    required this.id,
    required this.kind,
    required this.coarse,
    required this.receivedAt,
    required this.replyPublicKey,
  });

  final String id;
  final AlertKind kind;
  final GeoPoint? coarse;
  final DateTime receivedAt;
  final Uint8List replyPublicKey;
  bool answered = false;

  /// Position précise, si la personne a décidé de la partager avec nous.
  GeoPoint? precise;
}

/// Un medic qui a répondu à notre alerte.
class AlertResponder {
  AlertResponder({required this.name, required this.replyPublicKey, required this.receivedAt});

  final String name;
  final Uint8List replyPublicKey;
  final DateTime receivedAt;
  bool positionShared = false;
}

/// Une alerte qu'on a lancée.
class SentAlert {
  SentAlert({
    required this.id,
    required this.kind,
    required this.sentAt,
    required this.hadPosition,
  });

  final String id;
  final AlertKind kind;
  final DateTime sentAt;
  final bool hadPosition;
  final responders = <AlertResponder>[];
}

enum MedicEventType { incoming, reply, position }

class MedicEvent {
  const MedicEvent(this.type, this.alertId);

  final MedicEventType type;
  final String alertId;
}

class _SentRuntime {
  _SentRuntime(this.alert, this.reportId, this.readChannel, this.body);

  final SentAlert alert;
  final Uint8List reportId;
  final SealedChannel readChannel;

  /// Le contenu de l'alerte, pour la rejouer tant que personne n'a répondu.
  final Uint8List body;
  final repeaters = <_Repeater>[];

  void stopRepeating() {
    for (final repeater in repeaters) {
      repeater.cancel();
    }
    repeaters.clear();
  }
}

class _AnswerRuntime {
  _AnswerRuntime(this.alert, this.reportId, this.readChannel);

  final MedicAlert alert;
  final Uint8List reportId;
  final SealedChannel readChannel;
  _Repeater? repeater;
}

/// Rejoue un envoi à intervalles qui s'allongent. Le maillage n'a ni stockage ni
/// accusé de réception : un envoi fait au moment où le voisin est hors de portée
/// est perdu. Pour une alerte, une réponse ou une position, on le rejoue donc
/// quelques fois. [send] rend faux pour arrêter.
class _Repeater {
  _Repeater(this.delays, this.send, {this.repeatLast = false});

  final List<Duration> delays;
  final bool Function() send;

  /// Continue indéfiniment au dernier intervalle (jusqu'à ce que [send] dise stop).
  final bool repeatLast;
  Timer? _timer;
  var _step = 0;

  void start() => _next();

  void _next() {
    if (delays.isEmpty || (_step >= delays.length && !repeatLast)) return;
    final delay = delays[_step < delays.length ? _step : delays.length - 1];
    _step++;
    _timer = Timer(delay, () {
      if (send()) _next();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Le canal des medics et les alertes de blessés.
///
/// - Tout le monde connaît la clé publique du canal (elle voyage dans les
///   invitations) et peut y écrire une alerte. Seuls les medics ont la clé
///   secrète, donc seuls eux lisent.
/// - L'alerte porte une position floue et une clé de réponse à usage unique.
/// - Un medic qui répond le dit à la personne, avec sa propre clé de réponse.
///   La personne décide alors si elle lui envoie sa position précise.
/// - Rien de tout cela n'est écrit sur disque : les alertes et les positions
///   disparaissent au verrouillage complet.
class MedicService {
  MedicService(
    this.host, {
    this.location = const NoLocation(),
    this.compass = const NoCompass(),
    this.torch = const NoTorch(),
    this.resendDelays = defaultResendDelays,
    this.locationWait = const Duration(seconds: 8),
  });

  final MeshHost host;
  LocationProvider location;
  CompassProvider compass;

  /// La lampe, pour se faire repérer à vue.
  final Torch torch;

  /// Intervalles successifs des renvois (alerte, réponse, position).
  final List<Duration> resendDelays;

  /// Combien de temps on attend la position avant de lancer l'alerte sans elle :
  /// un blessé ne doit pas attendre qu'un GPS accroche, ni qu'une demande
  /// d'autorisation reçoive sa réponse.
  final Duration locationWait;

  static const defaultResendDelays = [
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 32),
    Duration(seconds: 60),
  ];

  /// Une alerte sans réponse est rejouée au plus ce temps.
  static const _alertRepeatLimit = Duration(minutes: 30);

  static const alertLifetime = Duration(hours: 2);
  static const _minDelayBetweenReports = Duration(seconds: 15);
  static const _alertVersion = 1;

  SealedChannel? _medicChannel;
  final _received = <String, MedicAlert>{};
  final _sent = <String, _SentRuntime>{};
  final _answers = <String, _AnswerRuntime>{};
  final _events = StreamController<MedicEvent>.broadcast(sync: true);
  DateTime? _lastReport;

  Stream<MedicEvent> get events => _events.stream;

  /// Vrai si ce téléphone connaît le canal des medics de l'événement.
  bool get hasChannel => host.session.state.medicPublicKey != null;

  bool get isMedic => host.session.state.medicActive && host.session.state.medicSecretKey != null;

  bool get canInviteMedics => host.session.state.medicSecretKey != null;

  Iterable<FrameChannel> get channels => [
        ?_medicChannel,
        for (final r in _sent.values) r.readChannel,
        for (final r in _answers.values) r.readChannel,
      ];

  List<MedicAlert> get alertsForMedic {
    _expire();
    return _received.values.toList()..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }

  List<SentAlert> get sentAlerts {
    _expire();
    return _sent.values.map((r) => r.alert).toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
  }

  /// À rappeler dès que les clés du canal changent.
  void rebuild() {
    _medicChannel?.dispose();
    _medicChannel = null;
    final state = host.session.state;
    final publicKey = state.medicPublicKey;
    if (publicKey != null) {
      _medicChannel = SealedChannel(
        host.crypto,
        publicKey: publicKey,
        secretKey: state.medicActive ? state.medicSecretKey : null,
      );
    }
  }

  void dispose() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _medicChannel?.dispose();
    _medicChannel = null;
    for (final r in _sent.values) {
      r.stopRepeating();
      r.readChannel.dispose();
    }
    for (final r in _answers.values) {
      r.repeater?.cancel();
      r.readChannel.dispose();
    }
    _sent.clear();
    _answers.clear();
    _received.clear();
    unawaited(_events.close());
  }

  // Rôle medic

  /// Crée le canal des medics de l'événement et rend ce téléphone medic.
  Future<MedicInvite> createChannel() async {
    final state = host.session.state;
    final pair = host.crypto.newBoxKeyPair();
    final secret = pair.secretKey.extractBytes();
    pair.secretKey.dispose();
    state.eventSecret ??= host.crypto.randomBytes(32);
    state.medicPublicKey = pair.publicKey;
    state.medicSecretKey = secret;
    state.medicActive = true;
    await _keysChanged();
    return invite()!;
  }

  /// Rejoint le canal des medics d'un autre medic (QR).
  Future<void> join(MedicInvite invite) async {
    final state = host.session.state;
    final current = state.eventSecret;
    if (current != null && !_same(current, invite.eventSecret)) throw DifferentEventException();
    state.eventSecret ??= invite.eventSecret;
    state.medicPublicKey = Uint8List.fromList(invite.publicKey);
    state.medicSecretKey = Uint8List.fromList(invite.secretKey);
    state.medicActive = true;
    await _keysChanged();
  }

  /// Le QR à remettre à un autre medic. Null si on n'a pas la clé secrète.
  MedicInvite? invite() {
    final state = host.session.state;
    final secret = state.medicSecretKey;
    final publicKey = state.medicPublicKey;
    final event = state.eventSecret;
    if (secret == null || publicKey == null || event == null) return null;
    return MedicInvite(eventSecret: event, publicKey: publicKey, secretKey: secret);
  }

  Future<void> setActive(bool active) async {
    final state = host.session.state;
    if (active && state.medicSecretKey == null) return;
    state.medicActive = active;
    await _keysChanged();
  }

  /// Oublie les alertes en mémoire (reçues, lancées, réponses) et leurs renvois.
  void forgetAlerts() {
    if (_beaconAlertId != null) unawaited(stopBeacon());
    for (final r in _sent.values) {
      r.stopRepeating();
      r.readChannel.dispose();
    }
    for (final r in _answers.values) {
      r.repeater?.cancel();
      r.readChannel.dispose();
    }
    _sent.clear();
    _answers.clear();
    _received.clear();
  }

  /// Oublie le canal des medics (clé publique et secrète).
  Future<void> leave() async {
    final state = host.session.state;
    state.medicPublicKey = null;
    state.medicSecretKey = null;
    state.medicActive = false;
    _received.clear();
    final hadOthers = state.groups.isNotEmpty || state.buddies.isNotEmpty;
    if (!hadOthers) endEvent(state);
    await _keysChanged();
  }

  /// La clé publique du canal est arrivée dans une invitation de groupe ou de
  /// binôme : on la retient pour pouvoir envoyer des alertes.
  void learnPublicKey(Uint8List? publicKey) {
    if (publicKey == null) return;
    final state = host.session.state;
    if (state.medicPublicKey != null) return;
    state.medicPublicKey = Uint8List.fromList(publicKey);
    _touch();
    rebuild();
    host.refreshChannels();
    host.saveVault();
    host.medicKeyChanged();
    host.changed();
  }

  void _touch() => host.session.state.medicActivity = host.now();

  Future<void> _keysChanged() async {
    _touch();
    rebuild();
    host.refreshChannels();
    host.saveVault();
    await host.syncTransport();
    host.medicKeyChanged();
    host.changed();
  }

  // Signaler un blessé

  /// Lance une alerte vers les medics. Lève [NoMedicChannelException] si ce
  /// téléphone ne connaît pas le canal des medics.
  Future<SentAlert> report(AlertKind kind) async {
    final publicKey = host.session.state.medicPublicKey;
    final channel = _medicChannel;
    if (publicKey == null || channel == null) throw NoMedicChannelException();

    final now = host.now();
    final last = _lastReport;
    if (last != null && _sent.isNotEmpty && now.difference(last) < _minDelayBetweenReports) {
      // Un double appui ne lance pas deux alertes.
      return _sent.values.last.alert;
    }
    _lastReport = now;
    _touch();

    final point = await location.current().timeout(locationWait, onTimeout: () => null);
    final coarse = point == null ? null : coarsened(point);
    final reportId = host.crypto.randomBytes(8);
    final replyPair = host.crypto.newBoxKeyPair();
    final replySecret = replyPair.secretKey.extractBytes();
    replyPair.secretKey.dispose();
    final readChannel = SealedChannel(
      host.crypto,
      publicKey: replyPair.publicKey,
      secretKey: replySecret,
    );
    replySecret.fillRange(0, replySecret.length, 0);

    final body = _encodeAlert(kind, coarse, replyPair.publicKey, reportId);
    host.node.sendOn(channel, type: MessageType.alert, body: body);

    final alert = SentAlert(
      id: _hex(reportId),
      kind: kind,
      sentAt: host.now(),
      hadPosition: coarse != null,
    );
    final runtime = _SentRuntime(alert, reportId, readChannel, body);
    _sent[alert.id] = runtime;
    runtime.repeaters.add(
      _Repeater(resendDelays, () => _resendAlert(runtime), repeatLast: true)..start(),
    );
    host.refreshChannels();
    host.changed();
    return alert;
  }

  /// Rejoue l'alerte tant qu'aucun medic n'a répondu. Faux : on arrête.
  bool _resendAlert(_SentRuntime runtime) {
    if (!identical(_sent[runtime.alert.id], runtime)) return false;
    if (runtime.alert.responders.isNotEmpty) return false;
    if (host.now().difference(runtime.alert.sentAt) > _alertRepeatLimit) return false;
    final channel = _medicChannel;
    if (channel == null) return false;
    host.node.sendOn(channel, type: MessageType.alert, body: runtime.body);
    return true;
  }

  // Se faire trouver : la balise Bluetooth

  static const beaconBytes = 5;
  static const _beaconMax = Duration(minutes: 30);
  String? _beaconAlertId;
  Timer? _beaconTimer;

  /// Vrai tant que ce téléphone annonce sa balise.
  bool get beaconOn => _beaconAlertId != null;

  /// La balise d'une alerte : dérivée de sa clé de réponse, que seuls la
  /// personne et les medics qui ont reçu l'alerte connaissent. Pour un autre,
  /// c'est cinq octets au hasard.
  Uint8List beaconIdFor(Uint8List replyPublicKey) => host.crypto.hash(
        Uint8List.fromList([...utf8.encode('cortege/beacon/1'), ...replyPublicKey]),
        beaconBytes,
      );

  /// La personne qui a lancé [alertId] annonce sa balise : un medic qui la
  /// cherche en mesure la force pour savoir s'il se rapproche. S'arrête toute
  /// seule au bout de 30 minutes.
  Future<void> startBeacon(String alertId) async {
    final runtime = _sent[alertId];
    if (runtime == null) return;
    _beaconAlertId = alertId;
    _beaconTimer?.cancel();
    _beaconTimer = Timer(_beaconMax, () => unawaited(stopBeacon()));
    final onTheAir = await host.setBeacon(beaconIdFor(runtime.readChannel.publicKey));
    if (!onTheAir) {
      // Android a refusé : on ne prétend pas émettre.
      _beaconTimer?.cancel();
      _beaconTimer = null;
      _beaconAlertId = null;
    }
    host.changed();
  }

  Future<void> stopBeacon() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (_beaconAlertId == null) return;
    _beaconAlertId = null;
    await host.setBeacon(null);
    host.changed();
  }

  /// Force du signal (dBm) de la balise de [alert], à chaque fois qu'on
  /// l'entend.
  Stream<int> proximityTo(MedicAlert alert) {
    final wanted = beaconIdFor(alert.replyPublicKey);
    return host.proximity.where((r) => _same(r.beacon, wanted)).map((r) => r.rssi);
  }

  /// Retire une alerte lancée (fausse manœuvre, plus utile).
  void cancel(String alertId) {
    if (_beaconAlertId == alertId) unawaited(stopBeacon());
    final runtime = _sent.remove(alertId);
    if (runtime == null) return;
    runtime.stopRepeating();
    runtime.readChannel.dispose();
    host.refreshChannels();
    host.changed();
  }

  /// Envoie la position précise à un medic qui a répondu. Faux si le téléphone
  /// n'a pas de position à donner.
  Future<bool> sharePosition(String alertId, AlertResponder responder) async {
    final runtime = _sent[alertId];
    if (runtime == null) return false;
    final point = await location.current(accurate: true);
    if (point == null) return false;
    final body = (BytesBuilder(copy: false)
          ..add(runtime.reportId)
          ..add(_int32(point.lat))
          ..add(_int32(point.lon))
          ..add((ByteData(2)..setUint16(0, point.accuracyMeters.clamp(0, 65535).round())).buffer.asUint8List()))
        .toBytes();
    void sendOnce() {
      final channel = SealedChannel(host.crypto, publicKey: responder.replyPublicKey);
      try {
        host.node.sendOn(channel, type: MessageType.alertPosition, body: body);
      } finally {
        channel.dispose();
      }
    }

    sendOnce();
    // Le medic n'accuse pas réception : on rejoue quelques fois, en gardant la
    // position du moment du clic (pas de nouvelle lecture du GPS).
    runtime.repeaters.add(
      _Repeater(resendDelays, () {
        if (!identical(_sent[alertId], runtime)) return false;
        sendOnce();
        return true;
      })..start(),
    );
    responder.positionShared = true;
    host.changed();
    return true;
  }

  // Répondre à une alerte (medic)

  Future<void> respond(String alertId, {required String medicName}) async {
    final alert = _received[alertId];
    if (alert == null || _answers.containsKey(alertId)) return;
    final pair = host.crypto.newBoxKeyPair();
    final secret = pair.secretKey.extractBytes();
    pair.secretKey.dispose();
    final readChannel = SealedChannel(host.crypto, publicKey: pair.publicKey, secretKey: secret);
    secret.fillRange(0, secret.length, 0);
    final reportId = _unhex(alert.id);

    final name = utf8.encode(medicName.length > MeshNode.maxNameBytes ? medicName.substring(0, MeshNode.maxNameBytes) : medicName);
    final replyBody = (BytesBuilder(copy: false)
          ..add(reportId)
          ..add(pair.publicKey)
          ..addByte(name.length)
          ..add(name))
        .toBytes();
    void sendReply() {
      final toReporter = SealedChannel(host.crypto, publicKey: alert.replyPublicKey);
      try {
        host.node.sendOn(toReporter, type: MessageType.alertReply, body: replyBody);
      } finally {
        toReporter.dispose();
      }
    }

    sendReply();
    alert.answered = true;
    final runtime = _AnswerRuntime(alert, reportId, readChannel);
    _answers[alertId] = runtime;
    // Pas d'accusé de réception : on rejoue la réponse jusqu'à ce que la position
    // arrive (preuve que la personne l'a reçue) ou que la série soit finie.
    runtime.repeater = _Repeater(resendDelays, () {
      if (!identical(_answers[alertId], runtime) || alert.precise != null) return false;
      sendReply();
      return true;
    })..start();
    host.refreshChannels();
    host.changed();
  }

  // Réception

  /// Traite un message reçu sur un canal des medics. Faux s'il ne nous concerne pas.
  bool handle(ReceivedMessage message) {
    final channelId = message.channelId;
    if (_medicChannel != null && channelId == _medicChannel!.id) {
      if (message.type == MessageType.alert && isMedic) _readAlert(message);
      return true;
    }
    for (final runtime in _sent.values) {
      if (runtime.readChannel.id == channelId) {
        if (message.type == MessageType.alertReply) _readReply(runtime, message);
        return true;
      }
    }
    for (final runtime in _answers.values) {
      if (runtime.readChannel.id == channelId) {
        if (message.type == MessageType.alertPosition) _readPosition(runtime, message);
        return true;
      }
    }
    return false;
  }

  void _readAlert(ReceivedMessage message) {
    // Une vieille alerte rejouée par quelqu'un ne doit pas ressusciter.
    if (host.now().difference(message.sentAt) > alertLifetime) return;
    final body = message.body;
    if (body.length != 1 + 1 + 4 + 4 + 2 + 32 + 8 || body[0] != _alertVersion) return;
    final kind = AlertKind.fromCode(body[1]);
    if (kind == null) return;
    final view = ByteData.sublistView(body);
    final lat = view.getInt32(2);
    final lon = view.getInt32(6);
    final id = _hex(body.sublist(44, 52));
    if (_received.containsKey(id)) return;
    _received[id] = MedicAlert(
      id: id,
      kind: kind,
      coarse: lat == _unknown ? null : GeoPoint(lat / 1e6, lon / 1e6, view.getUint16(10).toDouble()),
      receivedAt: host.now(),
      replyPublicKey: Uint8List.fromList(body.sublist(12, 44)),
    );
    _touch();
    host.saveVault();
    _events.add(MedicEvent(MedicEventType.incoming, id));
    host.changed();
  }

  void _readReply(_SentRuntime runtime, ReceivedMessage message) {
    final body = message.body;
    if (body.length < 8 + 32 + 1) return;
    if (!_same(Uint8List.sublistView(body, 0, 8), runtime.reportId)) return;
    final nameLength = body[40];
    if (body.length != 41 + nameLength) return;
    final String name;
    try {
      name = cleanName(utf8.decode(body.sublist(41)));
    } on FormatException {
      return;
    }
    final key = Uint8List.fromList(body.sublist(8, 40));
    if (runtime.alert.responders.any((r) => _same(r.replyPublicKey, key))) return;
    runtime.alert.responders.add(
      AlertResponder(name: name, replyPublicKey: key, receivedAt: host.now()),
    );
    _events.add(MedicEvent(MedicEventType.reply, runtime.alert.id));
    host.changed();
  }

  void _readPosition(_AnswerRuntime runtime, ReceivedMessage message) {
    final body = message.body;
    if (body.length != 8 + 4 + 4 + 2) return;
    if (!_same(Uint8List.sublistView(body, 0, 8), runtime.reportId)) return;
    final view = ByteData.sublistView(body);
    final point = GeoPoint(
      view.getInt32(8) / 1e6,
      view.getInt32(12) / 1e6,
      view.getUint16(16).toDouble(),
    );
    // La personne rejoue sa position : on ne prévient qu'à la première fois.
    final known = runtime.alert.precise;
    if (known != null && known.lat == point.lat && known.lon == point.lon) return;
    runtime.alert.precise = point;
    _events.add(MedicEvent(MedicEventType.position, runtime.alert.id));
    host.changed();
  }

  // Outils

  static const _unknown = 0x7fffffff;

  Uint8List _encodeAlert(AlertKind kind, GeoPoint? point, Uint8List replyKey, Uint8List reportId) {
    final body = BytesBuilder(copy: false)
      ..addByte(_alertVersion)
      ..addByte(kind.code)
      ..add(point == null ? _int32Raw(_unknown) : _int32(point.lat))
      ..add(point == null ? _int32Raw(_unknown) : _int32(point.lon))
      ..add((ByteData(2)..setUint16(0, point?.accuracyMeters.round() ?? 0)).buffer.asUint8List())
      ..add(replyKey)
      ..add(reportId);
    return body.toBytes();
  }

  Uint8List _int32(double degrees) => _int32Raw((degrees * 1e6).round());

  Uint8List _int32Raw(int value) => (ByteData(4)..setInt32(0, value)).buffer.asUint8List();

  void _expire() {
    final now = host.now();
    _received.removeWhere((_, a) => now.difference(a.receivedAt) > alertLifetime);
    final oldSent = _sent.entries
        .where((e) => now.difference(e.value.alert.sentAt) > alertLifetime)
        .map((e) => e.key)
        .toList();
    for (final id in oldSent) {
      final runtime = _sent.remove(id);
      runtime?.stopRepeating();
      runtime?.readChannel.dispose();
    }
    final oldAnswers = _answers.entries
        .where((e) => now.difference(e.value.alert.receivedAt) > alertLifetime)
        .map((e) => e.key)
        .toList();
    for (final id in oldAnswers) {
      final runtime = _answers.remove(id);
      runtime?.repeater?.cancel();
      runtime?.readChannel.dispose();
    }
    if (oldSent.isNotEmpty || oldAnswers.isNotEmpty) host.refreshChannels();
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
