import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'channels.dart';
import 'frame.dart';
import 'group.dart';
import 'mesh_crypto.dart';
import 'names.dart';

/// Un voisin joignable. Les trames arrivent par [MeshNode.onFrame], pas ici :
/// en Bluetooth, la connexion par laquelle on envoie n'est pas celle par
/// laquelle on reçoit.
abstract class MeshLink {
  String get id;

  /// Envoie une trame complète (sans préfixe de longueur) à ce voisin.
  Future<void> send(Uint8List frame);
}

/// Les types de messages qui circulent dans les trames.
class MessageType {
  static const chat = 1;
  static const checkIn = 2;

  /// Liste des autres personnes d'un binôme, pour que les nouveaux venus
  /// connaissent tout le monde sans scanner chacun.
  static const roster = 3;

  static const alert = 10;
  static const alertReply = 11;
  static const alertPosition = 12;
}

class ReceivedMessage {
  const ReceivedMessage({
    required this.id,
    required this.groupId,
    required this.senderName,
    required this.senderKey,
    required this.text,
    required this.sentAt,
    required this.mine,
    this.type = MessageType.chat,
    Uint8List? body,
  }) : _body = body;

  /// Empreinte de la trame, identique chez tous les récepteurs. Sert à ne
  /// jamais afficher deux fois le même message.
  final String id;

  /// Identifiant du canal (groupe, binôme...) par lequel le message est arrivé.
  final String groupId;
  final String senderName;
  final Uint8List senderKey;

  /// Le texte, pour un message de discussion. Vide pour les autres types.
  final String text;
  final DateTime sentAt;
  final bool mine;
  final int type;
  final Uint8List? _body;

  String get channelId => groupId;

  Uint8List get body => _body ?? Uint8List.fromList(utf8.encode(text));

  /// Quatre octets de la clé de l'expéditeur, pour distinguer deux membres
  /// qui ont choisi le même pseudo.
  String get senderTag => senderKey
      .sublist(0, 3)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

class MeshStats {
  int received = 0;
  int malformed = 0;
  int duplicates = 0;
  int rateLimited = 0;
  int rejected = 0;
  int delivered = 0;
  int relayed = 0;
  int sent = 0;
}

/// Le moteur du maillage : reçoit des trames, déchiffre celles de nos canaux
/// (groupes, binômes, canal des medics), rediffuse toutes les autres
/// (inondation contrôlée).
///
/// - Chaque trame est reconnue par une empreinte de son contenu chiffré ; une
///   trame déjà vue est ignorée, ce qui casse les boucles.
/// - Le TTL est plafonné à la réception.
/// - Une trame de l'un de nos canaux qui échoue au déchiffrement ou à la
///   vérification de signature n'est jamais rediffusée.
/// - Un voisin qui envoie trop de trames est ignoré le temps de la fenêtre.
/// - Les trames d'autres canaux sont rediffusées sans être lues : les relais
///   n'ont pas besoin d'être dans le groupe.
class MeshNode {
  MeshNode({
    required this.crypto,
    DateTime Function()? now,
    this.defaultTtl = 7,
    this.maxTtl = 7,
    this.maxMessageAge = const Duration(hours: 24),
    this.maxClockAhead = const Duration(minutes: 10),
    this.maxFramesPerWindow = 60,
    this.rateWindow = const Duration(seconds: 10),
    this.seenLifetime = const Duration(hours: 1),
    this.seenCapacity = 4096,
    this.relayDelay,
  }) : _now = now ?? DateTime.now;

  static const maxBodyBytes = 300;
  static const maxNameBytes = 24;
  static const _tagEpoch = Duration(hours: 1);

  final MeshCrypto crypto;
  final DateTime Function() _now;
  final int defaultTtl;
  final int maxTtl;

  /// Les messages plus vieux que ça sont refusés (la durée d'effacement des
  /// réglages s'y applique aussi).
  Duration maxMessageAge;
  final Duration maxClockAhead;
  final int maxFramesPerWindow;
  final Duration rateWindow;
  final Duration seenLifetime;
  final int seenCapacity;

  /// Délai aléatoire avant chaque rediffusion, pour que des voisins n'émettent
  /// pas tous au même instant. Null : immédiat (tests).
  final Duration Function()? relayDelay;

  final stats = MeshStats();

  final _links = <String, MeshLink>{};
  final _groupChannels = <String, GroupChannel>{};
  var _extraChannels = <FrameChannel>[];
  final _seen = <String, DateTime>{}; // l'ordre d'insertion sert à purger
  final _arrivals = <String, List<DateTime>>{};
  // Livraison immédiate : un message est remis au moment où la trame est lue,
  // pas au prochain tour de la boucle d'événements.
  final _messages = StreamController<ReceivedMessage>.broadcast(sync: true);
  Map<String, FrameChannel>? _tagIndex;
  int? _tagIndexEpoch;

