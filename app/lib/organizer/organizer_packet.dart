import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import '../mesh/mesh_crypto.dart';
import '../mesh/names.dart';

enum PacketProblem {
  /// Pas un paquet Cortège, ou contenu absurde.
  malformed,
  tooBig,
  badSignature,

  /// La signature est bonne, mais l'organisateur n'est pas dans la liste de ceux
  /// auxquels ce téléphone fait confiance.
  unknownOrganizer,
  expired,
  notYetValid,

  /// Un paquet plus récent du même organisateur est déjà là.
  older,

  /// Le fichier de carte ne correspond à aucun paquet de confiance.
  mapNotExpected,
  mapCorrupted,
}

class PacketRejected implements Exception {
  PacketRejected(this.problem, [this.detail]);

  final PacketProblem problem;
  final String? detail;

  @override
  String toString() => 'PacketRejected(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// Ce qu'un organisateur peut poser sur la carte.
enum PointKind {
  water('E', 'Point d\'eau'),
  toilets('WC', 'Toilettes'),
  meeting('RV', 'Rendez-vous'),
  dispersal('D', 'Dispersion'),
  medic('M', 'Poste de secours'),
  legal('J', 'Aide juridique'),
  exit('S', 'Sortie'),
  info('i', 'Information');

  const PointKind(this.symbol, this.label);

  final String symbol;
  final String label;

  static PointKind? parse(String code) {
    for (final kind in values) {
      if (kind.name == code) return kind;
    }
    return null;
  }
}

class OrganizerPoint {
  const OrganizerPoint({
    required this.kind,
    required this.name,
    required this.lat,
    required this.lon,
    this.note = '',
  });

  final PointKind kind;
  final String name;
  final double lat;
  final double lon;
  final String note;
}

/// Un contact utile (permanence juridique, coordination). Un numéro s'affiche,
/// il n'est jamais composé tout seul.
class OrganizerContact {
  const OrganizerContact({required this.name, required this.phone, this.note = ''});

  final String name;
  final String phone;
  final String note;
}

/// La carte hors ligne que les organisateurs recommandent : son empreinte
/// (BLAKE2b sur 256 bits) est dans le paquet signé, donc un fichier de carte
/// trafiqué est refusé.
class MapReference {
  const MapReference({required this.hash, required this.size, required this.name});

  /// Empreinte en hexadécimal, 64 caractères.
  final String hash;
  final int size;
  final String name;
}

/// Le contenu signé d'un paquet.
class OrganizerPayload {
  OrganizerPayload({
    required this.name,
    required this.issued,
    required this.expires,
    this.route = const [],
    this.points = const [],
    this.contacts = const [],
    this.map,
    this.medicKey,
    this.organizerName = '',
  });

  static const maxRoutePoints = 1000;
  static const maxPoints = 150;
  static const maxContacts = 30;
  static const maxValidity = Duration(days: 30);

  final String name;
  final DateTime issued;
  final DateTime expires;

  /// Le parcours déclaré : (latitude, longitude).
  final List<(double, double)> route;
  final List<OrganizerPoint> points;
  final List<OrganizerContact> contacts;
  final MapReference? map;

  /// Clé publique du canal des medics de l'événement, si l'organisateur la donne.
  final Uint8List? medicKey;

  /// Le nom que l'organisateur se donne. Il l'écrit lui-même : tant qu'on n'a pas
  /// comparé l'empreinte de sa clé, ça ne prouve rien.
  final String organizerName;

  Map<String, Object?> toJson() => {
        'v': 1,
        'name': name,
        if (organizerName.isNotEmpty) 'by': organizerName,
        'issued': issued.millisecondsSinceEpoch ~/ 1000,
        'expires': expires.millisecondsSinceEpoch ~/ 1000,
        if (route.isNotEmpty) 'route': [for (final p in route) [_round(p.$1), _round(p.$2)]],
        if (points.isNotEmpty)
          'points': [
            for (final p in points)
              {
                'k': p.kind.name,
                'n': p.name,
                'lat': _round(p.lat),
                'lon': _round(p.lon),
                if (p.note.isNotEmpty) 'note': p.note,
              },
          ],
        if (contacts.isNotEmpty)
          'contacts': [
            for (final c in contacts)
              {'n': c.name, 't': c.phone, if (c.note.isNotEmpty) 'note': c.note},
          ],
        if (map != null) 'map': {'hash': map!.hash, 'size': map!.size, 'name': map!.name},
        if (medicKey != null) 'medicKey': base64Url.encode(medicKey!).replaceAll('=', ''),
      };

  static double _round(double v) => (v * 1e6).round() / 1e6;

