import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../map/byte_source.dart';
import '../map/encrypted_source.dart';
import '../map/pmtiles.dart';
import '../mesh/mesh_crypto.dart';
import '../vault/vault_state.dart';
import '../vault/vault_store.dart';
import 'event_file.dart';
import 'organizer_packet.dart';

/// La carte hors ligne actuellement en place.
class MapInfo {
  const MapInfo({required this.name, required this.hash, required this.size, required this.expires});

  final String name;
  final String hash;
  final int size;
  final DateTime? expires;
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Un fichier d'événement lu et vérifié, pas encore importé : de quoi montrer à
/// la personne ce qu'elle s'apprête à accepter.
class IncomingEvent {
  const IncomingEvent({
    required this.file,
    required this.kind,
    required this.packet,
    required this.trusted,
    required this.packetIsNew,
    required this.mapStart,
    required this.mapLength,
    this.mapWanted = false,
    this.knownName,
    this.sameNameOtherKey = false,
  });

  final File file;
  final EventFileKind kind;

  /// Null pour une carte seule.
  final OrganizerPacket? packet;

  /// La clé du signataire est déjà dans la liste de ceux auxquels on fait
  /// confiance.
  final bool trusted;

  /// Le nom sous lequel on connaît ce signataire, s'il est de confiance.
  final String? knownName;

  /// Un autre organisateur de confiance porte le même nom avec une autre clé :
  /// soit une confusion, soit quelqu'un qui se fait passer pour lui.
  final bool sameNameOtherKey;

  /// Ce paquet est plus récent que celui qu'on a déjà (ou le premier).
  final bool packetIsNew;

  /// La carte jointe est annoncée par le paquet et on ne l'a pas encore.
  final bool mapWanted;
  final int mapStart;
  final int mapLength;

  bool get hasMap => mapLength > 0;
}

/// Ce que l'import d'un fichier a fait.
class EventImported {
  const EventImported({this.packet, this.packetAdded = false, this.map, this.mapProblem});

  final OrganizerPacket? packet;
  final bool packetAdded;

  /// La carte en place à la fin, jointe ou déjà là.
  final MapInfo? map;

  /// Pourquoi la carte jointe n'a pas été prise, alors que le paquet l'a été.
  final PacketRejected? mapProblem;
}

/// Les organisateurs de confiance, leurs paquets signés et la carte hors ligne.
///
/// - Un organisateur de confiance est une clé publique qu'on a scannée, ou dont on
///   a comparé l'empreinte en important son fichier.
/// - Un paquet n'est accepté que signé par l'un d'eux, jamais expiré, et plus
///   récent que celui qu'on a déjà.
/// - La carte n'est acceptée que si son empreinte est celle qu'un paquet signé
///   annonce. Elle est alors chiffrée (clé dans le coffre) avant d'être gardée.
///
/// Tout est dans le coffre ou chiffré par lui : l'effacement automatique emporte
/// les paquets, les organisateurs et, avec la clé, la carte.
class OrganizerService extends ChangeNotifier {
  OrganizerService({
    required this.session,
    required this.crypto,
    required this.mapsDirectory,
    DateTime Function()? now,
    this.learnMedicKey,
  }) : _now = now ?? DateTime.now;

  final VaultSession session;
  final MeshCrypto crypto;
  final Directory mapsDirectory;
  final DateTime Function() _now;

  /// Appelé quand un paquet donne la clé publique du canal des medics.
  final void Function(Uint8List key)? learnMedicKey;

  static const packetKind = 'org';
  static const mapKind = 'map';

  /// On tolère une horloge qui avance un peu sur celle de l'organisateur.
  static const _clockSlack = Duration(minutes: 10);

  // Un paquet déjà lu n'est pas relu à chaque affichage (null : illisible).
  final _parsed = <String, OrganizerPacket?>{};

  VaultState get _state => session.state;

  List<OrganizerRecord> get organizers => List.unmodifiable(_state.organizers);

  bool isTrusted(Uint8List key) => _state.organizers.any((o) => _same(o.publicKey, key));

