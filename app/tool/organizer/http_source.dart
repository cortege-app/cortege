import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/map/byte_source.dart';

/// Un fichier distant lu par morceaux (en-tête HTTP « Range »), pour extraire
/// une zone d'une carte du monde sans la télécharger en entier.
///
/// Ce fichier vit dans `tool/` et pas dans `lib/` : c'est l'outil de
/// l'organisateur, sur son ordinateur, qui parle au réseau. L'appli n'en contient
/// aucune ligne, et `test/no_network_test.dart` continue de le vérifier.
class HttpRangeSource implements ByteSource {
  HttpRangeSource._(this._client, this._url, this.length);

  final HttpClient _client;
  final Uri _url;

  @override
  final int length;

  /// Une adresse http(s) est lue en ligne ; autre chose est un fichier de cet
  /// ordinateur (une carte du monde déjà téléchargée, par exemple).
  static Future<ByteSource> openSource(String where) {
    final lower = where.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return open(where);
    return FileByteSource.open(File(where));
  }

  static Future<HttpRangeSource> open(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 206) {
        throw HttpException(
          'le serveur répond ${response.statusCode}, pas la lecture par morceaux attendue',
          uri: uri,
        );
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final total = int.tryParse(range?.split('/').last ?? '');
      if (total == null) throw HttpException('taille du fichier inconnue', uri: uri);
      return HttpRangeSource._(client, uri, total);
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) {
      throw RangeError('lecture hors du fichier : $offset + $count sur $length');
    }
    if (count == 0) return Uint8List(0);
    Object? last;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final request = await _client.getUrl(_url);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + count - 1}');
        final response = await request.close();
        if (response.statusCode != 206) {
          await response.drain<void>();
          throw HttpException('le serveur répond ${response.statusCode}', uri: _url);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          // Un serveur qui renvoie plus que demandé ne doit pas remplir la mémoire.
          if (bytes.length + chunk.length > count) {
            throw HttpException('le serveur renvoie plus que demandé', uri: _url);
          }
          bytes.add(chunk);
        }
        final result = bytes.takeBytes();
        if (result.length != count) {
          throw HttpException('reçu ${result.length} octets au lieu de $count', uri: _url);
        }
        return result;
      } on Object catch (error) {
        last = error;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    throw last!;
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
