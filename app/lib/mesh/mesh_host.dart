import 'dart:typed_data';

import '../vault/vault_store.dart';
import 'mesh_crypto.dart';
import 'mesh_node.dart';
import 'proximity.dart';

/// Ce que les services du maillage (binôme, medics) attendent de leur hôte,
/// le [MeshController] : un accès au coffre, au moteur et à la radio.
abstract class MeshHost {
  MeshCrypto get crypto;

  VaultSession get session;

  MeshNode get node;

  DateTime now();

  /// Vrai quand la radio tourne : sinon il est inutile d'émettre.
  bool get transportRunning;

  /// Enregistre le coffre sans bloquer : l'état d'un binôme change à chaque
  /// message. [removal] : quelque chose vient d'être retiré (un binôme quitté), le
  /// secret matériel est renouvelé pour que les anciennes copies ne se relisent plus.
  void saveVault({bool removal = false});

  /// Reconstruit la liste des canaux du moteur après un ajout ou un retrait.
  void refreshChannels();

  /// Met la radio en accord avec l'état du coffre (allumer, éteindre).
  Future<void> syncTransport();

  /// Un proche de confiance (binôme appairé en face à face) nous a transmis la
  /// clé publique du canal des medics. Ignorée si on en connaît déjà une.
  void learnMedicKey(Uint8List publicKey);

  /// On vient de connaître ou de créer le canal des medics : les binômes en sont
  /// informés.
  void medicKeyChanged();

  /// Plus de groupe, plus de binôme et pas de rôle medic : l'événement est fini,
  /// on oublie son secret et la clé du canal des medics.
  void endEventIfUnused();

  /// Annonce (ou retire, avec null) une balise Bluetooth de 5 octets.
  Future<bool> setBeacon(Uint8List? beacon);

  /// Les balises entendues par la radio.
  Stream<ProximityReading> get proximity;

  /// Prévient l'interface.
  void changed();
}
