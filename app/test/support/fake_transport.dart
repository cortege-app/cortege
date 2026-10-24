import 'dart:async';
import 'dart:typed_data';

import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_node.dart';
import 'package:cortege/mesh/proximity.dart';
import 'package:cortege/mesh/transport.dart';

/// Un faux espace radio : deux téléphones se voient s'ils sont dans le même
/// événement (même identifiant GATT, donc même secret), comme en vrai.
class FakeAir {
  final transports = <FakeTransport>[];

  void join(FakeTransport joining) {
    for (final other in transports) {
      if (other.event == joining.event && other.events != null) {
        other._linkTo(joining);
        joining._linkTo(other);
      }
    }
    transports.add(joining);
  }

  void leave(FakeTransport leaving) {
    transports.remove(leaving);
    for (final other in transports) {
      other.events?.onLinkDown('vers-${leaving.name}');
    }
  }
}

class FakeTransport implements MeshTransport {
  FakeTransport(this.air, this.name, {this.unavailable = false, this.retryable = true});

  final FakeAir air;
  final String name;
  bool unavailable;
  bool retryable;
  MeshTransportEvents? events;
  String? event;
  var startCount = 0;
  var stopCount = 0;

  bool get running => events != null;

  @override
  Future<void> start(EventKeys keys, MeshTransportEvents events) async {
    if (unavailable) throw MeshTransportUnavailable('Bluetooth éteint', retryable: retryable);
    startCount++;
    this.events = events;
    event = keys.gattService.join(',');
    air.join(this);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    air.leave(this);
    events = null;
    event = null;
  }

  /// La balise que ce téléphone annonce, s'il y en a une.
  Uint8List? beacon;
  final proximityController = StreamController<ProximityReading>.broadcast(sync: true);

  /// Android refuse l'annonce avec la balise.
  var refuseBeacon = false;

  @override
  Future<bool> setBeacon(Uint8List? beacon) async {
    if (beacon != null && refuseBeacon) return false;
    this.beacon = beacon == null ? null : Uint8List.fromList(beacon);
    return true;
  }

  @override
  Stream<ProximityReading> get proximity => proximityController.stream;

  /// Ce téléphone entend la balise [beacon] avec ce signal.
  void hear(Uint8List beacon, int rssi) =>
      proximityController.add(ProximityReading(beacon, rssi));

  /// Le Bluetooth s'éteint en cours de route : la radio s'arrête sans que le
  /// moteur l'ait demandé, et les voisins perdent le lien.
  void failNow(String reason, {bool retryable = true}) {
    final listening = events;
    if (listening == null) return;
    air.leave(this);
    listening.onFailure(reason, retryable);
  }

  void _linkTo(FakeTransport target) {
    events!.onLinkUp(_FakeLink(this, target));
  }
}

class _FakeLink implements MeshLink {
  _FakeLink(this.from, this.to);

  final FakeTransport from;
  final FakeTransport to;

  @override
  String get id => 'vers-${to.name}';

  @override
  Future<void> send(Uint8List frame) async {
    to.events?.onFrame('de-${from.name}', frame);
  }
}
