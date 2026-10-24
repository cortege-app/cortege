import 'package:flutter/services.dart';

import 'geo.dart';

/// La position vient du système Android, à la demande, une seule fois. La
/// permission est demandée à ce moment-là, pas avant. Rien n'est gardé.
class PlatformLocationProvider implements LocationProvider {
  static const _channel = MethodChannel('org.cortege.app/location');
  static const _updates = EventChannel('org.cortege.app/location_updates');

  @override
  Future<GeoPoint?> current({bool accurate = false}) async {
    try {
      final map = await _channel.invokeMapMethod<String, double>('current', {'accurate': accurate});
      if (map == null) return null;
      return GeoPoint(map['lat']!, map['lon']!, map['accuracy'] ?? 0);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<GeoPoint> updates() => _updates.receiveBroadcastStream().map((value) {
        final map = Map<String, Object?>.from(value as Map);
        return GeoPoint(
          (map['lat']! as num).toDouble(),
          (map['lon']! as num).toDouble(),
          (map['accuracy'] as num?)?.toDouble() ?? 0,
        );
      });
}
