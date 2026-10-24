import 'dart:io';

import 'package:flutter/services.dart';

/// Un fichier choisi par l'utilisateur, copié dans le dossier privé de l'appli :
/// l'appli ne garde aucun accès au reste du stockage.
class PickedFile {
  const PickedFile(this.file, this.name);

  final File file;

  /// Le nom d'origine, pour l'afficher.
  final String name;
}

/// Choix d'un fichier d'événement. Sur Android : le sélecteur du système, sans
/// autorisation de stockage, ou le fichier qu'une autre appli (messagerie,
/// gestionnaire de fichiers) vient d'ouvrir avec Cortège.
abstract class FilePicker {
  /// Null si l'utilisateur annule.
  Future<PickedFile?> pick();

  /// Le fichier qu'une autre appli a ouvert avec Cortège, une seule fois. Null
  /// s'il n'y en a pas.
  Future<PickedFile?> takeIncoming();

  /// Supprime les copies temporaires qu'un choix précédent aurait laissées. Avec
  /// [all], aussi les fichiers reçus qui n'ont pas encore été pris.
  Future<void> clean({bool all = false});
}

class NoFilePicker implements FilePicker {
  const NoFilePicker();

  @override
  Future<PickedFile?> pick() async => null;

  @override
  Future<PickedFile?> takeIncoming() async => null;

  @override
  Future<void> clean({bool all = false}) async {}
}

class PlatformFilePicker implements FilePicker {
  const PlatformFilePicker();

  static const _channel = MethodChannel('org.cortege.app/files');

  Future<PickedFile?> _call(String method) async {
    try {
      final result = await _channel.invokeMapMethod<String, String>(method);
      if (result == null) return null;
      final path = result['path'];
      if (path == null) return null;
      return PickedFile(File(path), result['name'] ?? 'fichier');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<PickedFile?> pick() => _call('pick');

  @override
  Future<PickedFile?> takeIncoming() => _call('incoming');

  @override
  Future<void> clean({bool all = false}) async {
    try {
      await _channel.invokeMethod<void>('clean', {'all': all});
    } on MissingPluginException {
      // Rien à nettoyer ici.
    } on PlatformException {
      // Sans importance.
    }
  }
}
