import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import 'mesh_crypto.dart';
import 'names.dart';

/// Ce que le QR d'un groupe transporte. Posséder ce QR, c'est appartenir au
/// groupe : la clé du groupe y est en clair. Le secret d'événement sert à
/// calculer les identifiants Bluetooth (décision 7) : tous les groupes d'un
/// même événement le partagent, c'est ce qui les fait se retrouver.
class GroupInvite {
  GroupInvite({
    required this.name,
    required this.groupKey,
    required this.eventSecret,
    this.medicPublicKey,
  }) {
    if (groupKey.length != 32 || eventSecret.length != 32) {
      throw const FormatException('clés de 32 octets attendues');
    }
    if (medicPublicKey != null && medicPublicKey!.length != 32) {
      throw const FormatException('clé des medics de 32 octets attendue');
    }
    final bytes = utf8.encode(name);
    if (bytes.isEmpty || bytes.length > maxNameBytes) {
      throw const FormatException('nom de groupe vide ou trop long');
    }
  }

  static const prefix = 'CORTEGE1.';
  static const maxNameBytes = 40;
  static const _version = 1;
  static const _versionWithMedic = 2;

  final String name;
  final Uint8List groupKey;
  final Uint8List eventSecret;

  /// Clé publique du canal des medics de l'événement, si l'invitation vient d'un
  /// téléphone qui la connaît. Elle permet à tout le monde d'envoyer une alerte
  /// que seuls les medics peuvent lire.
  final Uint8List? medicPublicKey;

  String encode() {
    final nameBytes = utf8.encode(name);
    final raw = BytesBuilder(copy: false)
      ..addByte(medicPublicKey == null ? _version : _versionWithMedic)
      ..add(eventSecret)
      ..add(groupKey);
    if (medicPublicKey != null) raw.add(medicPublicKey!);
    raw
      ..addByte(nameBytes.length)
      ..add(nameBytes);
    return prefix + base64Url.encode(raw.toBytes()).replaceAll('=', '');
  }

  factory GroupInvite.decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const FormatException('ce QR n\'est pas une invitation Cortège');
    }
    final Uint8List raw;
    try {
      raw = base64Url.decode(base64Url.normalize(trimmed.substring(prefix.length)));
    } on FormatException {
      throw const FormatException('invitation illisible');
    }
    if (raw.isEmpty || (raw[0] != _version && raw[0] != _versionWithMedic)) {
      throw const FormatException('invitation d\'une version inconnue');
    }
    final withMedic = raw[0] == _versionWithMedic;
    final lengthAt = 65 + (withMedic ? 32 : 0);
    if (raw.length < lengthAt + 1) {
      throw const FormatException('invitation tronquée');
    }
    final nameLength = raw[lengthAt];
    if (raw.length != lengthAt + 1 + nameLength) {
      throw const FormatException('invitation tronquée');
    }
    final String name;
    try {
      name = cleanName(utf8.decode(raw.sublist(lengthAt + 1), allowMalformed: false));
    } on FormatException {
      throw const FormatException('nom de groupe illisible');
    }
    return GroupInvite(
      name: name,
      eventSecret: Uint8List.fromList(raw.sublist(1, 33)),
      groupKey: Uint8List.fromList(raw.sublist(33, 65)),
      medicPublicKey: withMedic ? Uint8List.fromList(raw.sublist(65, 97)) : null,
    );
  }
}

/// Un groupe prêt à servir : clés dérivées en mémoire native, plus la paire de
/// clés de signature propre à ce groupe (un membre n'a pas la même identité
/// d'un groupe à l'autre, on ne peut pas les relier).
class MeshGroup {
  MeshGroup._({
    required this.id,
    required this.name,
    required this.groupKey,
    required this.aeadKey,
    required this.tagKey,
    required this.signPublic,
    required this.signSecret,
  });

  factory MeshGroup.create(
    MeshCrypto crypto, {
    required String name,
    required Uint8List groupKey,
    required Uint8List signPublic,
    required Uint8List signSecret,
  }) {
    final master = crypto.secure(groupKey);
    try {
      return MeshGroup._(
        id: _hex(crypto.derive(master, 'group-id/1', 6)),
        name: name,
        groupKey: Uint8List.fromList(groupKey),
        aeadKey: crypto.secure(crypto.derive(master, 'aead/1', 32)),
        tagKey: crypto.secure(crypto.derive(master, 'tag/1', 32)),
        signPublic: Uint8List.fromList(signPublic),
        signSecret: crypto.secure(signSecret),
      );
    } finally {
      master.dispose();
    }
  }

  /// Nouveau groupe créé par ce téléphone ou rejoint par QR.
  factory MeshGroup.fromInvite(MeshCrypto crypto, GroupInvite invite) {
    final pair = crypto.newSigningKeyPair();
    final secret = pair.secretKey.extractBytes();
    try {
      return MeshGroup.create(
        crypto,
        name: invite.name,
        groupKey: invite.groupKey,
        signPublic: pair.publicKey,
        signSecret: secret,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
      pair.secretKey.dispose();
    }
  }

  /// Identifiant local, jamais transmis. Sert à retrouver le groupe.
  final String id;
  final String name;
  final Uint8List groupKey;
  final SecureKey aeadKey;
  final SecureKey tagKey;
  final Uint8List signPublic;
  final SecureKey signSecret;

  void dispose() {
    aeadKey.dispose();
    tagKey.dispose();
    signSecret.dispose();
    groupKey.fillRange(0, groupKey.length, 0);
  }
}

/// Identifiants Bluetooth dérivés du secret d'événement.
///
/// - L'identifiant annoncé change toutes les 15 minutes : un passant avec un
///   scanner ne peut ni reconnaître l'appli ni suivre un téléphone dans la
///   durée. Les voisins cherchent la période précédente, courante et suivante
///   pour absorber les écarts d'horloge.
/// - L'identifiant du service GATT et de la boîte de réception sont propres à
///   l'événement mais ne tournent pas (le faire couperait les connexions en
///   cours). Ils ne se voient qu'après s'être connecté.
class EventKeys {
  EventKeys(this._crypto, Uint8List eventSecret)
      : _secret = _crypto.secure(eventSecret);

  final MeshCrypto _crypto;
  final SecureKey _secret;

  static const advertisePeriod = Duration(minutes: 15);

  static int periodOf(DateTime now) =>
      now.millisecondsSinceEpoch ~/ advertisePeriod.inMilliseconds;

  Uint8List advertisedService(int period) {
    final extra = ByteData(8)..setUint64(0, period);
    return _crypto.derive(_secret, 'adv/1', 16, extra.buffer.asUint8List());
  }

  /// Les identifiants à chercher : période précédente, courante, suivante.
  List<Uint8List> servicesToScan(DateTime now) {
    final period = periodOf(now);
    return [for (final p in [period - 1, period, period + 1]) advertisedService(p)];
  }

  Uint8List get gattService => _crypto.derive(_secret, 'gatt/1', 16);

  Uint8List get inboxCharacteristic => _crypto.derive(_secret, 'inbox/1', 16);

  void dispose() => _secret.dispose();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
