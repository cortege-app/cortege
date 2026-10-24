import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import '../vault/vault_state.dart';
import 'frame.dart';
import 'group.dart';
import 'mesh_crypto.dart';

/// Ce que [FrameChannel.open] renvoie : le contenu déchiffré, et de quoi
/// valider l'opération une fois la signature vérifiée.
class ChannelOpened {
  ChannelOpened(this.plain, this.commit, {this.expectedSigner});

  /// Contenu en clair, encore rempli (padding).
  final Uint8List plain;

  /// À appeler seulement quand tout est vérifié : c'est là que la chaîne de clés
  /// d'un binôme avance. Une trame falsifiée ne doit jamais la faire avancer.
  final void Function() commit;

  /// Si non null, la signature du message doit venir de cette clé (binôme : la
  /// chaîne déchiffrée appartient à une personne précise).
  final Uint8List? expectedSigner;
}

/// Identité avec laquelle on signe un message envoyé sur un canal.
class ChannelIdentity {
  ChannelIdentity(this.signPublic, this.signSecret, {this.disposeAfterUse = false});

  final Uint8List signPublic;
  final SecureKey signSecret;

  /// Vrai pour une identité jetable créée pour un seul message.
  final bool disposeAfterUse;
}

/// Une façon de reconnaître, déchiffrer et émettre des trames. Le moteur du
/// maillage ne connaît que cette interface : groupe, binôme et canal des medics
/// s'y branchent de la même manière.
abstract class FrameChannel {
  String get id;

  /// Faux pour un canal où l'on ne peut que lire.
  bool get canSend;

  /// Faux quand on connaît le canal mais pas de quoi le déchiffrer (clé
  /// publique du canal des medics sans la clé secrète). Ses trames sont alors
  /// rediffusées comme celles de n'importe quel canal étranger : y toucher
  /// casserait la route de l'alerte.
  bool get canRead;

  /// Étiquette portée par les trames de ce canal pendant l'heure [epoch].
  Uint8List tagFor(int epoch);

  ChannelIdentity identity();

  /// Chiffre un contenu déjà rempli. Renvoie ce qui va dans la trame.
  Uint8List seal(Uint8List padded, Uint8List aad);

  /// Déchiffre une trame qui porte l'étiquette de ce canal, ou renvoie null.
  ChannelOpened? open(Frame frame);

  bool isOwnKey(Uint8List signPublic);

  void dispose();
}

Uint8List _epochBytes(int epoch) => (ByteData(8)..setUint64(0, epoch)).buffer.asUint8List();

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Un groupe : une clé partagée par tous les membres.
class GroupChannel implements FrameChannel {
  GroupChannel(this.crypto, this.group);

  final MeshCrypto crypto;
  final MeshGroup group;

  @override
  String get id => group.id;

  @override
  bool get canSend => true;

  @override
  bool get canRead => true;

  @override
  Uint8List tagFor(int epoch) =>
      crypto.derive(group.tagKey, 'tag-value/1', Frame.tagLength, _epochBytes(epoch));

  @override
  ChannelIdentity identity() => ChannelIdentity(group.signPublic, group.signSecret);

  @override
  Uint8List seal(Uint8List padded, Uint8List aad) => crypto.seal(group.aeadKey, padded, aad);

  @override
  ChannelOpened? open(Frame frame) {
    final plain = crypto.open(group.aeadKey, frame.sealed, frame.associatedData);
    return plain == null ? null : ChannelOpened(plain, () {});
  }

  @override
  bool isOwnKey(Uint8List signPublic) => _same(group.signPublic, signPublic);

  @override
  void dispose() {} // les clés appartiennent au MeshGroup
}

/// Boîte scellée : n'importe qui écrit à [publicKey], seul le détenteur de la clé
/// secrète lit. Sert au canal des medics et aux réponses d'une alerte. L'envoi
/// ne révèle rien sur l'expéditeur : la clé de signature change à chaque message.
class SealedChannel implements FrameChannel {
  SealedChannel(this.crypto, {required this.publicKey, Uint8List? secretKey})
      : _secretKey = secretKey == null ? null : crypto.secure(secretKey),
        _tagKey = crypto.secure(crypto.hash(publicKey, 32));

