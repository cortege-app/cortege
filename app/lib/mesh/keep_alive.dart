import 'package:flutter/services.dart';

/// Garde l'appli en vie quand elle passe en arrière-plan (service au premier
/// plan d'Android, avec une notification). Sans lui, Android arrête l'appli et
/// le maillage avec elle quelques minutes après l'extinction de l'écran.
abstract class KeepAlive {
  Future<void> start();

  Future<void> stop();
}

class PlatformKeepAlive implements KeepAlive {
  static const _channel = MethodChannel('org.cortege.app/keepalive');

  @override
  Future<void> start() => _call('start');

  @override
  Future<void> stop() => _call('stop');

  Future<void> _call(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Plateforme sans service au premier plan (iOS, tests).
    } on PlatformException {
      // Le maillage marche sans, seulement tant que l'appli est visible.
    }
  }
}
