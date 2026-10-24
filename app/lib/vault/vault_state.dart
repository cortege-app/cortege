import 'dart:convert';
import 'dart:typed_data';

enum VaultRole { real, decoy }

/// Une donnée de l'événement (message, alerte, paquet d'organisateur...).
/// Tout ce qui a une durée de vie passe par ici pour que l'effacement
/// automatique le trouve.
class VaultRecord {
  VaultRecord({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.expiresAt,
    Map<String, Object?>? data,
  }) : data = data ?? {};

  final String id;
  final String kind;
  final DateTime createdAt;

  /// Échéance propre à l'enregistrement (paquet d'organisateur périmé, par
  /// exemple). La durée générale des réglages s'applique en plus.
  final DateTime? expiresAt;
  final Map<String, Object?> data;

  bool isExpired(DateTime now, Duration ttl) {
    if (!now.isBefore(createdAt.add(ttl))) return true;
    final own = expiresAt;
    return own != null && !now.isBefore(own);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
        'data': data,
      };

  factory VaultRecord.fromJson(Map<String, Object?> json) => VaultRecord(
        id: json['id']! as String,
        kind: json['kind']! as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['expiresAt']! as int),
        data: Map<String, Object?>.from(json['data']! as Map),
      );
}

/// Un groupe de messagerie rejoint par ce téléphone, avec les clés qu'il faut
/// pour le lire et y écrire. Ces clés sont des données de l'événement : elles
/// disparaissent comme les messages.
class GroupRecord {
  GroupRecord({
    required this.name,
    required this.groupKey,
    required this.signPublic,
    required this.signSecret,
    required this.joinedAt,
    required this.lastActivity,
  });

  final String name;
  final Uint8List groupKey;
  final Uint8List signPublic;
  final Uint8List signSecret;
  final DateTime joinedAt;

  /// Dernier message envoyé ou reçu dans ce groupe. Un groupe sans activité
  /// pendant la durée d'effacement est supprimé avec ses clés.
  DateTime lastActivity;

  bool isExpired(DateTime now, Duration ttl) => !now.isBefore(lastActivity.add(ttl));

  Map<String, Object?> toJson() => {
        'name': name,
        'groupKey': base64.encode(groupKey),
        'signPublic': base64.encode(signPublic),
        'signSecret': base64.encode(signSecret),
        'joinedAt': joinedAt.millisecondsSinceEpoch,
        'lastActivity': lastActivity.millisecondsSinceEpoch,
      };

  factory GroupRecord.fromJson(Map<String, Object?> json) => GroupRecord(
        name: json['name']! as String,
        groupKey: base64.decode(json['groupKey']! as String),
        signPublic: base64.decode(json['signPublic']! as String),
        signSecret: base64.decode(json['signSecret']! as String),
        joinedAt: DateTime.fromMillisecondsSinceEpoch(json['joinedAt']! as int),
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch(json['lastActivity']! as int),
      );
}

/// Un proche appairé : sa clé de signature et sa chaîne de clés de message.
/// La chaîne avance à chaque message reçu et les anciennes clés sont jetées :
/// c'est ce qui donne la confidentialité persistante du binôme.
class BuddyMemberRecord {
  BuddyMemberRecord({
    required this.name,
    required this.signPublic,
    required this.chainKey,
    required this.nextIndex,
    Map<int, Uint8List>? skipped,
  }) : skipped = skipped ?? {};

  String name;
  final Uint8List signPublic;

  /// Clé de chaîne pour le message numéro [nextIndex].
  Uint8List chainKey;
  int nextIndex;

  /// Clés des messages sautés (arrivés dans le désordre ou perdus en route),
  /// gardées le temps qu'ils arrivent. Bornées.
  final Map<int, Uint8List> skipped;

  Map<String, Object?> toJson() => {
        'name': name,
        'signPublic': base64.encode(signPublic),
        'chainKey': base64.encode(chainKey),
        'nextIndex': nextIndex,
        'skipped': {
          for (final e in skipped.entries) '${e.key}': base64.encode(e.value),
        },
      };

  factory BuddyMemberRecord.fromJson(Map<String, Object?> json) => BuddyMemberRecord(
        name: json['name']! as String,
        signPublic: base64.decode(json['signPublic']! as String),
        chainKey: base64.decode(json['chainKey']! as String),
        nextIndex: json['nextIndex']! as int,
        skipped: {
          for (final e in (json['skipped']! as Map).entries)
            int.parse(e.key as String): base64.decode(e.value as String),
        },
      );
}

/// Un binôme : 2 à 4 personnes qui se sont scanné leurs codes en face à face.
class BuddyRecord {
  BuddyRecord({
    required this.id,
    required this.tagKey,
    required this.ownName,
    required this.signPublic,
    required this.signSecret,
    required this.sendChainKey,
    required this.sendIndex,
    required this.members,
    required this.createdAt,
    required this.lastActivity,
  });

