import 'dart:convert';
import 'dart:typed_data';

import 'names.dart';

/// Le QR d'un proche pour un binôme : ce qu'il faut pour rejoindre son binôme
/// et pour lire ses prochains messages. Chaque personne montre le sien, les
/// autres le scannent.
///
/// La chaîne de clés qu'il contient est celle de l'instant : celui qui scanne
/// ne peut lire que les messages à venir, jamais ceux déjà envoyés.
class BuddyInvite {
  BuddyInvite({
    required this.binomeId,
    required this.eventSecret,
    required this.tagKey,
    required this.name,
    required this.signPublic,
    required this.chainKey,
    required this.chainIndex,
    this.medicPublicKey,
  }) {
    if (binomeId.length != 8 ||
        eventSecret.length != 32 ||
        tagKey.length != 32 ||
        signPublic.length != 32 ||
        chainKey.length != 32 ||
        (medicPublicKey != null && medicPublicKey!.length != 32)) {
      throw const FormatException('tailles de clés invalides');
    }
    final bytes = utf8.encode(name);
    if (bytes.isEmpty || bytes.length > maxNameBytes) {
      throw const FormatException('pseudo vide ou trop long');
    }
  }

  static const prefix = 'CORTEGEB1.';
  static const maxNameBytes = 24;
  static const _version = 1;

  final Uint8List binomeId;
  final Uint8List eventSecret;
  final Uint8List tagKey;
  final String name;
  final Uint8List signPublic;
  final Uint8List chainKey;
  final int chainIndex;
  final Uint8List? medicPublicKey;

  String encode() {
    final nameBytes = utf8.encode(name);
    final raw = BytesBuilder(copy: false)
      ..addByte(_version)
      ..addByte(medicPublicKey == null ? 0 : 1)
      ..add(binomeId)
      ..add(eventSecret)
      ..add(tagKey)
      ..add(signPublic)
      ..add(chainKey)
      ..add((ByteData(4)..setUint32(0, chainIndex)).buffer.asUint8List())
      ..addByte(nameBytes.length)
      ..add(nameBytes);
    if (medicPublicKey != null) raw.add(medicPublicKey!);
    return prefix + base64Url.encode(raw.toBytes()).replaceAll('=', '');
  }

  factory BuddyInvite.decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const FormatException('ce QR n\'est pas un code de binôme Cortège');
    }
    final Uint8List raw;
    try {
      raw = base64Url.decode(base64Url.normalize(trimmed.substring(prefix.length)));
    } on FormatException {
      throw const FormatException('code illisible');
    }
    const fixed = 2 + 8 + 32 + 32 + 32 + 32 + 4 + 1;
    if (raw.length < fixed || raw[0] != _version) {
      throw const FormatException('code d\'une version inconnue');
    }
    final hasMedic = raw[1] & 1 == 1;
    final nameLength = raw[fixed - 1];
    final expected = fixed + nameLength + (hasMedic ? 32 : 0);
    if (raw.length != expected) throw const FormatException('code tronqué');
    var offset = 2;
    Uint8List take(int count) {
      final out = Uint8List.fromList(raw.sublist(offset, offset + count));
      offset += count;
      return out;
    }

    final binomeId = take(8);
    final eventSecret = take(32);
    final tagKey = take(32);
    final signPublic = take(32);
    final chainKey = take(32);
    final chainIndex = ByteData.sublistView(take(4)).getUint32(0);
    offset += 1; // longueur du pseudo, déjà lue
    final String name;
    try {
      name = cleanName(utf8.decode(take(nameLength)));
    } on FormatException {
      throw const FormatException('pseudo illisible');
    }
    return BuddyInvite(
      binomeId: binomeId,
      eventSecret: eventSecret,
      tagKey: tagKey,
      name: name,
      signPublic: signPublic,
      chainKey: chainKey,
      chainIndex: chainIndex,
      medicPublicKey: hasMedic ? take(32) : null,
    );
  }
}
