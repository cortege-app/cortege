import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart' show SecureKey;

import '../map/byte_source.dart';
import '../map/pmtiles_extract.dart';
import '../mesh/mesh_crypto.dart';
import '../mesh/qr_codec.dart';
import 'event_file.dart';
import 'organizer_packet.dart';
import 'png.dart';

/// Ouvre une carte PMTiles distante, lue par morceaux. Fournie par le
/// programme qui lance l'outil : la bibliothèque, elle, n'ouvre aucune connexion.
typedef RemoteOpener = Future<ByteSource> Function(String url);

/// L'outil de l'organisateur : fabriquer sa clé, son QR, et signer des
/// événements. Tourne sur un ordinateur, jamais dans l'appli. La clé secrète
/// reste dans un fichier que l'organisateur garde pour lui ; ce qu'il distribue,
/// c'est le fichier d'événement (et, si besoin, le QR de sa clé).
///
///     keygen  --name "Collectif Eau" --out collectif.cle
///     event   --key collectif.cle --in evenement.json --out evenement.cortege [--map carte.pmtiles]
///     extract --zone ouest,sud,est,nord --out carte.pmtiles
///     qr      --key collectif.cle --out collectif-qr.png
///     show    --in evenement.cortege
///     packet  --key collectif.cle --in evenement.json --out paquet.cortege [--map carte.pmtiles]
///     hash    --in carte.pmtiles
Future<int> runOrganizerTool(
  List<String> args, {
  required MeshCrypto crypto,
  void Function(String line)? out,
  DateTime Function()? now,
  RemoteOpener? openRemote,
}) async {
  final void Function(String) say = out ?? (String line) => stdout.writeln(line);
  final clock = now ?? DateTime.now;
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    say(_usage);
    return args.isEmpty ? 2 : 0;
  }
  final command = args.first;
  try {
    final options = _parse(args.skip(1).toList());
    switch (command) {
      case 'keygen':
        return await _keygen(options, crypto, say);
      case 'qr':
        return await _qr(options, say);
      case 'event':
        return await _event(options, crypto, say, clock, openRemote);
      case 'extract':
        return await _extractCommand(options, say, clock, openRemote);
      case 'packet':
        return await _packet(options, crypto, say, clock);
      case 'show':
        return await _show(options, crypto, say);
      case 'hash':
        return await _hash(options, crypto, say);
    }
  } on _ToolError catch (error) {
    say('Erreur : ${error.message}');
    return 1;
  } on PacketRejected catch (error) {
    say('Paquet refusé : ${error.problem.name}${error.detail == null ? '' : ' (${error.detail})'}');
    return 1;
  } on ExtractException catch (error) {
    say('Carte impossible : ${error.message}');
    return 1;
  } on FileSystemException catch (error) {
    say('Erreur de fichier : ${error.message} ${error.path ?? ''}');
    return 1;
  } on FormatException catch (error) {
    say('Erreur de format : ${error.message}');
    return 1;
  } on TypeError {
    say('Erreur dans le fichier d\'événement : un champ manque ou n\'est pas du bon type.');
    return 1;
  }
  say('Commande inconnue : $command\n$_usage');
  return 2;
}

const _usage = '''Outil de l'organisateur Cortège

  keygen  --name "Nom" --out fichier.cle     crée ta clé et le QR à montrer
  event   --key fichier.cle --in evenement.json --out evenement.cortege [--map carte.pmtiles]
                                              fabrique LE fichier à envoyer :
                                              l'événement signé, avec sa carte
  extract --zone ouest,sud,est,nord --out carte.pmtiles [--zoom-max 15]
                                              prépare seulement une carte
  show    --in evenement.cortege              vérifie et affiche un fichier
  qr      --key fichier.cle --out qr.png      refait le QR d'une clé existante
  packet  --key fichier.cle --in evenement.json --out paquet.cortege [--map carte.pmtiles]
                                              paquet seul (ancienne méthode)
  hash    --in carte.pmtiles                  empreinte d'un fichier de carte

Dans evenement.json, "carte": true joint une carte de la zone du parcours,
ou "carte": {"zone": [ouest, sud, est, nord], "zoom_max": 15}.
Le fichier .cle contient ta clé secrète : ne le partage avec personne.''';

class _ToolError implements Exception {
  _ToolError(this.message);

  final String message;
}

