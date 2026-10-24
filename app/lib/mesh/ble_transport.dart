import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'frame.dart';
import 'group.dart';
import 'keep_alive.dart';
import 'mesh_node.dart';
import 'proximity.dart';
import 'transport.dart';

/// Journal de mise au point de la radio, absent par défaut : une appli de
/// sécurité n'écrit pas dans le journal du téléphone ce qu'elle fait. Pour le
/// activer sur un build d'essai : `--dart-define=CORTEGE_TRACE=true`.
const _traceEnabled = bool.fromEnvironment('CORTEGE_TRACE');

/// Radio Bluetooth Low Energy du maillage.
///
/// Chaque téléphone tient deux rôles à la fois :
/// - périphérique : il annonce un identifiant dérivé du secret d'événement
///   (qui change toutes les 15 minutes) et expose une « boîte de réception » où
///   les voisins écrivent des trames ;
/// - central : il cherche cet identifiant chez les autres, se connecte à
///   quelques voisins et écrit dans leur boîte.
///
/// Les deux sens sont donc deux connexions distinctes. Un même téléphone
/// apparaît sous deux adresses Bluetooth selon le rôle : on ne s'en sert pas
/// pour reconnaître un voisin, seuls les contenus des messages comptent.
class BleMeshTransport implements MeshTransport {
  BleMeshTransport({
    DateTime Function()? now,
    this.keepAlive,
    this.maxOutgoing = 4,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final KeepAlive? keepAlive;

  /// Nombre maximum de voisins auxquels on se connecte comme central. Android
  /// plafonne le nombre de connexions simultanées (autour de sept selon les
  /// modèles) et chacune coûte de la batterie.
  final int maxOutgoing;

  final _central = CentralManager();
  final _peripheral = PeripheralManager();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _links = <String, _BleLink>{};
  final _connecting = <String>{};
  final _retryAfter = <String, DateTime>{};
  final _assemblers = <String, FrameAssembler>{};

  /// Numéro de fabricant réservé aux essais, sans entreprise derrière.
  static const _beaconCompany = 0xFFFF;
  static const beaconLength = 5;

  Uint8List? _beacon;
  final _proximity = StreamController<ProximityReading>.broadcast(sync: true);

  EventKeys? _keys;
  MeshTransportEvents? _events;
  UUID? _gattUuid;
  UUID? _inboxUuid;
  GATTCharacteristic? _inbox;
  Timer? _rotation;
  int? _period;
  var _running = false;

  @override
  Future<void> start(EventKeys keys, MeshTransportEvents events) async {
    if (_running) await stop();

    await _ensureAuthorized();
    if (_central.state != BluetoothLowEnergyState.poweredOn ||
        _peripheral.state != BluetoothLowEnergyState.poweredOn) {
      throw MeshTransportUnavailable('Bluetooth éteint', retryable: true);
    }

    _keys = keys;
    _events = events;
    _gattUuid = UUID(keys.gattService);
    _inboxUuid = UUID(keys.inboxCharacteristic);
    _running = true;

    try {
      _subscriptions
        ..add(_central.discovered.listen(_onDiscovered))
        ..add(_central.connectionStateChanged.listen(_onCentralConnectionChanged))
        ..add(_peripheral.characteristicWriteRequested.listen(_onWriteRequested))
        ..add(_peripheral.connectionStateChanged.listen(_onPeripheralConnectionChanged))
        ..add(_central.stateChanged.listen(_onRadioStateChanged))
        ..add(_peripheral.stateChanged.listen(_onRadioStateChanged));

      _inbox = GATTCharacteristic.mutable(
        uuid: _inboxUuid!,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );
      await _peripheral.removeAllServices();
      _trace('ajout du service GATT');
      await _guard(
        _peripheral.addService(
          GATTService(
            uuid: _gattUuid!,
            isPrimary: true,
            includedServices: [],
            characteristics: [_inbox!],
          ),
        ),
        'Le Bluetooth',
      );
      _trace('service GATT ajouté');
      await _startRadio();
      _trace('annonce et recherche démarrées');
      _rotation = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
      await keepAlive?.start();
      _trace('service au premier plan demandé');
    } on MeshTransportUnavailable {
      await stop();
      rethrow;
    } catch (error) {
      _trace('échec du démarrage : $error');
      await stop();
      throw MeshTransportUnavailable('Bluetooth indisponible', retryable: true);
    }
  }

  /// Ne demande les autorisations que si elles manquent. Les redemander quand
  /// elles sont déjà accordées a suffi, sur le OnePlus, à ne jamais recevoir de
  /// réponse : le maillage restait bloqué sur « démarrage ».
  Future<void> _ensureAuthorized() async {
    // L'état n'est connu qu'un instant après la création des gestionnaires.
    for (var i = 0; i < 20; i++) {
      if (_central.state != BluetoothLowEnergyState.unknown &&
          _peripheral.state != BluetoothLowEnergyState.unknown) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final missing = _central.state == BluetoothLowEnergyState.unauthorized ||
        _peripheral.state == BluetoothLowEnergyState.unauthorized ||
        _central.state == BluetoothLowEnergyState.unknown ||
        _peripheral.state == BluetoothLowEnergyState.unknown;
    _trace('état : central=${_central.state.name} périphérique=${_peripheral.state.name}');
    if (!missing) return;

    _trace('demande des autorisations');
    final centralOk = await _guard(
      _central.authorize(),
      'La demande d\'autorisation',
      const Duration(minutes: 2),
    );
    final peripheralOk = await _guard(
      _peripheral.authorize(),
      'La demande d\'autorisation',
      const Duration(minutes: 2),
    );
    _trace('autorisations : central=$centralOk périphérique=$peripheralOk');
    if (!centralOk || !peripheralOk) {
      throw MeshTransportUnavailable('Permission Bluetooth refusée');
    }
  }

  /// Aucune étape de la radio ne doit pouvoir bloquer le démarrage sans fin.
  Future<T> _guard<T>(
    Future<T> operation,
    String what, [
    Duration timeout = const Duration(seconds: 15),
  ]) =>
      operation.timeout(
        timeout,
        onTimeout: () =>
            throw MeshTransportUnavailable('$what ne répond pas', retryable: true),
      );

  /// Journal de mise au point : étapes seulement, jamais de clé ni de contenu.
  void _trace(String message) {
    if (_traceEnabled) debugPrint('cortege-ble: $message');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _rotation?.cancel();
    _rotation = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    try {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (_) {}
    for (final link in _links.values.toList()) {
      try {
        await _central.disconnect(link.peripheral);
      } catch (_) {}
    }
    _links.clear();
    _connecting.clear();
    _assemblers.clear();
    _retryAfter.clear();
    _keys = null;
    _events = null;
    await keepAlive?.stop();
  }

  @override
  Stream<ProximityReading> get proximity => _proximity.stream;

  @override
  Future<bool> setBeacon(Uint8List? beacon) async {
    if (beacon != null && beacon.length != beaconLength) {
      throw ArgumentError('balise de $beaconLength octets attendue');
    }
    _beacon = beacon == null ? null : Uint8List.fromList(beacon);
    if (!_running || _keys == null) return true;
    try {
      await _peripheral.stopAdvertising();
      await _guard(_peripheral.startAdvertising(_advertisement(_keys!)), 'L\'annonce Bluetooth');
      return true;
    } catch (error) {
      _trace('balise impossible ($error)');
      // Surtout ne pas rester sans annonce : sans elle, les voisins ne nous
      // voient plus. On remet l'annonce normale.
      _beacon = null;
      try {
        await _guard(_peripheral.startAdvertising(_advertisement(_keys!)), 'L\'annonce Bluetooth');
      } catch (_) {}
      return false;
    }
  }

  /// L'annonce tient dans 31 octets : drapeaux (3), identifiant d'événement de
  /// 128 bits (18), et la balise s'il y en a une (2 + 2 + 5 = 9). On n'ajoute
  /// donc rien d'autre.
  Advertisement _advertisement(EventKeys keys) {
    final beacon = _beacon;
    return Advertisement(
      serviceUUIDs: [UUID(keys.advertisedService(_period!))],
      manufacturerSpecificData: [
        if (beacon != null) ManufacturerSpecificData(id: _beaconCompany, data: beacon),
      ],
    );
  }

  Future<void> _startRadio() async {
    final keys = _keys!;
    final now = _now();
    _period = EventKeys.periodOf(now);
    _trace('annonce de la période $_period');
    await _guard(
      _peripheral.startAdvertising(_advertisement(keys)),
      'L\'annonce Bluetooth',
    );
    _trace('annonce démarrée, recherche');
    await _guard(
      _central.startDiscovery(
        serviceUUIDs: [for (final bytes in keys.servicesToScan(now)) UUID(bytes)],
      ),
      'La recherche Bluetooth',
    );
  }

  /// Le Bluetooth a été éteint (ou la permission retirée) pendant que la radio
  /// tournait : Android coupe alors l'annonce, la recherche et les connexions, et
  /// ne les remet pas en route au rallumage. On le dit au moteur, qui relance
  /// tout dès que c'est possible.
  void _onRadioStateChanged(BluetoothLowEnergyStateChangedEventArgs event) {
    if (!_running) return;
    final state = event.state;
    _trace('état du Bluetooth : ${state.name}');
    if (state == BluetoothLowEnergyState.poweredOn ||
        state == BluetoothLowEnergyState.unknown) {
      return;
    }
    final unauthorized = state == BluetoothLowEnergyState.unauthorized;
    _events?.onFailure(
      unauthorized ? 'Permission Bluetooth refusée' : 'Bluetooth éteint',
      !unauthorized,
    );
  }

  var _aloneTicks = 0;

  /// Toutes les 30 secondes :
  /// - toutes les 15 minutes, l'identifiant annoncé change : on relance
  ///   l'annonce et la recherche avec les nouveaux identifiants (les connexions
  ///   en cours ne sont pas touchées) ;
  /// - si on est resté une minute sans aucun voisin, on relance aussi l'annonce
  ///   et la recherche : une annonce ou une recherche qui s'est endormie en
  ///   silence ne se verrait pas autrement.
  Future<void> _tick() async {
    if (!_running) return;
    final rotate = EventKeys.periodOf(_now()) != _period;
    if (_links.isEmpty && _connecting.isEmpty) {
      _aloneTicks++;
    } else {
      _aloneTicks = 0;
    }
    if (!rotate && _aloneTicks < 2) return;
    _aloneTicks = 0;
    try {
      await _peripheral.stopAdvertising();
      await _central.stopDiscovery();
      await _startRadio();
    } catch (error) {
      _trace('relance de la radio impossible ($error)');
    }
  }

  // Rôle central : on se connecte aux voisins et on leur écrit.

  void _onDiscovered(DiscoveredEventArgs event) {
    if (!_running) return;
    // Une balise annoncée par un téléphone qui cherche à être trouvé : on note la
    // force de son signal, qu'on soit déjà connecté à lui ou non.
    for (final data in event.advertisement.manufacturerSpecificData) {
      if (data.id == _beaconCompany && data.data.length == beaconLength) {
        _trace('balise rssi=${event.rssi}');
        _proximity.add(ProximityReading(Uint8List.fromList(data.data), event.rssi));
      }
    }
    final id = event.peripheral.uuid.toString();
    if (_links.containsKey(id) || _connecting.contains(id)) return;
    if (_links.length + _connecting.length >= maxOutgoing) return;
    final retry = _retryAfter[id];
    if (retry != null && _now().isBefore(retry)) return;
    _trace('voisin vu, connexion');
    unawaited(_connect(event.peripheral));
  }

  Future<void> _connect(Peripheral peripheral) async {
    final id = peripheral.uuid.toString();
    _connecting.add(id);
    try {
      await _central.connect(peripheral);
      final mtu = await _central.requestMTU(peripheral, mtu: 517);
      final maxWrite = await _central.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
      final services = await _central.discoverGATT(peripheral);
      GATTCharacteristic? inbox;
      for (final service in services) {
        if (service.uuid != _gattUuid) continue;
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _inboxUuid) inbox = characteristic;
        }
      }
      if (inbox == null || !_running) {
        await _central.disconnect(peripheral);
        _retryAfter[id] = _now().add(const Duration(seconds: 60));
        return;
      }
      final link = _BleLink(
        id: id,
        peripheral: peripheral,
        inbox: inbox,
        central: _central,
        maxWrite: math.max(20, math.min(maxWrite, mtu)),
        onBroken: () => _dropLink(id),
      );
      _links[id] = link;
      _events?.onLinkUp(link);
      _trace('lien prêt (écriture max ${link.maxWrite} octets)');
    } catch (error) {
      _trace('échec de connexion : $error');
      _retryAfter[id] = _now().add(const Duration(seconds: 10));
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
    } finally {
      _connecting.remove(id);
    }
  }

  void _onCentralConnectionChanged(PeripheralConnectionStateChangedEventArgs event) {
    if (event.state != ConnectionState.disconnected) return;
    final id = event.peripheral.uuid.toString();
    _retryAfter[id] = _now().add(const Duration(seconds: 5));
    _removeLink(id);
  }

  void _dropLink(String id) {
    final link = _links[id];
    _retryAfter[id] = _now().add(const Duration(seconds: 10));
    _removeLink(id);
    if (link != null) {
      unawaited(_central.disconnect(link.peripheral).then((_) {}, onError: (_) {}));
    }
  }

  void _removeLink(String id) {
    if (_links.remove(id) != null) _events?.onLinkDown(id);
  }

  // Rôle périphérique : les voisins nous écrivent des trames.

  Future<void> _onWriteRequested(GATTCharacteristicWriteRequestedEventArgs event) async {
    if (!_running || event.characteristic.uuid != _inboxUuid) return;
    final sourceId = 'in:${event.central.uuid}';
    List<Uint8List> frames;
    try {
      frames = _assemblers
          .putIfAbsent(sourceId, FrameAssembler.new)
          .add(Uint8List.fromList(event.request.value));
    } on FrameStreamError {
      _assemblers.remove(sourceId);
      try {
        await _peripheral.respondWriteRequestWithError(
          event.request,
          error: GATTError.invalidPDU,
        );
        await _peripheral.disconnect(event.central);
      } catch (_) {}
      return;
    }
    try {
      await _peripheral.respondWriteRequest(event.request);
    } catch (_) {}
    for (final frame in frames) {
      _events?.onFrame(sourceId, frame);
    }
  }

  void _onPeripheralConnectionChanged(CentralConnectionStateChangedEventArgs event) {
    if (event.state == ConnectionState.disconnected) {
      _assemblers.remove('in:${event.central.uuid}');
    }
  }
}

class _BleLink implements MeshLink {
  _BleLink({
    required this.id,
    required this.peripheral,
    required this.inbox,
    required this.central,
    required this.maxWrite,
    required this.onBroken,
  });

  @override
  final String id;
  final Peripheral peripheral;
  final GATTCharacteristic inbox;
  final CentralManager central;
  final int maxWrite;
  final void Function() onBroken;

  Future<void> _queue = Future.value();

  /// Les morceaux de deux trames ne doivent jamais se mélanger : les envois
  /// passent l'un après l'autre. Si une écriture échoue au milieu d'une
  /// trame, le flux du voisin est abîmé : on coupe la connexion.
  @override
  Future<void> send(Uint8List frame) {
    final chunks = chunksOf(withLength(frame), maxWrite);
    final operation = _queue.then((_) async {
      for (final chunk in chunks) {
        await central.writeCharacteristic(
          peripheral,
          inbox,
          value: chunk,
          type: GATTCharacteristicWriteType.withResponse,
        );
      }
    });
    _queue = operation.then((_) {}, onError: (_) => onBroken());
    return operation;
  }
}