  /// Fait confiance à cet organisateur (ou met à jour son nom).
  Future<void> trust(OrganizerInvite invite) async {
    final now = _now();
    final existing = _state.organizers.where((o) => _same(o.publicKey, invite.publicKey));
    if (existing.isNotEmpty) {
      existing.first
        ..name = invite.name
        ..lastActivity = now;
    } else {
      _state.organizers.add(
        OrganizerRecord(
          name: invite.name,
          publicKey: Uint8List.fromList(invite.publicKey),
          addedAt: now,
          lastActivity: now,
        ),
      );
    }
    await session.save();
    notifyListeners();
  }

  /// Ne plus faire confiance : ses paquets disparaissent, et la carte avec s'ils
  /// étaient les seuls à l'annoncer.
  Future<void> forget(Uint8List key) async {
    _state.organizers.removeWhere((o) => _same(o.publicKey, key));
    _state.records.removeWhere((r) => r.kind == packetKind && r.id == _packetId(key));
    _dropUnexpectedMaps();
    await session.save(removal: true);
    await cleanFiles();
    notifyListeners();
  }

  /// Les paquets valables : signés par un organisateur de confiance, pas expirés.
  List<OrganizerPacket> get packets {
    final now = _now();
    final result = <OrganizerPacket>[];
    for (final record in _state.records.where((r) => r.kind == packetKind)) {
      final raw = record.data['raw'];
      if (raw is! String) continue;
      final packet = _parsed.containsKey(raw) ? _parsed[raw] : (_parsed[raw] = _tryParse(raw));
      if (packet == null) continue;
      if (!isTrusted(packet.organizerKey)) continue;
      if (!packet.payload.expires.isAfter(now)) continue;
      result.add(packet);
    }
    result.sort((a, b) => b.payload.issued.compareTo(a.payload.issued));
    return result;
  }

  OrganizerPacket? _tryParse(String raw) {
    try {
      return OrganizerPacket.parse(raw, crypto);
    } on PacketRejected {
      return null;
    }
  }

  String _packetId(Uint8List key) => 'org:${_hex(key)}';

  void _checkTime(OrganizerPayload payload) {
    final now = _now();
    if (payload.issued.isAfter(now.add(_clockSlack))) throw PacketRejected(PacketProblem.notYetValid);
    if (!payload.expires.isAfter(now)) throw PacketRejected(PacketProblem.expired);
  }

  /// Le paquet qu'on garde déjà de cet organisateur, s'il y en a un.
  OrganizerPacket? _known(Uint8List key) {
    final id = _packetId(key);
    for (final record in _state.records.where((r) => r.kind == packetKind && r.id == id)) {
      final raw = record.data['raw'];
      final known = raw is String ? _tryParse(raw) : null;
      if (known != null) return known;
    }
    return null;
  }

  bool _hasMap(String hash) {
    final now = _now();
    return _state.records.any(
      (r) => r.kind == mapKind && r.data['hash'] == hash && !r.isExpired(now, _state.ttl),
    );
  }

  /// Lit un fichier d'événement (paquet seul, paquet et carte, ou carte seule) et
  /// vérifie ce qui peut l'être avant d'importer quoi que ce soit. Lève
  /// [PacketRejected] si le fichier est à refuser.
  Future<IncomingEvent> inspect(File file) async {
    final head = await EventFile.readHead(file);
    if (head.kind == EventFileKind.map) {
      if (!packets.any((p) => p.payload.map != null)) {
        throw PacketRejected(PacketProblem.mapNotExpected, 'aucun paquet n\'annonce de carte');
      }
      return IncomingEvent(
        file: file,
        kind: head.kind,
        packet: null,
        trusted: true,
        packetIsNew: false,
        mapStart: 0,
        mapLength: head.mapLength,
      );
    }
    final packet = OrganizerPacket.parse(head.packetText!.trim(), crypto);
    final payload = packet.payload;
    _checkTime(payload);
    final known = _known(packet.organizerKey);
    final isNew = known == null || payload.issued.isAfter(known.payload.issued);
    final wanted = head.mapLength > 0 && payload.map != null && !_hasMap(payload.map!.hash);
    if (!isNew && !wanted) throw PacketRejected(PacketProblem.older);

    String? knownName;
    var sameNameOtherKey = false;
    for (final o in _state.organizers) {
      if (_same(o.publicKey, packet.organizerKey)) {
        knownName = o.name;
      } else if (payload.organizerName.isNotEmpty &&
          o.name.toLowerCase() == payload.organizerName.toLowerCase()) {
        sameNameOtherKey = true;
      }
    }
    return IncomingEvent(
      file: file,
      kind: head.kind,
      packet: packet,
      trusted: knownName != null,
      knownName: knownName,
      sameNameOtherKey: sameNameOtherKey,
      packetIsNew: isNew,
      mapWanted: wanted,
      mapStart: head.mapStart,
      mapLength: head.mapLength,
    );
  }

