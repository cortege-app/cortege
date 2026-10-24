import 'dart:async';

import 'package:cortege/mesh/alert_signal.dart';
import 'package:cortege/mesh/compass.dart';
import 'package:cortege/mesh/geo.dart';
import 'package:cortege/mesh/torch.dart';

/// Une position qu'on règle à la main.
class FakeLocation implements LocationProvider {
  FakeLocation([this.point]);

  GeoPoint? point;
  var calls = 0;

  bool? lastAccurate;

  /// Les positions qu'un écran qui suit un déplacement recevra.
  final updatesController = StreamController<GeoPoint>.broadcast(sync: true);

  @override
  Stream<GeoPoint> updates() => updatesController.stream;

  @override
  Future<GeoPoint?> current({bool accurate = false}) async {
    lastAccurate = accurate;
    calls++;
    return point;
  }
}

/// Compte les vibrations au lieu de les produire.
class CountingSignal implements AlertSignal {
  var urgentCount = 0;
  var noticeCount = 0;

  @override
  Future<void> urgent() async => urgentCount++;

  @override
  Future<void> notice() async => noticeCount++;
}

/// Une boussole qu'on pilote à la main : chaque `turn` envoie un cap.
class FakeCompass implements CompassProvider {
  final _controller = StreamController<double>.broadcast();
  GeoPoint? askedAt;

  void turn(double degrees) => _controller.add(degrees);

  void breakDown() => _controller.addError(StateError('pas de capteur'));

  @override
  Stream<double> headings(GeoPoint at) {
    askedAt = at;
    return _controller.stream;
  }
}

/// Une lampe qui note ce qu'on lui demande.
class FakeTorch implements Torch {
  final calls = <bool>[];

  bool get isOn => calls.isNotEmpty && calls.last;

  @override
  Future<bool> set(bool on) async {
    calls.add(on);
    return true;
  }
}