  Stream<ReceivedMessage> get messages => _messages.stream;

  Iterable<MeshLink> get links => _links.values;

  void addLink(MeshLink link) => _links[link.id] = link;

  void removeLink(String id) => _links.remove(id);

  /// La radio s'est arrêtée : les liens qu'elle avait ouverts ne servent plus.
  void clearLinks() => _links.clear();

  void setGroups(Iterable<MeshGroup> groups) {
    _groupChannels
      ..clear()
      ..addEntries(groups.map((g) => MapEntry(g.id, GroupChannel(crypto, g))));
    _tagIndex = null;
  }

  /// Canaux autres que les groupes : binômes, canal des medics, réponses
  /// d'alerte. Le moteur ne les possède pas : celui qui les crée les libère.
  void setChannels(Iterable<FrameChannel> channels) {
    _extraChannels = List.of(channels);
    _tagIndex = null;
  }

  Future<void> close() => _messages.close();

  /// Écrit un message de discussion dans [group] et le lance dans le maillage.
  ReceivedMessage send(
    MeshGroup group, {
    required String senderName,
    required String text,
  }) {
    final channel = _groupChannels[group.id];
    if (channel == null) throw StateError('groupe inconnu du maillage');
    return sendOn(
      channel,
      type: MessageType.chat,
      body: Uint8List.fromList(utf8.encode(text)),
      senderName: senderName,
    );
  }

  /// Écrit un message d'un [type] donné sur [channel] et le lance dans le
  /// maillage.
  ReceivedMessage sendOn(
    FrameChannel channel, {
    required int type,
    required Uint8List body,
    String senderName = '',
    int? ttl,
  }) {
    final name = utf8.encode(senderName);
    if (!channel.canSend) throw StateError('canal en lecture seule');
    if (body.isEmpty || body.length > maxBodyBytes) {
      throw ArgumentError('message de 1 à $maxBodyBytes octets attendu');
    }
    if (name.length > maxNameBytes) {
      throw ArgumentError('pseudo de $maxNameBytes octets au plus');
    }
    final now = _now();
    final tag = channel.tagFor(_epochOf(now));
    final identity = channel.identity();

    try {
      final prefix = BytesBuilder(copy: false)
        ..addByte(type)
        ..add((ByteData(4)..setUint32(0, now.millisecondsSinceEpoch ~/ 1000)).buffer.asUint8List())
        ..add(identity.signPublic)
        ..addByte(name.length)
        ..add(name)
        ..add((ByteData(2)..setUint16(0, body.length)).buffer.asUint8List())
        ..add(body);
      final prefixBytes = prefix.toBytes();
      final signature = crypto.sign(_signedData(tag, prefixBytes), identity.signSecret);
      final plain = crypto.pad(
        (BytesBuilder(copy: false)
              ..add(prefixBytes)
              ..add(signature))
            .toBytes(),
      );
      final aad = Uint8List.fromList([Frame.version, ...tag]);
      final frame = Frame(
        ttl: ttl ?? defaultTtl,
        groupTag: tag,
        sealed: channel.seal(plain, aad),
      );
      plain.fillRange(0, plain.length, 0);

      final id = _frameId(frame);
      _remember(id, now);
      final bytes = frame.encode();
      for (final link in _links.values.toList()) {
        _dispatch(link, bytes);
      }
      stats.sent++;
      return ReceivedMessage(
        id: id,
        groupId: channel.id,
        senderName: senderName,
        senderKey: identity.signPublic,
        text: type == MessageType.chat ? utf8.decode(body) : '',
        sentAt: DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch ~/ 1000 * 1000),
        mine: true,
        type: type,
        body: body,
      );
    } finally {
      if (identity.disposeAfterUse) identity.signSecret.dispose();
    }
  }

  /// Une trame est arrivée du voisin [sourceId].
  void onFrame(String sourceId, Uint8List bytes) {
    final now = _now();
    stats.received++;
    if (!_allow(sourceId, now)) {
      stats.rateLimited++;
      return;
    }
    final frame = Frame.parse(
      bytes,
      minSealedLength: crypto.tagBytes + MeshCrypto.padBlock,
    );
    if (frame == null) {
      stats.malformed++;
      return;
    }
    final id = _frameId(frame);
    if (_seen.containsKey(id)) {
      stats.duplicates++;
      return;
    }
    _remember(id, now);

    final channel = _tagIndexFor(now)[_hex(frame.groupTag)];
    if (channel != null && channel.canRead) {
      final message = _open(channel, frame, id, now);
      if (message == null) {
        stats.rejected++;
        return;
      }
      stats.delivered++;
      _messages.add(message);
    }
    _relay(frame);
  }