  final MeshCrypto crypto;
  final Uint8List publicKey;
  final SecureKey? _secretKey;
  final SecureKey _tagKey;

  @override
  bool get canRead => _secretKey != null;

  @override
  String get id => 'sealed:${_hex(crypto.hash(publicKey, 6))}';

  @override
  bool get canSend => true;

  @override
  Uint8List tagFor(int epoch) =>
      crypto.derive(_tagKey, 'sealed-tag/1', Frame.tagLength, _epochBytes(epoch));

  @override
  ChannelIdentity identity() {
    final pair = crypto.newSigningKeyPair();
    return ChannelIdentity(pair.publicKey, pair.secretKey, disposeAfterUse: true);
  }

  @override
  Uint8List seal(Uint8List padded, Uint8List aad) => crypto.boxSeal(padded, publicKey);

  @override
  ChannelOpened? open(Frame frame) {
    final secret = _secretKey;
    if (secret == null) return null;
    final plain = crypto.boxSealOpen(frame.sealed, publicKey, secret);
    return plain == null ? null : ChannelOpened(plain, () {});
  }

  @override
  bool isOwnKey(Uint8List signPublic) => false;

  @override
  void dispose() {
    _secretKey?.dispose();
    _tagKey.dispose();
  }
}

/// Un binôme. Chaque personne a sa propre chaîne de clés : chaque message part
/// avec une clé neuve, tirée de la précédente, et les clés déjà utilisées sont
/// jetées. Quelqu'un qui obtient la chaîne d'aujourd'hui ne peut pas relire les
/// messages d'hier (confidentialité persistante).
///
/// L'état de toutes les chaînes vit dans le [BuddyRecord] et change à chaque
/// message : l'appelant doit enregistrer le coffre après un envoi ou une
/// réception.
class BuddyChannel implements FrameChannel {
  BuddyChannel(this.crypto, this.record)
      : _tagKey = crypto.secure(record.tagKey),
        _signSecret = crypto.secure(record.signSecret);

  final MeshCrypto crypto;
  final BuddyRecord record;
  final SecureKey _tagKey;
  final SecureKey _signSecret;

  /// Combien de messages perdus ou en retard on accepte de sauter d'un coup.
  static const maxSkip = 64;
  static const maxStoredSkipped = 128;

  @override
  String get id => 'buddy:${_hex(record.id)}';

  @override
  bool get canSend => true;

  @override
  bool get canRead => true;

  @override
  Uint8List tagFor(int epoch) =>
      crypto.derive(_tagKey, 'buddy-tag/1', Frame.tagLength, _epochBytes(epoch));

  @override
  ChannelIdentity identity() => ChannelIdentity(record.signPublic, _signSecret);

  /// Saute [steps] numéros de notre chaîne d'envoi. À faire à la réouverture du
  /// coffre : si l'appli a été tuée juste après un envoi, avant que l'écriture
  /// du coffre soit finie, notre chaîne a reculé alors que le proche a déjà
  /// avancé. Sans ce saut, nos prochains messages réutiliseraient des numéros
  /// qu'il a déjà passés et il ne pourrait plus les lire. Il accepte jusqu'à
  /// [maxSkip] numéros sautés.
  void advanceSendChain(int steps) {
    for (var i = 0; i < steps; i++) {
      final old = record.sendChainKey;
      record.sendChainKey = _nextChain(old);
      old.fillRange(0, old.length, 0);
      record.sendIndex++;
    }
  }

  Uint8List _nextChain(Uint8List chainKey) {
    final key = crypto.secure(chainKey);
    try {
      return crypto.derive(key, 'buddy-chain/1', 32);
    } finally {
      key.dispose();
    }
  }

