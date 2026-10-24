import 'dart:io';

import 'package:flutter/services.dart';

/// La copie du fichier d'installation de l'appli, prête à être envoyée.
class AppPackage {
  const AppPackage(this.file, this.size);

  final File file;
  final int size;
}

/// L'appli ne peut pas se préparer à être envoyée.
class AppShareException implements Exception {
  AppShareException(this.message);

  final String message;

  @override
  String toString() => 'AppShareException($message)';
}

/// Passer l'appli de téléphone à téléphone, sans internet : l'appli copie son
/// propre fichier d'installation et laisse la personne choisir comment l'envoyer
/// (Bluetooth, Quick Share, clé USB...). C'est Android qui envoie, l'appli ne
/// touche à aucun réseau.
abstract class AppSharer {
  /// Copie le fichier d'installation dans un dossier prêté le temps de l'envoi.
  /// Lève [AppShareException] si ce n'est pas possible.
  Future<AppPackage> prepare();

  /// Ouvre la feuille de partage d'Android avec la copie. Faux si elle n'a pas
  /// pu s'ouvrir.
  Future<bool> send();
}

class NoAppSharer implements AppSharer {
  const NoAppSharer();

  @override
  Future<AppPackage> prepare() async =>
      throw AppShareException('Le partage de l\'appli n\'est pas disponible ici.');

  @override
  Future<bool> send() async => false;
}

class PlatformAppSharer implements AppSharer {
  const PlatformAppSharer();

  static const _channel = MethodChannel('org.cortege.app/share');

  @override
  Future<AppPackage> prepare() async {
    final Map<String, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<String, Object?>('prepare');
    } on MissingPluginException {
      throw AppShareException('Le partage de l\'appli n\'est pas disponible ici.');
    } on PlatformException {
      throw AppShareException('L\'appli n\'a pas pu se copier.');
    }
    final error = result?['error'];
    if (error == 'split') {
      throw AppShareException(
        'Cette installation est en plusieurs morceaux : son fichier ne s\'installerait pas chez l\'autre personne.',
      );
    }
    final path = result?['path'];
    final size = result?['size'];
    if (error != null || path is! String || size is! int) {
      throw AppShareException('L\'appli n\'a pas pu se copier.');
    }
    return AppPackage(File(path), size);
  }

  @override
  Future<bool> send() async {
    try {
      return await _channel.invokeMethod<bool>('send') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