Map<String, String> _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) throw _ToolError('argument inattendu : $arg');
    if (i + 1 >= args.length) throw _ToolError('il manque la valeur de $arg');
    options[arg.substring(2)] = args[++i];
  }
  return options;
}

String _need(Map<String, String> options, String name) =>
    options[name] ?? (throw _ToolError('option --$name manquante'));

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String text) => Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<void> _writeQr(String text, String path) async {
  final image = renderQr(encodeQr(text), moduleSize: 10, quiet: 4);
  await File(path).writeAsBytes(encodeGrayPng(image.pixels, image.side, image.side));
}

Future<int> _keygen(Map<String, String> options, MeshCrypto crypto, void Function(String) say) async {
  final name = _need(options, 'name');
  final path = _need(options, 'out');
  if (await File(path).exists()) {
    throw _ToolError('$path existe déjà : je ne l\'écrase pas (ce serait perdre la clé)');
  }
  final pair = crypto.newSigningKeyPair();
  final secret = pair.secretKey.extractBytes();
  pair.secretKey.dispose();
  // Le nom est contrôlé ici, avant d'écrire quoi que ce soit.
  final realInvite = OrganizerInvite(name: name, publicKey: pair.publicKey);
  await File(path).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'name': name,
      'publicKey': _b64(pair.publicKey),
      'secretKey': _b64(secret),
    }),
  );
  secret.fillRange(0, secret.length, 0);
  await _writeQr(realInvite.encode(), '$path.qr.png');
  say('Clé créée : $path (SECRÈTE : à garder pour toi)');
  say('Empreinte : ${realInvite.fingerprint}');
  say('Donne cette empreinte à voix haute, sur ton tract ou ton affiche : c\'est ce que les gens comparent.');
  say('QR à montrer ou imprimer : $path.qr.png');
  say('Texte du QR : ${realInvite.encode()}');
  return 0;
}

class _Key {
  _Key(this.name, this.publicKey, this.secret);

  final String name;
  final Uint8List publicKey;
  final SecureKey secret;
}

_Key _readKey(String path, MeshCrypto crypto) {
  final json = jsonDecode(File(path).readAsStringSync());
  if (json is! Map) throw _ToolError('$path n\'est pas un fichier de clé');
  final publicKey = _unb64(json['publicKey'] as String);
  final secret = _unb64(json['secretKey'] as String);
  if (publicKey.length != 32 || secret.length != 64) throw _ToolError('clé de taille inattendue dans $path');
  final key = _Key(json['name'] as String, publicKey, crypto.secure(secret));
  secret.fillRange(0, secret.length, 0);
  return key;
}

Future<int> _qr(Map<String, String> options, void Function(String) say) async {
  final json = jsonDecode(File(_need(options, 'key')).readAsStringSync()) as Map;
  final invite = OrganizerInvite(
    name: json['name'] as String,
    publicKey: _unb64(json['publicKey'] as String),
  );
  final path = _need(options, 'out');
  await _writeQr(invite.encode(), path);
  say('QR écrit : $path (empreinte ${invite.fingerprint})');
  return 0;
}

const _kinds = {
  'eau': PointKind.water,
  'toilettes': PointKind.toilets,
  'rdv': PointKind.meeting,
  'dispersion': PointKind.dispersal,
  'secours': PointKind.medic,
  'juridique': PointKind.legal,
  'sortie': PointKind.exit,
  'info': PointKind.info,
};

/// Le fichier d'événement de l'organisateur (celui qu'il écrit à la main).
class _Input {
  _Input({
    required this.name,
    required this.hours,
    required this.route,
    required this.points,
    required this.contacts,
    required this.medic,
    required this.carte,
  });

  final String name;
  final int hours;
  final List<(double, double)> route;
  final List<OrganizerPoint> points;
  final List<OrganizerContact> contacts;
  final String? medic;

  /// `true`, un objet avec la zone, ou rien.
  final Object? carte;
}

