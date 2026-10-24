import 'package:flutter/services.dart';

/// La lampe du téléphone, pour se faire repérer à vue. Android ne demande pas
/// d'autorisation pour l'allumer.
abstract class Torch {
  /// Allume ou éteint. Faux si le téléphone n'a pas de lampe ou la refuse.
  Future<bool> set(bool on);
}

class NoTorch implements Torch {
  const NoTorch();

  @override
  Future<bool> set(bool on) async => false;
}

class PlatformTorch implements Torch {
  const PlatformTorch();

  static const _channel = MethodChannel('org.cortege.app/torch');

  @override
  Future<bool> set(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('set', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