  static const maxPeople = 4;

  final Uint8List id;

  /// Sert à reconnaître les trames du binôme, jamais à les déchiffrer.
  final Uint8List tagKey;
  String ownName;
  final Uint8List signPublic;
  final Uint8List signSecret;

  /// Clé de chaîne de nos propres messages, pour le numéro [sendIndex].
  Uint8List sendChainKey;
  int sendIndex;

  /// Les autres personnes du binôme (au plus trois).
  final List<BuddyMemberRecord> members;
  final DateTime createdAt;
  DateTime lastActivity;

  bool get isFull => members.length + 1 >= maxPeople;

  bool isExpired(DateTime now, Duration ttl) => !now.isBefore(lastActivity.add(ttl));

  Map<String, Object?> toJson() => {
        'id': base64.encode(id),
        'tagKey': base64.encode(tagKey),
        'ownName': ownName,
        'signPublic': base64.encode(signPublic),
        'signSecret': base64.encode(signSecret),
        'sendChainKey': base64.encode(sendChainKey),
        'sendIndex': sendIndex,
        'members': [for (final m in members) m.toJson()],
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastActivity': lastActivity.millisecondsSinceEpoch,
      };

  factory BuddyRecord.fromJson(Map<String, Object?> json) => BuddyRecord(
        id: base64.decode(json['id']! as String),
        tagKey: base64.decode(json['tagKey']! as String),
        ownName: json['ownName']! as String,
        signPublic: base64.decode(json['signPublic']! as String),
        signSecret: base64.decode(json['signSecret']! as String),
        sendChainKey: base64.decode(json['sendChainKey']! as String),
        sendIndex: json['sendIndex']! as int,
        members: [
          for (final m in json['members']! as List)
            BuddyMemberRecord.fromJson(Map<String, Object?>.from(m as Map)),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
        lastActivity: DateTime.fromMillisecondsSinceEpoch(json['lastActivity']! as int),
      );
}

/// Un organisateur auquel ce téléphone fait confiance : ses paquets signés sont
/// acceptés. Donnée de l'événement : elle disparaît comme les autres.
class OrganizerRecord {
  OrganizerRecord({
    required this.name,
    required this.publicKey,
    required this.addedAt,
    required this.lastActivity,
  });

  String name;
  final Uint8List publicKey;
  final DateTime addedAt;

  /// Dernier paquet reçu ou dernier scan de son code.
  DateTime lastActivity;

  bool isExpired(DateTime now, Duration ttl) => !now.isBefore(lastActivity.add(ttl));

  Map<String, Object?> toJson() => {
        'name': name,
        'publicKey': base64.encode(publicKey),
        'addedAt': addedAt.millisecondsSinceEpoch,
        'lastActivity': lastActivity.millisecondsSinceEpoch,
      };

  factory OrganizerRecord.fromJson(Map<String, Object?> json) => OrganizerRecord(
        name: json['name']! as String,
        publicKey: base64.decode(json['publicKey']! as String),
        addedAt: DateTime.fromMillisecondsSinceEpoch(json['addedAt']! as int),
        lastActivity: DateTime.fromMillisecondsSinceEpoch(json['lastActivity']! as int),
      );
}

class VaultState {
  VaultState({
    required this.role,
    this.ttl = defaultTtl,
    this.lockAfter = defaultLockAfter,
    this.closeAfter = defaultCloseAfter,
    this.checkInEvery = defaultCheckInEvery,
    this.displayName,
    this.eventSecret,
    this.medicPublicKey,
    this.medicSecretKey,
    this.medicActive = false,
    this.medicActivity,
    List<VaultRecord>? records,
    List<GroupRecord>? groups,
    List<BuddyRecord>? buddies,
    List<OrganizerRecord>? organizers,
  })  : records = records ?? [],
        groups = groups ?? [],
        buddies = buddies ?? [],
        organizers = organizers ?? [];

  static const formatVersion = 1;
  static const defaultTtl = Duration(hours: 24);
  static const defaultLockAfter = Duration(seconds: 30);
  static const defaultCloseAfter = Duration(hours: 1);
  static const defaultCheckInEvery = Duration(minutes: 5);

  /// Écrit dans le contenu chiffré, jamais en clair : rien dans les fichiers ne
  /// dit lequel des deux coffres est le leurre.
  final VaultRole role;
  Duration ttl;

  /// Premier niveau : temps passé en arrière-plan avant que l'écran de code
  /// s'affiche. À partir de là, il faut le code pour voir quoi que ce soit.
  Duration lockAfter;