_Input _readInput(String path) {
  final input = jsonDecode(File(path).readAsStringSync());
  if (input is! Map) throw _ToolError('le fichier d\'événement doit être un objet JSON');
  final route = <(double, double)>[];
  for (final p in (input['parcours'] as List? ?? const [])) {
    final lat = ((p as List)[0] as num).toDouble();
    final lon = (p[1] as num).toDouble();
    if (lat.abs() > 90) throw _ToolError('latitude hors limites');
    if (lon.abs() > 180) throw _ToolError('longitude hors limites');
    route.add((lat, lon));
  }
  return _Input(
    name: input['nom'] as String,
    hours: (input['heures'] as num?)?.toInt() ?? 12,
    route: route,
    points: [
      for (final p in (input['lieux'] as List? ?? const []))
        OrganizerPoint(
          kind: _kinds[(p as Map)['type']] ??
              (throw _ToolError('type de lieu inconnu : ${p['type']} (attendu : ${_kinds.keys.join(', ')})')),
          name: (p['nom'] as String?) ?? '',
          lat: (p['lat'] as num).toDouble(),
          lon: (p['lon'] as num).toDouble(),
          note: (p['note'] as String?) ?? '',
        ),
    ],
    contacts: [
      for (final c in (input['contacts'] as List? ?? const []))
        OrganizerContact(
          name: (c as Map)['nom'] as String,
          phone: c['tel'] as String,
          note: (c['note'] as String?) ?? '',
        ),
    ],
    medic: input['cle_medic'] as String?,
    carte: input['carte'],
  );
}

OrganizerPayload _payload(_Input input, _Key key, DateTime issued, MapReference? map) => OrganizerPayload(
      name: input.name,
      issued: issued,
      expires: issued.add(Duration(hours: input.hours)),
      route: input.route,
      points: input.points,
      contacts: input.contacts,
      map: map,
      medicKey: input.medic == null ? null : _unb64(input.medic!),
      organizerName: key.name,
    );

Future<MapReference> _referenceOf(MeshCrypto crypto, File file, {String? name}) async => MapReference(
      hash: _hex(await crypto.hashFile(file)),
      size: await file.length(),
      name: name ?? file.uri.pathSegments.last,
    );

/// Signe, puis relit ce qu'on vient de signer : un paquet que l'appli
/// refuserait ne part pas.
String _sign(MeshCrypto crypto, _Key key, OrganizerPayload payload) {
  final text = OrganizerPacket.sign(
    crypto: crypto,
    publicKey: key.publicKey,
    secretKey: key.secret,
    payload: payload,
  );
  OrganizerPacket.parse(text, crypto);
  return text;
}

Future<int> _packet(
  Map<String, String> options,
  MeshCrypto crypto,
  void Function(String) say,
  DateTime Function() clock,
) async {
  final key = _readKey(_need(options, 'key'), crypto);
  try {
    final input = _readInput(_need(options, 'in'));
    final mapPath = options['map'];
    final map = mapPath == null ? null : await _referenceOf(crypto, File(mapPath));
    final text = _sign(crypto, key, _payload(input, key, clock().toUtc(), map));
    final path = _need(options, 'out');
    await File(path).writeAsString(text);
    say('Paquet écrit : $path (${text.length} octets)');
    say('Signé par ${key.name}, empreinte ${OrganizerPacket.fingerprintOf(key.publicKey)}');
    say('Valable ${input.hours} h, ${input.route.length} points de parcours, ${input.points.length} lieux, ${input.contacts.length} contacts');
    if (map != null) say('Carte annoncée : ${map.name}, ${map.size} octets, empreinte ${map.hash}');
    return 0;
  } finally {
    key.secret.dispose();
  }
}

ExtractArea _parseZone(String text) {
  final parts = text.split(',').map((s) => double.tryParse(s.trim())).toList();
  if (parts.length != 4 || parts.any((v) => v == null)) {
    throw _ToolError('la zone s\'écrit ouest,sud,est,nord en degrés, par exemple 2.325,48.845,2.375,48.870');
  }
  final zone = (west: parts[0]!, south: parts[1]!, east: parts[2]!, north: parts[3]!);
  if (zone.west.abs() > 180 || zone.east.abs() > 180 || zone.south.abs() > 90 || zone.north.abs() > 90) {
    throw _ToolError('zone hors limites');
  }
  return zone;
}

/// La zone du parcours et des lieux, élargie d'une marge.
ExtractArea _autoArea(_Input input, double marginMeters) {
  final points = [...input.route, for (final p in input.points) (p.lat, p.lon)];
  if (points.isEmpty) {
    throw _ToolError('"carte": true a besoin d\'un parcours ou de lieux. Sinon donne "zone": [ouest, sud, est, nord].');
  }
  var west = 180.0;
  var east = -180.0;
  var south = 90.0;
  var north = -90.0;
  for (final (lat, lon) in points) {
    west = math.min(west, lon);
    east = math.max(east, lon);
    south = math.min(south, lat);
    north = math.max(north, lat);
  }
  final cosLat = math.cos((south + north) / 2 * math.pi / 180).abs().clamp(0.05, 1.0);
  final dLat = marginMeters / 111320;
  final dLon = marginMeters / (111320 * cosLat);
  return (
    west: math.max(-180.0, west - dLon),
    south: math.max(-85.0, south - dLat),
    east: math.min(180.0, east + dLon),
    north: math.min(85.0, north + dLat),
  );
}