  /// Lit et contrôle un contenu. Tout ce qui sort des limites est refusé : un
  /// paquet signé par un organisateur de confiance reste une entrée qu'on ne
  /// croit pas sur parole.
  factory OrganizerPayload.fromJson(Map<String, Object?> json) {
    PacketRejected bad(String why) => PacketRejected(PacketProblem.malformed, why);
    if (json['v'] != 1) throw bad('version');
    String text(Object? value, String field, int max, {bool required = false}) {
      if (value == null) {
        if (required) throw bad(field);
        return '';
      }
      if (value is! String) throw bad(field);
      final cleaned = cleanName(value);
      if (required && (value.isEmpty || cleaned.isEmpty)) throw bad(field);
      if (value.length > max) throw bad(field);
      return value.isEmpty ? '' : cleaned;
    }

    double coordinate(Object? value, double limit, String field) {
      if (value is! num) throw bad(field);
      final v = value.toDouble();
      if (v.isNaN || v.isInfinite || v < -limit || v > limit) throw bad(field);
      return v;
    }

    DateTime time(Object? value, String field) {
      if (value is! int || value < 0 || value > 4102444800) throw bad(field);
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }

    final name = text(json['name'], 'name', 80, required: true);
    final organizerName = text(json['by'], 'by', OrganizerInvite.maxNameBytes);
    if (utf8.encode(organizerName).length > OrganizerInvite.maxNameBytes) throw bad('by');
    final issued = time(json['issued'], 'issued');
    final expires = time(json['expires'], 'expires');
    if (!expires.isAfter(issued) || expires.difference(issued) > maxValidity) throw bad('validité');

    final route = <(double, double)>[];
    final rawRoute = json['route'];
    if (rawRoute != null) {
      if (rawRoute is! List || rawRoute.length > maxRoutePoints) throw bad('route');
      for (final p in rawRoute) {
        if (p is! List || p.length != 2) throw bad('route');
        route.add((coordinate(p[0], 90, 'route'), coordinate(p[1], 180, 'route')));
      }
    }

    final points = <OrganizerPoint>[];
    final rawPoints = json['points'];
    if (rawPoints != null) {
      if (rawPoints is! List || rawPoints.length > maxPoints) throw bad('points');
      for (final p in rawPoints) {
        if (p is! Map) throw bad('points');
        final kind = PointKind.parse(p['k'] is String ? p['k']! as String : '');
        if (kind == null) throw bad('points');
        points.add(OrganizerPoint(
          kind: kind,
          name: text(p['n'], 'point', 60),
          lat: coordinate(p['lat'], 90, 'point'),
          lon: coordinate(p['lon'], 180, 'point'),
          note: text(p['note'], 'point', 300),
        ));
      }
    }

    final contacts = <OrganizerContact>[];
    final rawContacts = json['contacts'];
    if (rawContacts != null) {
      if (rawContacts is! List || rawContacts.length > maxContacts) throw bad('contacts');
      for (final c in rawContacts) {
        if (c is! Map) throw bad('contacts');
        final phone = text(c['t'], 'contact', 30, required: true);
        if (!RegExp(r'^[0-9 +().\-]+$').hasMatch(phone)) throw bad('contact');
        contacts.add(OrganizerContact(
          name: text(c['n'], 'contact', 60, required: true),
          phone: phone,
          note: text(c['note'], 'contact', 200),
        ));
      }
    }

    MapReference? map;
    final rawMap = json['map'];
    if (rawMap != null) {
      if (rawMap is! Map) throw bad('carte');
      final hash = rawMap['hash'];
      final size = rawMap['size'];
      if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw bad('carte');
      if (size is! int || size <= 0 || size > 4 * 1024 * 1024 * 1024) throw bad('carte');
      map = MapReference(hash: hash, size: size, name: text(rawMap['name'], 'carte', 80));
    }

    Uint8List? medicKey;
    final rawKey = json['medicKey'];
    if (rawKey != null) {
      if (rawKey is! String) throw bad('medicKey');
      try {
        medicKey = base64Url.decode(base64Url.normalize(rawKey));
      } on FormatException {
        throw bad('medicKey');
      }
      if (medicKey.length != 32) throw bad('medicKey');
    }

    return OrganizerPayload(
      name: name,
      issued: issued,
      expires: expires,
      route: route,
      points: points,
      contacts: contacts,
      map: map,
      medicKey: medicKey,
      organizerName: organizerName,
    );
  }
}

/// Un paquet : le contenu, la clé de l'organisateur et sa signature.
///
/// Sur le disque ou dans un message, c'est un petit document JSON :
/// `{"cortege":"org1","key":...,"sig":...,"body":...}` où `body` est le contenu
/// encodé, et la signature (Ed25519) couvre un préfixe de contexte puis ces
/// octets exacts. Rien n'est affiché avant que la signature soit vérifiée.
class OrganizerPacket {
  OrganizerPacket._(this.organizerKey, this.signature, this.body, this.payload, this.raw);

  static const maxRawLength = 96 * 1024;
  static const maxBodyLength = 64 * 1024;
  static const _context = 'cortege/org/1\n';

