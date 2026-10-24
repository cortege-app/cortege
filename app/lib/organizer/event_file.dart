import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'organizer_packet.dart';

enum EventFileKind {
  /// Le paquet signé, suivi de la carte.
  bundle,

  /// Le paquet signé seul (un petit texte JSON).
  packet,

  /// Une carte PMTiles seule, sans paquet.
  map,
}

/// Le début d'un fichier d'événement : de quoi savoir ce qu'il contient sans le
/// lire en entier.
class EventFileHead {
  const EventFileHead({required this.kind, this.packetText, this.mapStart = 0, this.mapLength = 0});

  final EventFileKind kind;
  final String? packetText;

  /// Où commence la carte dans le fichier, et sa taille (0 : pas de carte).
  final int mapStart;
  final int mapLength;
}

/// Le fichier que l'organisateur envoie : tout l'événement en un seul morceau.
///
///     octets 0 à 3     « CTB1 »
///     octets 4 à 7     taille du paquet (entier, grand-boutiste)
///     ensuite          le paquet signé (texte JSON, UTF-8)
///     ensuite          la carte PMTiles, jusqu'à la fin
///
/// Rien ici n'est de confiance : la signature du paquet dit qui parle, et
/// l'empreinte de la carte, écrite dans ce paquet signé, dit si la carte jointe
/// est la bonne. Un paquet seul (sans carte) reste un simple texte JSON, comme
/// avant, et une carte PMTiles seule s'importe encore.
class EventFile {
  static const magic = [0x43, 0x54, 0x42, 0x31]; // « CTB1 »
  static const headerLength = 8;
  static const _pmtiles = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73]; // « PMTiles »

  static bool _starts(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static Future<Uint8List> _readAt(RandomAccessFile file, int at, int count) async {
    await file.setPosition(at);
    final out = Uint8List(count);
    var done = 0;
    while (done < count) {
      final n = await file.readInto(out, done, count);
      if (n <= 0) throw PacketRejected(PacketProblem.malformed, 'fichier tronqué');
      done += n;
    }
    return out;
  }

  /// Regarde le début du fichier. Lève [PacketRejected] si ce n'est rien de ce
  /// que l'appli sait lire.
  static Future<EventFileHead> readHead(File file) async {
    final length = await file.length();
    if (length == 0) throw PacketRejected(PacketProblem.malformed, 'fichier vide');
    final input = await file.open();
    try {
      final first = await _readAt(input, 0, length < headerLength ? length : headerLength);
      if (_starts(first, magic)) {
        if (length < headerLength) throw PacketRejected(PacketProblem.malformed, 'fichier tronqué');
        final packetLength = ByteData.sublistView(first).getUint32(4, Endian.big);
        if (packetLength == 0) throw PacketRejected(PacketProblem.malformed, 'paquet vide');
        if (packetLength > OrganizerPacket.maxRawLength) throw PacketRejected(PacketProblem.tooBig);
        if (headerLength + packetLength > length) {
          throw PacketRejected(PacketProblem.malformed, 'fichier tronqué');
        }
        final text = _decode(await _readAt(input, headerLength, packetLength));
        return EventFileHead(
          kind: EventFileKind.bundle,
          packetText: text,
          mapStart: headerLength + packetLength,
          mapLength: length - headerLength - packetLength,
        );
      }
      if (_starts(first, _pmtiles)) {
        return EventFileHead(kind: EventFileKind.map, mapLength: length);
      }
      if (length > OrganizerPacket.maxRawLength) {
        throw PacketRejected(PacketProblem.malformed, 'pas un fichier Cortège');
      }
      return EventFileHead(
        kind: EventFileKind.packet,
        packetText: _decode(await _readAt(input, 0, length)),
      );
    } finally {
      await input.close();
    }
  }

  static String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw PacketRejected(PacketProblem.malformed, 'texte illisible');
    }
  }

  /// Écrit le fichier d'événement : [packet] puis la carte [map].
  static Future<void> write({required String packet, required File map, required File target}) async {
    final bytes = utf8.encode(packet);
    final header = Uint8List(headerLength)
      ..setRange(0, 4, magic)
      ..buffer.asByteData().setUint32(4, bytes.length, Endian.big);
    final tmp = File('${target.path}.tmp');
    final sink = tmp.openWrite();
    try {
      sink.add(header);
      sink.add(bytes);
      await sink.addStream(map.openRead());
      await sink.flush();
      await sink.close();
      await tmp.rename(target.path);
    } on Object {
      try {
        await sink.close();
      } on Object {
        // Déjà fermé par l'échec.
      }
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }
}
