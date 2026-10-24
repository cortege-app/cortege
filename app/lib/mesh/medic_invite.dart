import 'dart:convert';
import 'dart:typed_data';

/// Le QR que s'échangent les medics : il donne accès au canal des alertes. À ne
/// remettre qu'à des medics connus. Quiconque le scanne lit toutes les alertes,
/// avec leurs positions approximatives.
class MedicInvite {
  MedicInvite({
    required this.eventSecret,
    required this.publicKey,
    required this.secretKey,
  }) {
    if (eventSecret.length != 32 || publicKey.length != 32 || secretKey.length != 32) {
      throw const FormatException('clés de 32 octets attendues');
    }
  }

  static const prefix = 'CORTEGEM1.';
  static const _version = 1;

  final Uint8List eventSecret;
  final Uint8List publicKey;
  final Uint8List secretKey;

  String encode() => prefix +
      base64Url
          .encode(
            (BytesBuilder(copy: false)
                  ..addByte(_version)
                  ..add(eventSecret)
                  ..add(publicKey)
                  ..add(secretKey))
                .toBytes(),
          )
          .replaceAll('=', '');

  factory MedicInvite.decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const FormatException('ce QR n\'est pas un code de medic Cortège');
    }
    final Uint8List raw;
    try {
      raw = base64Url.decode(base64Url.normalize(trimmed.substring(prefix.length)));
    } on FormatException {
      throw const FormatException('code illisible');
    }
    if (raw.length != 1 + 32 * 3 || raw[0] != _version) {
      throw const FormatException('code d\'une version inconnue');
    }
    return MedicInvite(
      eventSecret: Uint8List.fromList(raw.sublist(1, 33)),
      publicKey: Uint8List.fromList(raw.sublist(33, 65)),
      secretKey: Uint8List.fromList(raw.sublist(65, 97)),
    );
  }
}
