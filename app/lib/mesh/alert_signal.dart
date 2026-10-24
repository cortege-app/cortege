import 'package:flutter/services.dart';

/// Ce qui attire l'attention de la personne quand une alerte tombe et que le
/// téléphone est dans sa poche : une vibration, sans bruit et sans notification
/// qui nommerait l'appli.
abstract class AlertSignal {
  /// Alerte pressante (un proche se tait, un blessé à proximité).
  Future<void> urgent();

  /// Information moins pressante (un medic répond).
  Future<void> notice();
}

class NoSignal implements AlertSignal {
  const NoSignal();

  @override
  Future<void> urgent() async {}

  @override
  Future<void> notice() async {}
}

class PlatformAlertSignal implements AlertSignal {
  static const _channel = MethodChannel('org.cortege.app/alerts');

  @override
  Future<void> urgent() => _vibrate(const [0, 500, 200, 500, 200, 800]);

  @override
  Future<void> notice() => _vibrate(const [0, 250, 150, 250]);

  Future<void> _vibrate(List<int> pattern) async {
    try {
      await _channel.invokeMethod<void>('vibrate', {'pattern': pattern});
    } on MissingPluginException {
      // Pas de vibreur ici (tests, autre plateforme).
    } on PlatformException {
      // Sans importance : l'alerte reste visible dans l'appli.
    }
  }
}
