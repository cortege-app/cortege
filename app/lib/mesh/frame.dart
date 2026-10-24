import 'dart:typed_data';

/// Trame du maillage, telle qu'elle voyage de téléphone en téléphone.
///
///     octet 0        version (1)
///     octet 1        sauts restants (TTL)
///     octets 2 à 17  étiquette du groupe (change toutes les heures)
///     octets 18...   nonce (24 octets) puis contenu chiffré avec son tag
///
/// Un relais qui n'est pas dans le groupe ne voit que ça : il transporte sans
/// pouvoir lire. Le TTL doit rester lisible et change à chaque saut, donc il
/// n'est pas couvert par l'authentification : un relais hostile peut le
/// gonfler. Les récepteurs le plafonnent.
class Frame {
  Frame({required this.ttl, required this.groupTag, required this.sealed}) {
    if (groupTag.length != tagLength) {
      throw ArgumentError('étiquette de $tagLength octets attendue');
    }
  }

  static const version = 1;
  static const tagLength = 16;
  static const headerLength = 2 + tagLength;

  /// Au-delà, une trame est rejetée sans être lue (protège la mémoire).
  static const maxLength = 1024;

  final int ttl;
  final Uint8List groupTag;

  /// Nonce puis chiffré. Pas touché par les relais.
  final Uint8List sealed;

  /// Données authentifiées avec le chiffré : tout sauf le TTL.
  Uint8List get associatedData =>
      Uint8List.fromList([version, ...groupTag]);

  Frame withTtl(int newTtl) =>
      Frame(ttl: newTtl, groupTag: groupTag, sealed: sealed);

  Uint8List encode() => (BytesBuilder(copy: false)
        ..addByte(version)
        ..addByte(ttl)
        ..add(groupTag)
        ..add(sealed))
      .toBytes();

  /// Null si la trame n'a pas le bon format. Ne lève jamais : une trame
  /// étrangère est un cas normal, pas une erreur.
  static Frame? parse(Uint8List bytes, {required int minSealedLength}) {
    if (bytes.length > maxLength) return null;
    if (bytes.length < headerLength + minSealedLength) return null;
    if (bytes[0] != version) return null;
    return Frame(
      ttl: bytes[1],
      groupTag: Uint8List.fromList(bytes.sublist(2, headerLength)),
      sealed: Uint8List.fromList(bytes.sublist(headerLength)),
    );
  }
}

/// Une connexion Bluetooth transporte un flux d'octets : chaque trame est
/// précédée de sa longueur sur deux octets, puis découpée en morceaux qui
/// tiennent dans une écriture. Les écritures arrivent dans l'ordre, ce qui
/// suffit à recoller les morceaux.
Uint8List withLength(Uint8List frame) {
  final out = Uint8List(2 + frame.length);
  ByteData.sublistView(out).setUint16(0, frame.length);
  out.setRange(2, out.length, frame);
  return out;
}

List<Uint8List> chunksOf(Uint8List data, int maxWrite) {
  if (maxWrite <= 0) throw ArgumentError('taille d\'écriture invalide');
  return [
    for (var i = 0; i < data.length; i += maxWrite)
      Uint8List.sublistView(data, i, i + maxWrite > data.length ? data.length : i + maxWrite),
  ];
}

class FrameStreamError implements Exception {
  FrameStreamError(this.message);

  final String message;

  @override
  String toString() => 'FrameStreamError($message)';
}

/// Recolle les morceaux reçus d'un même voisin. Lève [FrameStreamError] si le
/// flux n'a pas de sens (longueur annoncée absurde) : l'appelant coupe alors
/// la connexion.
class FrameAssembler {
  var _pending = Uint8List(0);

  List<Uint8List> add(Uint8List chunk) {
    if (_pending.isEmpty) {
      _pending = Uint8List.fromList(chunk);
    } else {
      _pending = (BytesBuilder(copy: false)
            ..add(_pending)
            ..add(chunk))
          .toBytes();
    }
    final frames = <Uint8List>[];
    while (_pending.length >= 2) {
      final length = ByteData.sublistView(_pending).getUint16(0);
      if (length == 0 || length > Frame.maxLength) {
        _pending = Uint8List(0);
        throw FrameStreamError('longueur de trame invalide : $length');
      }
      if (_pending.length < 2 + length) break;
      frames.add(Uint8List.fromList(_pending.sublist(2, 2 + length)));
      _pending = Uint8List.fromList(_pending.sublist(2 + length));
    }
    if (_pending.length > 2 + Frame.maxLength) {
      _pending = Uint8List(0);
      throw FrameStreamError('trop de données sans trame complète');
    }
    return frames;
  }

  void clear() => _pending = Uint8List(0);
}