  final Uint8List organizerKey;
  final Uint8List signature;
  final Uint8List body;
  final OrganizerPayload payload;

  /// Le texte d'origine, gardé tel quel pour pouvoir revérifier la signature.
  final String raw;

  /// Les huit premiers caractères de l'empreinte de la clé, pour reconnaître un
  /// organisateur d'un coup d'œil (« 1a2b-3c4d »).
  String get fingerprint => fingerprintOf(organizerKey);

  static String fingerprintOf(Uint8List key) {
    final hex = key.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 4)}-${hex.substring(4)}';
  }

  static Uint8List _signed(Uint8List body) =>
      Uint8List.fromList([...utf8.encode(_context), ...body]);

  /// Écrit un paquet signé. Sert à l'outil de l'organisateur et aux tests.
  static String sign({
    required MeshCrypto crypto,
    required Uint8List publicKey,
    required SecureKey secretKey,
    required OrganizerPayload payload,
  }) {
    final body = Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));
    final signature = crypto.sign(_signed(body), secretKey);
    String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
    return jsonEncode({
      'cortege': 'org1',
      'key': b64(publicKey),
      'sig': b64(signature),
      'body': b64(body),
    });
  }

  /// Lit un paquet et vérifie sa signature. Ne dit pas si l'organisateur est de
  /// confiance : c'est à l'appelant de le contrôler.
  static OrganizerPacket parse(String text, MeshCrypto crypto) {
    if (text.length > maxRawLength) throw PacketRejected(PacketProblem.tooBig);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw PacketRejected(PacketProblem.malformed, 'JSON');
    }
    if (decoded is! Map || decoded['cortege'] != 'org1') {
      throw PacketRejected(PacketProblem.malformed, 'pas un paquet Cortège');
    }
    final Map<Object?, Object?> envelope = decoded;
    Uint8List field(String name, int? exact) {
      final value = envelope[name];
      if (value is! String) throw PacketRejected(PacketProblem.malformed, name);
      try {
        final bytes = base64Url.decode(base64Url.normalize(value));
        if (exact != null && bytes.length != exact) throw PacketRejected(PacketProblem.malformed, name);
        return Uint8List.fromList(bytes);
      } on FormatException {
        throw PacketRejected(PacketProblem.malformed, name);
      }
    }

    final key = field('key', MeshCrypto.publicKeyBytes);
    final signature = field('sig', MeshCrypto.signatureBytes);
    final body = field('body', null);
    if (body.length > maxBodyLength) throw PacketRejected(PacketProblem.tooBig);
    if (!crypto.verify(_signed(body), signature, key)) {
      throw PacketRejected(PacketProblem.badSignature);
    }
    final Object? content;
    try {
      content = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw PacketRejected(PacketProblem.malformed, 'contenu');
    }
    if (content is! Map) throw PacketRejected(PacketProblem.malformed, 'contenu');
    final payload = OrganizerPayload.fromJson(Map<String, Object?>.from(content));
    return OrganizerPacket._(key, signature, body, payload, text);
  }
}

/// Le QR que montre un organisateur : sa clé publique et son nom. Le scanner,
/// c'est décider de croire les paquets signés par cette clé. À scanner en face à
/// face, sur le téléphone ou le papier de l'organisateur, pas sur une photo
/// reçue par message.
class OrganizerInvite {
  OrganizerInvite({required this.name, required this.publicKey}) {
    if (publicKey.length != 32) throw const FormatException('clé de 32 octets attendue');
    final bytes = utf8.encode(name);
    if (bytes.isEmpty || bytes.length > maxNameBytes) {
      throw const FormatException('nom vide ou trop long');
    }
  }

  static const prefix = 'CORTEGEO1.';
  static const maxNameBytes = 40;

  final String name;
  final Uint8List publicKey;

  String get fingerprint => OrganizerPacket.fingerprintOf(publicKey);

  String encode() {
    final nameBytes = utf8.encode(name);
    final raw = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(publicKey)
      ..addByte(nameBytes.length)
      ..add(nameBytes);
    return prefix + base64Url.encode(raw.toBytes()).replaceAll('=', '');
  }

  factory OrganizerInvite.decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const FormatException('ce QR n\'est pas un code d\'organisateur Cortège');
    }
    final Uint8List raw;
    try {
      raw = base64Url.decode(base64Url.normalize(trimmed.substring(prefix.length)));
    } on FormatException {
      throw const FormatException('code illisible');
    }
    if (raw.length < 35 || raw[0] != 1) throw const FormatException('code d\'une version inconnue');
    final nameLength = raw[33];
    if (raw.length != 34 + nameLength) throw const FormatException('code tronqué');
    final String name;
    try {
      name = cleanName(utf8.decode(raw.sublist(34)));
    } on FormatException {
      throw const FormatException('nom illisible');
    }
    return OrganizerInvite(name: name, publicKey: Uint8List.fromList(raw.sublist(1, 33)));
  }
}
