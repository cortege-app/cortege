import 'package:flutter/services.dart';

/// Monte la luminosité de l'écran au maximum le temps d'afficher un QR, puis
/// rend la main au réglage du téléphone.
class ScreenBrightness {
  static const _channel = MethodChannel('org.cortege.app/screen');

  static Future<void> max({required bool on}) async {
    try {
      await _channel.invokeMethod<void>('maxBrightness', {'on': on});
    } on MissingPluginException {
      // Pas de réglage possible ici (tests, autre plateforme).
    } on PlatformException {
      // Sans importance : le QR reste affiché.
    }
  }
}