  Uint8List _messageKey(Uint8List chainKey) {
    final key = crypto.secure(chainKey);
    try {
      return crypto.derive(key, 'buddy-message/1', 32);
    } finally {
      key.dispose();
    }
  }

  @override
  Uint8List seal(Uint8List padded, Uint8List aad) {
    final index = record.sendIndex;
    final messageKey = _messageKey(record.sendChainKey);
    final oldChain = record.sendChainKey;
    record.sendChainKey = _nextChain(oldChain);
    oldChain.fillRange(0, oldChain.length, 0);
    record.sendIndex = index + 1;

    final nonce = (BytesBuilder(copy: false)
          ..add((ByteData(4)..setUint32(0, index)).buffer.asUint8List())
          ..add(crypto.randomBytes(crypto.nonceBytes - 4)))
        .toBytes();
    final key = crypto.secure(messageKey);
    messageKey.fillRange(0, messageKey.length, 0);
    try {
      return (BytesBuilder(copy: false)
            ..add(nonce)
            ..add(crypto.sealWithNonce(key, nonce, padded, aad)))
          .toBytes();
    } finally {
      key.dispose();
    }
  }

  @override
  ChannelOpened? open(Frame frame) {
    final sealed = frame.sealed;
    final nonceLength = crypto.nonceBytes;
    if (sealed.length < nonceLength + crypto.tagBytes) return null;
    final nonce = Uint8List.fromList(sealed.sublist(0, nonceLength));
    final cipher = Uint8List.fromList(sealed.sublist(nonceLength));
    final index = ByteData.sublistView(nonce).getUint32(0);

    for (final member in List<BuddyMemberRecord>.of(record.members)) {
      final candidate = _candidate(member, index);
      if (candidate == null) continue;
      final key = crypto.secure(candidate.messageKey);
      final plain = crypto.openWithNonce(key, nonce, cipher, frame.associatedData);
      key.dispose();
      candidate.messageKey.fillRange(0, candidate.messageKey.length, 0);
      if (plain != null) {
        return ChannelOpened(
          plain,
          () => _commit(member, candidate, index),
          expectedSigner: member.signPublic,
        );
      }
    }
    return null;
  }

  /// La clé du message [index] de [member], sans rien modifier : l'état ne
  /// change qu'au [_commit], une fois la trame vérifiée jusqu'au bout.
  _Candidate? _candidate(BuddyMemberRecord member, int index) {
    if (index < member.nextIndex) {
      final stored = member.skipped[index];
      return stored == null ? null : _Candidate(Uint8List.fromList(stored));
    }
    if (index - member.nextIndex > maxSkip) return null;
    var chain = Uint8List.fromList(member.chainKey);
    final skipped = <int, Uint8List>{};
    for (var i = member.nextIndex; i < index; i++) {
      skipped[i] = _messageKey(chain);
      chain = _nextChain(chain);
    }
    final messageKey = _messageKey(chain);
    return _Candidate(messageKey, newChain: _nextChain(chain), newSkipped: skipped);
  }

  void _commit(BuddyMemberRecord member, _Candidate candidate, int index) {
    if (candidate.newChain == null) {
      member.skipped.remove(index)?.fillRange(0, 32, 0);
      return;
    }
    member.chainKey.fillRange(0, member.chainKey.length, 0);
    member.chainKey = candidate.newChain!;
    member.nextIndex = index + 1;
    member.skipped.addAll(candidate.newSkipped);
    while (member.skipped.length > maxStoredSkipped) {
      final oldest = member.skipped.keys.reduce((a, b) => a < b ? a : b);
      member.skipped.remove(oldest)?.fillRange(0, 32, 0);
    }
  }

  @override
  bool isOwnKey(Uint8List signPublic) => _same(record.signPublic, signPublic);

  @override
  void dispose() {
    _tagKey.dispose();
    _signSecret.dispose();
  }
}

class _Candidate {
  _Candidate(this.messageKey, {this.newChain, this.newSkipped = const {}});

  final Uint8List messageKey;
  final Uint8List? newChain;
  final Map<int, Uint8List> newSkipped;
}