  /// Second niveau : temps pendant lequel, derrière l'écran de code, la clé du
  /// coffre et le maillage restent en mémoire pour continuer à recevoir et à
  /// relayer. Ensuite le coffre se verrouille pour de bon. [Duration.zero] :
  /// les deux niveaux se confondent, tout se ferme avec l'écran de code.
  Duration closeAfter;

  /// Le pseudo montré dans les groupes.
  String? displayName;

  /// Intervalle entre deux check-ins automatiques vers le binôme.
  Duration checkInEvery;

  /// Secret de l'événement en cours, partagé par QR : il sert à calculer les
  /// identifiants Bluetooth. Absent tant qu'on n'est dans aucun groupe.
  Uint8List? eventSecret;

  /// Clé publique du canal des medics de l'événement : n'importe qui peut y
  /// écrire une alerte, seuls les medics peuvent la lire. Elle voyage dans les
  /// invitations de groupe.
  Uint8List? medicPublicKey;

  /// Clé secrète du canal des medics. Seuls les medics l'ont.
  Uint8List? medicSecretKey;

  /// Le rôle « medic » est activé dans les réglages.
  bool medicActive;

  /// Dernière fois que le canal des medics a servi (clés reçues, alerte lancée
  /// ou reçue). Sans groupe ni binôme, le canal est effacé à la fin de la durée
  /// d'effacement qui suit.
  DateTime? medicActivity;

  final List<VaultRecord> records;
  final List<GroupRecord> groups;
  final List<BuddyRecord> buddies;

  /// Les organisateurs de confiance.
  final List<OrganizerRecord> organizers;

  Map<String, Object?> toJson() => {
        'v': formatVersion,
        'role': role.name,
        'ttlMinutes': ttl.inMinutes,
        'lockAfterSeconds': lockAfter.inSeconds,
        'closeAfterSeconds': closeAfter.inSeconds,
        'checkInSeconds': checkInEvery.inSeconds,
        if (displayName != null) 'displayName': displayName,
        if (eventSecret != null) 'eventSecret': base64.encode(eventSecret!),
        if (medicPublicKey != null) 'medicPublicKey': base64.encode(medicPublicKey!),
        if (medicSecretKey != null) 'medicSecretKey': base64.encode(medicSecretKey!),
        'medicActive': medicActive,
        if (medicActivity != null) 'medicActivity': medicActivity!.millisecondsSinceEpoch,
        'records': [for (final r in records) r.toJson()],
        'groups': [for (final g in groups) g.toJson()],
        'buddies': [for (final b in buddies) b.toJson()],
        if (organizers.isNotEmpty) 'organizers': [for (final o in organizers) o.toJson()],
      };

  factory VaultState.fromJson(Map<String, Object?> json) {
    if (json['v'] != formatVersion) {
      throw FormatException('version de coffre inconnue: ${json['v']}');
    }
    return VaultState(
      role: VaultRole.values.byName(json['role']! as String),
      ttl: Duration(minutes: json['ttlMinutes']! as int),
      lockAfter: json['lockAfterSeconds'] == null
          ? defaultLockAfter
          : Duration(seconds: json['lockAfterSeconds']! as int),
      closeAfter: json['closeAfterSeconds'] == null
          ? defaultCloseAfter
          : Duration(seconds: json['closeAfterSeconds']! as int),
      checkInEvery: json['checkInSeconds'] == null
          ? defaultCheckInEvery
          : Duration(seconds: json['checkInSeconds']! as int),
      displayName: json['displayName'] as String?,
      eventSecret: json['eventSecret'] == null
          ? null
          : base64.decode(json['eventSecret']! as String),
      medicPublicKey: json['medicPublicKey'] == null
          ? null
          : base64.decode(json['medicPublicKey']! as String),
      medicSecretKey: json['medicSecretKey'] == null
          ? null
          : base64.decode(json['medicSecretKey']! as String),
      medicActive: (json['medicActive'] as bool?) ?? false,
      medicActivity: json['medicActivity'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(json['medicActivity']! as int),
      records: [
        for (final r in json['records']! as List)
          VaultRecord.fromJson(Map<String, Object?>.from(r as Map)),
      ],
      groups: [
        for (final g in (json['groups'] as List?) ?? const [])
          GroupRecord.fromJson(Map<String, Object?>.from(g as Map)),
      ],
      buddies: [
        for (final b in (json['buddies'] as List?) ?? const [])
          BuddyRecord.fromJson(Map<String, Object?>.from(b as Map)),
      ],
      organizers: [
        for (final o in (json['organizers'] as List?) ?? const [])
          OrganizerRecord.fromJson(Map<String, Object?>.from(o as Map)),
      ],
    );
  }
}