  /// Importe ce que [inspect] a lu. Si le signataire n'est pas de confiance,
  /// [trustSigner] dit que la personne a comparé son empreinte et accepte de lui
  /// faire confiance : sans cela, rien n'est pris.
  Future<EventImported> importEvent(
    IncomingEvent event, {
    bool trustSigner = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final packet = event.packet;
    if (packet == null) {
      final map = await importMap(event.file, onProgress: onProgress);
      return EventImported(map: map);
    }
    if (!event.trusted) {
      if (!trustSigner) throw PacketRejected(PacketProblem.unknownOrganizer, packet.fingerprint);
      await trust(OrganizerInvite(name: _inviteName(packet), publicKey: packet.organizerKey));
    }
    if (event.packetIsNew) await importPacket(packet.raw);

    MapInfo? map;
    PacketRejected? mapProblem;
    if (event.hasMap) {
      if (packet.payload.map == null) {
        mapProblem = PacketRejected(PacketProblem.mapNotExpected, 'le paquet n\'annonce pas de carte');
      } else if (event.mapWanted) {
        try {
          map = await importMap(
            event.file,
            start: event.mapStart,
            length: event.mapLength,
            onProgress: onProgress,
          );
        } on PacketRejected catch (rejected) {
          mapProblem = rejected;
        }
      }
    }
    return EventImported(
      packet: packet,
      packetAdded: event.packetIsNew,
      map: map ?? mapInfo,
      mapProblem: mapProblem,
    );
  }

  /// Le nom sous lequel on enregistre un signataire qu'on vient d'accepter : celui
  /// qu'il se donne, sinon son empreinte.
  static String _inviteName(OrganizerPacket packet) {
    final given = packet.payload.organizerName;
    return given.isEmpty ? 'Organisateur ${packet.fingerprint}' : given;
  }

  /// Importe un paquet. Lève [PacketRejected] avec la raison du refus.
  Future<OrganizerPacket> importPacket(String text) async {
    final packet = OrganizerPacket.parse(text.trim(), crypto);
    if (!isTrusted(packet.organizerKey)) {
      throw PacketRejected(PacketProblem.unknownOrganizer, packet.fingerprint);
    }
    final now = _now();
    final payload = packet.payload;
    _checkTime(payload);

    final id = _packetId(packet.organizerKey);
    final known = _known(packet.organizerKey);
    if (known != null && !payload.issued.isAfter(known.payload.issued)) {
      throw PacketRejected(PacketProblem.older);
    }
    _state.records.removeWhere((r) => r.kind == packetKind && r.id == id);
    _state.records.add(
      VaultRecord(
        id: id,
        kind: packetKind,
        createdAt: now,
        expiresAt: payload.expires,
        data: {'raw': packet.raw},
      ),
    );
    _state.organizers.firstWhere((o) => _same(o.publicKey, packet.organizerKey)).lastActivity = now;
    _dropUnexpectedMaps();
    await session.save();
    await cleanFiles();
    final key = payload.medicKey;
    if (key != null) learnMedicKey?.call(key);
    notifyListeners();
    return packet;
  }

  /// La carte en place, si elle existe et n'est pas expirée.
  MapInfo? get mapInfo {
    final now = _now();
    for (final record in _state.records.where((r) => r.kind == mapKind)) {
      if (record.isExpired(now, _state.ttl)) continue;
      return MapInfo(
        name: record.data['name'] as String? ?? 'Carte',
        hash: record.data['hash'] as String? ?? '',
        size: record.data['size'] as int? ?? 0,
        expires: record.expiresAt,
      );
    }
    return null;
  }

  /// Importe un fichier de carte : il doit avoir l'empreinte annoncée par un
  /// paquet de confiance. Le fichier est chiffré, la copie en clair n'est pas
  /// gardée (c'est à l'appelant de supprimer son fichier d'origine).
  Future<MapInfo> importMap(
    File source, {
    int start = 0,
    int? length,
    void Function(int done, int total)? onProgress,
  }) async {
    final expected = packets.map((p) => (p, p.payload.map)).where((e) => e.$2 != null).toList();
    if (expected.isEmpty) throw PacketRejected(PacketProblem.mapNotExpected, 'aucun paquet n\'annonce de carte');
    final total = length ?? (await source.length() - start);
    var read = 0;
    final hash = _hex(await crypto.hashFile(source, start: start, length: total, onBytes: (n) {
      read += n;
      onProgress?.call(read ~/ 2, total);
    }));
    final match = expected.where((e) => e.$2!.hash == hash).toList();
    if (match.isEmpty) {
      final sameSize = expected.any((e) => e.$2!.size == total);
      throw PacketRejected(sameSize ? PacketProblem.mapCorrupted : PacketProblem.mapNotExpected);
    }
    final reference = match.first.$2!;
    final packet = match.first.$1;

    await mapsDirectory.create(recursive: true);
    final fileName = '${hash.substring(0, 24)}.ctm';
    final target = File('${mapsDirectory.path}${Platform.pathSeparator}$fileName');
    final keyBytes = crypto.randomBytes(32);
    final plainSize = await EncryptedMap.encrypt(
      crypto: crypto,
      source: source,
      target: target,
      keyBytes: keyBytes,
      start: start,
      length: total,
      onProgress: (done, all) => onProgress?.call(all ~/ 2 + done ~/ 2, total),
    );
    // On s'assure que ce qu'on garde se lit bien comme une carte.
    try {
      final check = await EncryptedByteSource.open(target, keyBytes, crypto);
      try {
        await (await PmtilesArchive.open(check)).close();
      } on Object {
        await check.close();
        rethrow;
      }
    } on Object catch (error) {
      if (await target.exists()) await target.delete();
      throw PacketRejected(PacketProblem.mapCorrupted, '$error');
    }

    _state.records.removeWhere((r) => r.kind == mapKind);
    _state.records.add(
      VaultRecord(
        id: 'map:$hash',
        kind: mapKind,
        createdAt: _now(),
        expiresAt: packet.payload.expires,
        data: {
          'file': fileName,
          'key': base64.encode(keyBytes),
          'hash': hash,
          'size': reference.size,
          'plain': plainSize,
          'name': reference.name.isEmpty ? packet.payload.name : reference.name,
        },
      ),
    );
    keyBytes.fillRange(0, keyBytes.length, 0);
    await session.save();
    await cleanFiles();
    notifyListeners();
    return mapInfo!;
  }

  /// Ouvre la carte pour la lire. À fermer par l'appelant.
  Future<PmtilesArchive?> openMap() async {
    final now = _now();
    for (final record in _state.records.where((r) => r.kind == mapKind)) {
      if (record.isExpired(now, _state.ttl)) continue;
      final file = File('${mapsDirectory.path}${Platform.pathSeparator}${record.data['file']}');
      if (!await file.exists()) continue;
      final key = Uint8List.fromList(base64.decode(record.data['key']! as String));
      final ByteSource source;
      try {
        source = await EncryptedByteSource.open(file, key, crypto);
      } finally {
        key.fillRange(0, key.length, 0);
      }
      try {
        return await PmtilesArchive.open(source);
      } on Object {
        // Un fichier qui ne s'ouvre pas ne doit pas rester ouvert.
        await source.close();
        rethrow;
      }
    }
    return null;
  }

  /// Une carte dont aucun paquet de confiance n'annonce plus l'empreinte ne se
  /// garde pas.
  void _dropUnexpectedMaps() {
    final wanted = {
      for (final p in packets)
        if (p.payload.map != null) p.payload.map!.hash,
    };
    _state.records.removeWhere((r) => r.kind == mapKind && !wanted.contains(r.data['hash']));
  }

  /// Supprime les fichiers de carte qui n'ont plus d'enregistrement valable.
  Future<void> cleanFiles() async {
    if (!await mapsDirectory.exists()) return;
    final now = _now();
    final keep = {
      for (final r in _state.records.where((r) => r.kind == mapKind && !r.isExpired(now, _state.ttl)))
        r.data['file'],
    };
    await for (final entry in mapsDirectory.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!keep.contains(name)) {
        try {
          await entry.delete();
        } on FileSystemException {
          // Un fichier encore ouvert se supprimera au prochain passage.
        }
      }
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
