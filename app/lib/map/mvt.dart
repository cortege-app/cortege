import 'dart:convert';
import 'dart:typed_data';

/// Le contenu d'une tuile vectorielle n'est pas lisible.
class MvtException implements Exception {
  MvtException(this.message);

  final String message;

  @override
  String toString() => 'MvtException($message)';
}

enum MvtGeometry { point, line, polygon }

/// Un objet de la carte : un point (un lieu), une ligne (une route, une rivière)
/// ou une surface (un bâtiment, un parc), avec ses propriétés (`kind`, `name`...).
class MvtFeature {
  MvtFeature(this.type, this.props, this.parts);

  final MvtGeometry type;
  final Map<String, Object> props;

  /// Points : une suite de (x, y) par point isolé. Lignes : une ligne par
  /// élément. Surfaces : un anneau par élément (le premier est le contour, les
  /// suivants les trous ; on les dessine tous ensemble en « pair-impair »).
  /// Les coordonnées vont de 0 à l'`extent` de la couche, y vers le bas.
  final List<Float32List> parts;

  String? get kind => props['kind'] as String?;
  String? get name => props['name'] as String?;
}

class MvtLayer {
  MvtLayer(this.name, this.extent, this.features);

  final String name;
  final int extent;
  final List<MvtFeature> features;
}

class MvtTile {
  MvtTile(this.layers);

  final Map<String, MvtLayer> layers;

  MvtLayer? operator [](String name) => layers[name];
}

class _Reader {
  _Reader(this.bytes, [this.position = 0, int? end]) : end = end ?? bytes.length;

  final Uint8List bytes;
  int position;
  final int end;

  bool get done => position >= end;

  /// Vérifie qu'il reste [count] octets à lire dans ce champ.
  void require(int count) {
    if (position + count > end) throw MvtException('fin inattendue');
  }

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (position >= end) throw MvtException('fin inattendue');
      final byte = bytes[position++];
      if (shift < 64) result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
      if (shift > 70) throw MvtException('entier trop long');
    }
  }

  /// Un champ « longueur + octets » : renvoie le lecteur de son contenu.
  _Reader bytesField() {
    final length = varint();
    if (length < 0 || position + length > end) throw MvtException('champ trop long');
    final inner = _Reader(bytes, position, position + length);
    position += length;
    return inner;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        position += 8;
      case 2:
        bytesField();
      case 5:
        position += 4;
      default:
        throw MvtException('type de champ $wireType inconnu');
    }
    if (position > end) throw MvtException('fin inattendue');
  }
}

/// Les tuiles portent le nom de chaque lieu dans des dizaines de langues
/// (`name:ja`, `name:ar`...) : on ne garde que `name` et les propriétés sans deux
/// points, ce qui divise la mémoire par plusieurs fois.
bool _wanted(String key) => !key.contains(':') && key != 'wikidata';

int _zigzag(int value) => (value >> 1) ^ -(value & 1);

/// Une tuile de ville en contient quelques milliers par couche ; au-delà de
/// cette limite, la tuile est abîmée ou piégée.
const maxFeaturesPerLayer = 400000;

/// Décode une tuile vectorielle (format Mapbox Vector Tile 2.1) déjà décompressée.
MvtTile decodeMvt(Uint8List bytes) {
  final reader = _Reader(bytes);
  final layers = <String, MvtLayer>{};
  while (!reader.done) {
    final tag = reader.varint();
    if (tag >> 3 == 3 && tag & 7 == 2) {
      final layer = _decodeLayer(reader.bytesField());
      // Deux couches du même nom : on garde la première, comme le font les
      // lecteurs courants.
      layers.putIfAbsent(layer.name, () => layer);
    } else {
      reader.skip(tag & 7);
    }
  }
  return MvtTile(layers);
}

