import 'dart:typed_data';

import 'group.dart';
import 'mesh_node.dart';
import 'proximity.dart';

void _ignoreFailure(String reason, bool retryable) {}

/// Ce que la couche radio remonte au moteur du maillage.
class MeshTransportEvents {
  const MeshTransportEvents({
    required this.onFrame,
    required this.onLinkUp,
    required this.onLinkDown,
    this.onFailure = _ignoreFailure,
  });

  /// Une trame complète est arrivée du voisin [sourceId].
  final void Function(String sourceId, Uint8List frame) onFrame;

  /// Un voisin devient joignable : on peut lui envoyer des trames.
  final void Function(MeshLink link) onLinkUp;

  final void Function(String linkId) onLinkDown;

  /// La radio s'est arrêtée toute seule (Bluetooth éteint pendant l'usage,
  /// permission retirée). Le moteur la relance quand c'est possible.
  final void Function(String reason, bool retryable) onFailure;
}

/// La couche radio (Bluetooth). Elle annonce notre présence, cherche les
/// voisins de l'événement et transporte des trames, rien de plus : elle ne
/// connaît ni les groupes ni les messages.
abstract class MeshTransport {
  /// Lève [MeshTransportUnavailable] si la radio n'est pas utilisable
  /// (Bluetooth éteint, permission refusée).
  Future<void> start(EventKeys keys, MeshTransportEvents events);

  Future<void> stop();

  /// Ajoute une balise (5 octets) à l'annonce Bluetooth, ou la retire (null).
  /// Elle sert à un medic qui cherche la personne qui a lancé une alerte. Rend
  /// faux si Android a refusé l'annonce avec la balise ; l'annonce normale est
  /// alors remise sans elle, le téléphone ne disparaît pas du maillage.
  Future<bool> setBeacon(Uint8List? beacon);

  /// Les balises entendues, avec la force de leur signal.
  Stream<ProximityReading> get proximity;
}

class MeshTransportUnavailable implements Exception {
  MeshTransportUnavailable(this.reason, {this.retryable = false});

  final String reason;

  /// Vrai si ça peut s'arranger tout seul (Bluetooth rallumé, radio qui ne
  /// répondait pas) : le maillage réessaie alors régulièrement. Faux pour une
  /// permission refusée, qu'on ne redemande pas en boucle.
  final bool retryable;

  @override
  String toString() => 'MeshTransportUnavailable($reason)';
}