  ReceivedMessage? _open(FrameChannel channel, Frame frame, String id, DateTime now) {
    final opened = channel.open(frame);
    if (opened == null) return null;
    final inner = crypto.unpad(opened.plain);
    opened.plain.fillRange(0, opened.plain.length, 0);
    if (inner == null) return null;

    final view = ByteData.sublistView(inner);
    var offset = 0;
    bool need(int count) => offset + count <= inner.length;

    if (!need(1 + 4 + MeshCrypto.publicKeyBytes + 1)) return null;
    final type = inner[offset++];
    final seconds = view.getUint32(offset);
    offset += 4;
    final senderKey = Uint8List.fromList(inner.sublist(offset, offset + MeshCrypto.publicKeyBytes));
    offset += MeshCrypto.publicKeyBytes;
    final nameLength = inner[offset++];
    if (nameLength > maxNameBytes || !need(nameLength + 2)) return null;
    final nameBytes = inner.sublist(offset, offset + nameLength);
    offset += nameLength;
    final bodyLength = view.getUint16(offset);
    offset += 2;
    if (bodyLength == 0 || bodyLength > maxBodyBytes) return null;
    if (!need(bodyLength + MeshCrypto.signatureBytes)) return null;
    final bodyBytes = Uint8List.fromList(inner.sublist(offset, offset + bodyLength));
    offset += bodyLength;
    final signature = Uint8List.fromList(inner.sublist(offset, offset + MeshCrypto.signatureBytes));
    final signedPrefix = Uint8List.fromList(inner.sublist(0, offset));

    if (!crypto.verify(_signedData(frame.groupTag, signedPrefix), signature, senderKey)) {
      return null;
    }
    final expected = opened.expectedSigner;
    if (expected != null && !_sameBytes(expected, senderKey)) return null;
    final sentAt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    if (now.difference(sentAt) > maxMessageAge) return null;
    if (sentAt.difference(now) > maxClockAhead) return null;

    final String name;
    try {
      name = cleanName(utf8.decode(nameBytes));
    } on FormatException {
      return null;
    }
    var text = '';
    if (type == MessageType.chat) {
      try {
        text = utf8.decode(bodyBytes);
      } on FormatException {
        return null;
      }
    }
    // Tout est vérifié : seulement maintenant, la chaîne d'un binôme avance.
    opened.commit();
    return ReceivedMessage(
      id: id,
      groupId: channel.id,
      senderName: name,
      senderKey: senderKey,
      text: text,
      sentAt: sentAt,
      mine: channel.isOwnKey(senderKey),
      type: type,
      body: bodyBytes,
    );
  }

  void _relay(Frame frame) {
    final ttl = frame.ttl > maxTtl ? maxTtl : frame.ttl;
    if (ttl <= 1) return;
    final bytes = frame.withTtl(ttl - 1).encode();
    for (final link in _links.values.toList()) {
      _dispatch(link, bytes);
    }
    stats.relayed++;
  }

  void _dispatch(MeshLink link, Uint8List bytes) {
    void go() => unawaited(link.send(bytes).then((_) {}, onError: (_) {}));
    final delay = relayDelay?.call();
    if (delay == null) {
      go();
    } else {
      Timer(delay, go);
    }
  }

  bool _allow(String sourceId, DateTime now) {
    final arrivals = _arrivals.putIfAbsent(sourceId, () => []);
    arrivals.removeWhere((t) => now.difference(t) > rateWindow);
    if (arrivals.length >= maxFramesPerWindow) return false;
    arrivals.add(now);
    return true;
  }

  String _frameId(Frame frame) => _hex(crypto.hash(frame.sealed, 16));

  void _remember(String id, DateTime now) {
    _seen[id] = now;
    while (_seen.length > seenCapacity) {
      _seen.remove(_seen.keys.first);
    }
    if (_seen.isNotEmpty && now.difference(_seen.values.first) > seenLifetime) {
      _seen.removeWhere((_, seenAt) => now.difference(seenAt) > seenLifetime);
    }
  }

  Map<String, FrameChannel> _tagIndexFor(DateTime now) {
    final epoch = _epochOf(now);
    final cached = _tagIndex;
    if (cached != null && _tagIndexEpoch == epoch) return cached;
    final index = <String, FrameChannel>{};
    final channels = <FrameChannel>[..._groupChannels.values, ..._extraChannels];
    for (final channel in channels) {
      for (final e in [epoch - 1, epoch, epoch + 1]) {
        index[_hex(channel.tagFor(e))] = channel;
      }
    }
    _tagIndex = index;
    _tagIndexEpoch = epoch;
    return index;
  }

  int _epochOf(DateTime now) => now.millisecondsSinceEpoch ~/ _tagEpoch.inMilliseconds;

  /// Ce que la signature couvre : le contexte, l'étiquette du canal (une
  /// signature ne peut pas être rejouée dans un autre canal) et le message.
  Uint8List _signedData(Uint8List tag, Uint8List prefix) => (BytesBuilder(copy: false)
        ..add(utf8.encode('cortege/msg/1'))
        ..add(tag)
        ..add(prefix))
      .toBytes();
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
