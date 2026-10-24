import 'package:flutter/services.dart';

/// Un secret gardé par le matériel, avec le numéro de génération sous lequel il
/// est rangé (pour pouvoir dire lequel garder après un renouvellement).
class StoredSecret {
  const StoredSecret(this.generation, this.bytes);

  final int generation;
  final Uint8List bytes;
}

/// Secret de 32 octets, un par emplacement du coffre, protégé par le matériel
/// du téléphone. Le coffre en dépend : sans lui, même le bon PIN ne suffit pas.
///
/// Un emplacement garde un seul secret, sauf pendant un renouvellement : le
/// nouveau est ajouté à côté de l'ancien, le coffre est réécrit avec la clé qui en
/// découle, puis l'ancien est détruit. Une coupure au milieu laisse donc toujours
/// au moins un secret qui ouvre le fichier présent sur le disque.
abstract class HardwareSecretStore {
  /// Les secrets de cet emplacement, du plus récent au plus ancien. Vide si aucun
  /// n'existe.
  Future<List<StoredSecret>> loadAll(int slot);

  /// Remplace tout ce que l'emplacement gardait par ce secret. Rend sa génération.
  Future<int> store(int slot, Uint8List secret);

  /// Ajoute un secret plus récent à côté de l'actuel, sans y toucher. Il ne doit
  /// y avoir qu'un secret au départ. Rend la génération du nouveau.
  Future<int> rotate(int slot, Uint8List secret);

  /// Détruit les autres secrets de cet emplacement, clés matérielles comprises.
  Future<void> keepOnly(int slot, int generation);

  /// Détruit tous les secrets. C'est l'effacement cryptographique du coffre.
  Future<void> eraseAll();
}

class HardwareSecretUnavailable implements Exception {
  HardwareSecretUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'HardwareSecretUnavailable($detail)';
}

/// Android : Keystore, via `HardwareSecret.kt`. Pas encore écrit pour iOS
/// (étape f) : sur iOS l'appli refuse de créer un coffre plutôt que de se
/// passer de la protection matérielle.
class PlatformHardwareSecretStore implements HardwareSecretStore {
  static const _channel = MethodChannel('org.cortege.app/hardware_secret');

  @override
  Future<List<StoredSecret>> loadAll(int slot) async {
    final raw = await _call<List<Object?>>('loadAll', {'slot': slot});
    if (raw == null) return const [];
    return [
      for (final entry in raw)
        StoredSecret(
          (entry! as Map)['generation']! as int,
          (entry as Map)['secret']! as Uint8List,
        ),
    ];
  }

  @override
  Future<int> store(int slot, Uint8List secret) async =>
      (await _call<int>('store', {'slot': slot, 'secret': secret}))!;

  @override
  Future<int> rotate(int slot, Uint8List secret) async =>
      (await _call<int>('rotate', {'slot': slot, 'secret': secret}))!;

  @override
  Future<void> keepOnly(int slot, int generation) async {
    await _call<void>('keepOnly', {'slot': slot, 'generation': generation});
  }

  @override
  Future<void> eraseAll() async {
    await _call<void>('erase', null);
  }

  Future<T?> _call<T>(String method, Map<String, Object?>? args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw HardwareSecretUnavailable('plateforme non prise en charge');
    } on PlatformException catch (e) {
      throw HardwareSecretUnavailable(e.code);
    }
  }
}