String _dayStamp(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';

/// La carte du monde de Protomaps la plus récente qui répond : les versions du
/// jour ne sont pas toujours déjà en ligne.
Future<ByteSource> _openBuild(
  Map<String, String> options,
  RemoteOpener? openRemote,
  DateTime Function() clock,
  void Function(String) say,
) async {
  if (openRemote == null) {
    throw _ToolError('cette version de l\'outil ne lit pas de carte en ligne : donne ta carte avec --map carte.pmtiles');
  }
  final given = options['source'];
  if (given != null) {
    say('Source de la carte : $given');
    return openRemote(given);
  }
  final today = clock().toUtc();
  Object? last;
  for (var back = 1; back <= 14; back++) {
    final url = 'https://build.protomaps.com/${_dayStamp(today.subtract(Duration(days: back)))}.pmtiles';
    try {
      final source = await openRemote(url);
      say('Source de la carte : $url');
      return source;
    } on Object catch (error) {
      last = error;
    }
  }
  throw _ToolError('aucune carte Protomaps récente n\'a répondu ($last). Vérifie ta connexion, ou donne --source ou --map.');
}

Future<void> _extractTo({
  required File target,
  required ExtractArea area,
  required int minZoom,
  required int maxZoom,
  required int maxMegabytes,
  required Map<String, String> options,
  required RemoteOpener? openRemote,
  required DateTime Function() clock,
  required void Function(String) say,
}) async {
  say('Zone : ${area.west.toStringAsFixed(4)}, ${area.south.toStringAsFixed(4)}, '
      '${area.east.toStringAsFixed(4)}, ${area.north.toStringAsFixed(4)} (ouest, sud, est, nord)');
  final source = await _openBuild(options, openRemote, clock, say);
  try {
    final result = await extractPmtiles(
      source: source,
      target: target,
      area: area,
      minZoom: minZoom,
      maxZoom: maxZoom,
      maxBytes: maxMegabytes * 1024 * 1024,
      log: say,
    );
    say('Carte prête : ${target.path}, ${(result.bytes / (1024 * 1024)).toStringAsFixed(1)} Mo, '
        '${result.addressedTiles} tuiles, zooms ${result.minZoom} à ${result.maxZoom}');
  } finally {
    await source.close();
  }
}

int _intOption(Map<String, String> options, String name, int fallback) {
  final text = options[name];
  if (text == null) return fallback;
  return int.tryParse(text) ?? (throw _ToolError('--$name attend un nombre entier'));
}

Future<int> _extractCommand(
  Map<String, String> options,
  void Function(String) say,
  DateTime Function() clock,
  RemoteOpener? openRemote,
) async {
  await _extractTo(
    target: File(_need(options, 'out')),
    area: _parseZone(_need(options, 'zone')),
    minZoom: _intOption(options, 'zoom-min', 9),
    maxZoom: _intOption(options, 'zoom-max', 15),
    maxMegabytes: _intOption(options, 'max-mo', 150),
    options: options,
    openRemote: openRemote,
    clock: clock,
    say: say,
  );
  return 0;
}

/// LE fichier à envoyer : l'événement signé et, selon le cas, la carte jointe.
Future<int> _event(
  Map<String, String> options,
  MeshCrypto crypto,
  void Function(String) say,
  DateTime Function() clock,
  RemoteOpener? openRemote,
) async {
  final key = _readKey(_need(options, 'key'), crypto);
  File? temporary;
  try {
    final input = _readInput(_need(options, 'in'));
    final path = _need(options, 'out');
    File? mapFile;
    final given = options['map'];
    if (given != null) {
      mapFile = File(given);
      if (!await mapFile.exists()) throw _ToolError('carte introuvable : $given');
    } else if (input.carte != null && input.carte != false) {
      final spec = input.carte is Map ? input.carte! as Map : const {};
      final ExtractArea area;
      final zone = spec['zone'];
      if (zone != null) {
        if (zone is! List || zone.length != 4) throw _ToolError('"zone" attend [ouest, sud, est, nord]');
        area = _parseZone(zone.join(','));
      } else {
        area = _autoArea(input, ((spec['marge_m'] as num?) ?? 1500).toDouble());
      }
      temporary = File('$path.carte.tmp');
      await _extractTo(
        target: temporary,
        area: area,
        minZoom: (spec['zoom_min'] as num?)?.toInt() ?? _intOption(options, 'zoom-min', 9),
        maxZoom: (spec['zoom_max'] as num?)?.toInt() ?? _intOption(options, 'zoom-max', 15),
        maxMegabytes: (spec['max_mo'] as num?)?.toInt() ?? _intOption(options, 'max-mo', 150),
        options: options,
        openRemote: openRemote,
        clock: clock,
        say: say,
      );
      mapFile = temporary;
    }

    // La carte extraite n'a qu'un nom de fichier provisoire : on lui en donne un lisible.
    final map = mapFile == null
        ? null
        : await _referenceOf(crypto, mapFile, name: identical(mapFile, temporary) ? 'carte.pmtiles' : null);
    final text = _sign(crypto, key, _payload(input, key, clock().toUtc(), map));
    if (mapFile == null) {
      await File(path).writeAsString(text);
    } else {
      await EventFile.write(packet: text, map: mapFile, target: File(path));
    }
    final size = await File(path).length();
    say('Fichier écrit : $path (${(size / (1024 * 1024)).toStringAsFixed(2)} Mo)');
    say('Signé par ${key.name}, empreinte ${OrganizerPacket.fingerprintOf(key.publicKey)}');
    say('Valable ${input.hours} h, ${input.route.length} points de parcours, ${input.points.length} lieux, ${input.contacts.length} contacts');
    say(map == null ? 'Sans carte : le parcours et les lieux s\'afficheront sur un fond vide.' : 'Carte jointe : ${map.name}, ${map.size} octets');
    say('Envoie ce fichier tel quel (messagerie, mail, clé USB). Chacun l\'ouvre avec Cortège, d\'un appui.');
    say('Donne ton empreinte ${OrganizerPacket.fingerprintOf(key.publicKey)} à voix haute ou sur ton affiche : les gens la comparent à l\'écran.');
    return 0;
  } finally {
    key.secret.dispose();
    if (temporary != null && await temporary.exists()) await temporary.delete();
  }
}

Future<int> _show(Map<String, String> options, MeshCrypto crypto, void Function(String) say) async {
  final file = File(_need(options, 'in'));
  final head = await EventFile.readHead(file);
  if (head.packetText == null) {
    say('Carte seule, ${head.mapLength} octets, empreinte ${_hex(await crypto.hashFile(file))}');
    return 0;
  }
  final packet = OrganizerPacket.parse(head.packetText!, crypto);
  final p = packet.payload;
  say('Signature valable. Empreinte de l\'organisateur : ${packet.fingerprint}');
  if (p.organizerName.isNotEmpty) say('Se présente comme : ${p.organizerName}');
  say('Nom : ${p.name}');
  say('Publié : ${p.issued.toIso8601String()}');
  say('Expire : ${p.expires.toIso8601String()}');
  say('Parcours : ${p.route.length} points');
  for (final point in p.points) {
    say('  ${point.kind.label} : ${point.name} (${point.lat}, ${point.lon})${point.note.isEmpty ? '' : ' - ${point.note}'}');
  }
  for (final contact in p.contacts) {
    say('  Contact : ${contact.name} ${contact.phone}');
  }
  if (p.map != null) say('Carte annoncée : ${p.map!.name}, ${p.map!.size} octets, ${p.map!.hash}');
  if (head.mapLength > 0 && head.kind == EventFileKind.bundle) {
    final hash = _hex(await crypto.hashFile(file, start: head.mapStart, length: head.mapLength));
    final ok = p.map != null && p.map!.hash == hash;
    say(ok
        ? 'Carte jointe : ${head.mapLength} octets, conforme à celle que le paquet annonce'
        : 'Carte jointe : ${head.mapLength} octets, NE CORRESPOND PAS à ce que le paquet annonce');
  } else if (p.map != null) {
    say('Pas de carte jointe à ce fichier.');
  }
  return 0;
}

Future<int> _hash(Map<String, String> options, MeshCrypto crypto, void Function(String) say) async {
  say(_hex(await crypto.hashFile(File(_need(options, 'in')))));
  return 0;
}
