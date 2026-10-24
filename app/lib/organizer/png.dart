import 'dart:io';
import 'dart:typed_data';

/// Écrit une image en niveaux de gris au format PNG, sans bibliothèque : de quoi
/// sauver le code QR d'un organisateur pour l'imprimer.
Uint8List encodeGrayPng(Uint8List pixels, int width, int height) {
  if (pixels.length != width * height) throw ArgumentError('taille de pixels incohérente');
  // Chaque ligne commence par un octet de filtre (0 : aucun).
  final raw = Uint8List(height * (width + 1));
  for (var y = 0; y < height; y++) {
    raw[y * (width + 1)] = 0;
    raw.setRange(y * (width + 1) + 1, (y + 1) * (width + 1), pixels, y * width);
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  void chunk(String type, List<int> data) {
    final length = ByteData(4)..setUint32(0, data.length);
    out.add(length.buffer.asUint8List());
    final body = Uint8List.fromList([...type.codeUnits, ...data]);
    out.add(body);
    final crc = ByteData(4)..setUint32(0, _crc32(body));
    out.add(crc.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // 8 bits par pixel
    ..setUint8(9, 0) // niveaux de gris
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibCodec(level: 6).encode(raw));
  chunk('IEND', const []);
  return out.toBytes();
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