MvtLayer _decodeLayer(_Reader reader) {
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <Object>[];
  final rawFeatures = <_Reader>[];
  while (!reader.done) {
    final tag = reader.varint();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1 when wire == 2:
        final inner = reader.bytesField();
        name = utf8.decode(Uint8List.sublistView(inner.bytes, inner.position, inner.end), allowMalformed: true);
      case 2 when wire == 2:
        rawFeatures.add(reader.bytesField());
      case 3 when wire == 2:
        final inner = reader.bytesField();
        keys.add(utf8.decode(Uint8List.sublistView(inner.bytes, inner.position, inner.end), allowMalformed: true));
      case 4 when wire == 2:
        values.add(_decodeValue(reader.bytesField()));
      case 5 when wire == 0:
        extent = reader.varint();
        // L'étendue sert de diviseur au dessin : zéro ou une valeur absurde
        // donneraient des dimensions infinies.
        if (extent < 16 || extent > 65536) throw MvtException('étendue de couche absurde ($extent)');
      default:
        reader.skip(wire);
    }
    if (rawFeatures.length > maxFeaturesPerLayer) throw MvtException('trop d\'objets dans une couche');
  }
  final features = <MvtFeature>[];
  for (final raw in rawFeatures) {
    final feature = _decodeFeature(raw, keys, values);
    if (feature != null) features.add(feature);
  }
  return MvtLayer(name, extent, features);
}

Object _decodeValue(_Reader reader) {
  Object result = '';
  while (!reader.done) {
    final tag = reader.varint();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 1 when wire == 2:
        final inner = reader.bytesField();
        result = utf8.decode(Uint8List.sublistView(inner.bytes, inner.position, inner.end), allowMalformed: true);
      case 2 when wire == 5:
        reader.require(4);
        result = ByteData.sublistView(reader.bytes, reader.position, reader.position + 4)
            .getFloat32(0, Endian.little);
        reader.position += 4;
      case 3 when wire == 1:
        reader.require(8);
        result = ByteData.sublistView(reader.bytes, reader.position, reader.position + 8)
            .getFloat64(0, Endian.little);
        reader.position += 8;
      case 4 when wire == 0:
      case 5 when wire == 0:
        result = reader.varint();
      case 6 when wire == 0:
        result = _zigzag(reader.varint());
      case 7 when wire == 0:
        result = reader.varint() != 0;
      default:
        reader.skip(wire);
    }
  }
  return result;
}

MvtFeature? _decodeFeature(_Reader reader, List<String> keys, List<Object> values) {
  var type = 0;
  final props = <String, Object>{};
  _Reader? geometry;
  while (!reader.done) {
    final tag = reader.varint();
    final wire = tag & 7;
    switch (tag >> 3) {
      case 2 when wire == 2:
        final tags = reader.bytesField();
        while (!tags.done) {
          final key = tags.varint();
          if (tags.done) break;
          final value = tags.varint();
          if (key >= 0 && value >= 0 && key < keys.length && value < values.length && _wanted(keys[key])) {
            props[keys[key]] = values[value];
          }
        }
      case 3 when wire == 0:
        type = reader.varint();
      case 4 when wire == 2:
        geometry = reader.bytesField();
      default:
        reader.skip(wire);
    }
  }
  if (geometry == null || type < 1 || type > 3) return null;
  final kind = MvtGeometry.values[type - 1];
  return MvtFeature(kind, props, _decodeGeometry(geometry, kind));
}

List<Float32List> _decodeGeometry(_Reader reader, MvtGeometry kind) {
  final parts = <Float32List>[];
  var x = 0;
  var y = 0;
  var current = <double>[];

  void finish() {
    if (current.isNotEmpty) parts.add(Float32List.fromList(current));
    current = <double>[];
  }

  while (!reader.done) {
    final command = reader.varint();
    final id = command & 7;
    final count = command >> 3;
    switch (id) {
      case 1: // MoveTo
        for (var i = 0; i < count; i++) {
          x += _zigzag(reader.varint());
          y += _zigzag(reader.varint());
          if (kind == MvtGeometry.point) {
            parts.add(Float32List.fromList([x.toDouble(), y.toDouble()]));
          } else {
            finish();
            current.addAll([x.toDouble(), y.toDouble()]);
          }
        }
      case 2: // LineTo
        for (var i = 0; i < count; i++) {
          x += _zigzag(reader.varint());
          y += _zigzag(reader.varint());
          current.addAll([x.toDouble(), y.toDouble()]);
        }
      case 7: // ClosePath
        finish();
      default:
        throw MvtException('commande de géométrie $id inconnue');
    }
  }
  finish();
  return parts;
}
