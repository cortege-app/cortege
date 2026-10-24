import 'dart:isolate';
import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Les modules (carrés noirs ou blancs) d'un code QR, ligne par ligne.
class QrMatrix {
  QrMatrix(this.modules) : size = modules.length;

  final List<List<bool>> modules;
  final int size;
}

QrMatrix _encode(String text, ErrorCorrectionLevel level, int? mask) {
  final hints = EncodeHints();
  if (mask != null) hints.put(EncodeHintType.qrMaskPattern, mask);
  final matrix = Encoder.encode(text, level, hints: hints).matrix!;
  return QrMatrix([
    for (var y = 0; y < matrix.height; y++)
      [for (var x = 0; x < matrix.width; x++) matrix.get(x, y) == 1],
  ]);
}

/// Tailles de module (en pixels) auxquelles un code doit se relire. Notre lecteur
/// est capricieux : un même code peut passer à une taille et pas à la voisine,
/// et une caméra le voit à des tailles très variables.
const _checkScales = [4, 5, 6, 8];

int _readableScales(QrMatrix matrix, String text) {
  var count = 0;
  for (final scale in _checkScales) {
    final image = renderQr(matrix, moduleSize: scale);
    if (decodeQr(luminance: image.pixels, width: image.side, height: image.side) == text) {
      count++;
    }
  }
  return count;
}

/// Fabrique le QR de [text] et vérifie qu'il se relit avec notre propre
/// lecteur, à plusieurs tailles. Environ un texte sur cent donne, avec le masque
/// choisi d'office, un code que le lecteur ne retrouve pas : on essaie alors les
/// autres masques et niveaux de correction jusqu'à en trouver un qui se relit
/// partout. Si aucun n'y arrive, on garde celui qui se relit le plus souvent.
QrMatrix encodeQr(String text) {
  QrMatrix? best;
  var bestScore = -1;
  final attempts = <(ErrorCorrectionLevel, int?)>[
    (ErrorCorrectionLevel.m, null),
    for (var mask = 0; mask < 8; mask++) (ErrorCorrectionLevel.m, mask),
    (ErrorCorrectionLevel.q, null),
    (ErrorCorrectionLevel.l, null),
  ];
  for (final (level, mask) in attempts) {
    final matrix = _encode(text, level, mask);
    final score = _readableScales(matrix, text);
    if (score == _checkScales.length) return matrix;
    if (score > bestScore) {
      best = matrix;
      bestScore = score;
    }
  }
  return best!;
}

/// Lit un code QR dans une image en niveaux de gris ([luminance] : un octet par
/// pixel, ligne après ligne, sans remplissage). Renvoie null s'il n'y en a
/// pas. Tout se passe dans l'appli : aucune bibliothèque tierce de lecture,
/// aucun service de Google.
String? decodeQr({
  required Uint8List luminance,
  required int width,
  required int height,
}) {
  if (luminance.length < width * height) return null;
  final pixels = Int32List(width * height);
  for (var i = 0; i < pixels.length; i++) {
    final y = luminance[i];
    pixels[i] = 0xFF000000 | (y << 16) | (y << 8) | y;
  }
  final source = RGBLuminanceSource(width, height, pixels);
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  // Trois lectures, de la plus fine à la plus tolérante : seuil local (reflets
  // sur un écran), seuil global, puis image inversée.
  final attempts = <BinaryBitmap Function()>[
    () => BinaryBitmap(HybridBinarizer(source)),
    () => BinaryBitmap(GlobalHistogramBinarizer(source)),
    () => BinaryBitmap(HybridBinarizer(InvertedLuminanceSource(source))),
  ];
  for (final attempt in attempts) {
    try {
      return QRCodeReader().decode(attempt(), hints: hints).text;
    } on ReaderException {
      continue;
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Comme [decodeQr], dans un autre isolate pour ne pas figer l'interface.
///
/// Fonction hors de toute classe exprès : une fermeture créée dans une méthode
/// d'un widget emporte le widget avec elle, et Dart refuse alors de l'envoyer
/// à l'autre isolate (« unsendable »). L'erreur qui en résultait avalait chaque
/// lecture de la caméra sans rien dire.
Future<String?> decodeQrInBackground({
  required Uint8List luminance,
  required int width,
  required int height,
}) =>
    Isolate.run(() => decodeQr(luminance: luminance, width: width, height: height));

/// Dessine [matrix] en niveaux de gris avec une marge blanche, pour les tests
/// et pour vérifier qu'un QR généré se relit.
({Uint8List pixels, int side}) renderQr(QrMatrix matrix, {int moduleSize = 6, int quiet = 4}) {
  final side = (matrix.size + 2 * quiet) * moduleSize;
  final pixels = Uint8List(side * side)..fillRange(0, side * side, 255);
  for (var my = 0; my < matrix.size; my++) {
    for (var mx = 0; mx < matrix.size; mx++) {
      if (!matrix.modules[my][mx]) continue;
      for (var dy = 0; dy < moduleSize; dy++) {
        final row = ((my + quiet) * moduleSize + dy) * side;
        for (var dx = 0; dx < moduleSize; dx++) {
          pixels[row + (mx + quiet) * moduleSize + dx] = 0;
        }
      }
    }
  }
  return (pixels: pixels, side: side);
}
