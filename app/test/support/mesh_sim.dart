import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/mesh/mesh_node.dart';

/// Un faux téléphone : un [MeshNode] et la liste de ses groupes.
class SimPhone {
  SimPhone(this.name, this.node, this.groups) {
    node.setGroups(groups);
    node.messages.listen(inbox.add);
  }

  final String name;
  final MeshNode node;
  final List<MeshGroup> groups;
  final inbox = <ReceivedMessage>[];

  Set<String> get texts => inbox.map((m) => m.text).toSet();
}

/// Réseau simulé. Les trames sont livrées dans l'ordre d'envoi, une file à la
/// fois, ce qui rend les tests déterministes. Chaque lien est à sens unique :
/// `connect(a, b)` fait que `a` sait envoyer à `b`.
class SimNetwork {
  SimNetwork(this.crypto);

  final MeshCrypto crypto;
  final phones = <String, SimPhone>{};
  final _queue = Queue<void Function()>();
  var framesDelivered = 0;
  var framesOnAir = 0;

  /// Frames vues par le réseau, pour les tests qui regardent ce qu'un
  /// observateur extérieur voit.
  final onAir = <Uint8List>[];

  SimPhone add(
    String name, {
    List<MeshGroup> groups = const [],
    DateTime Function()? now,
    int maxFramesPerWindow = 60,
  }) {
    final node = MeshNode(
      crypto: crypto,
      now: now,
      maxFramesPerWindow: maxFramesPerWindow,
    );
    return phones[name] = SimPhone(name, node, groups);
  }

  void connect(String from, String to) {
    final target = phones[to]!;
    phones[from]!.node.addLink(_SimLink(this, from, to, target));
  }

  void connectBoth(String a, String b) {
    connect(a, b);
    connect(b, a);
  }

  /// Distribue toutes les trames en attente, y compris celles que les
  /// rediffusions créent en route.
  void run() {
    while (_queue.isNotEmpty) {
      _queue.removeFirst()();
    }
  }

  void _enqueue(String from, SimPhone target, Uint8List bytes) {
    framesOnAir++;
    onAir.add(Uint8List.fromList(bytes));
    _queue.add(() {
      framesDelivered++;
      target.node.onFrame(from, bytes);
    });
  }
}

class _SimLink implements MeshLink {
  _SimLink(this.network, this.from, this.to, this.target);

  final SimNetwork network;
  final String from;
  final String to;
  final SimPhone target;

  @override
  String get id => to;

  @override
  Future<void> send(Uint8List frame) async {
    network._enqueue(from, target, frame);
  }
}

/// Fabrique des groupes qui partagent la même clé, comme après un scan de QR.
class SimGroups {
  SimGroups(this.crypto)
      : eventSecret = crypto.randomBytes(32),
        groupKey = crypto.randomBytes(32);

  final MeshCrypto crypto;
  final Uint8List eventSecret;
  final Uint8List groupKey;

  /// Un membre : même clé de groupe, sa propre paire de clés de signature.
  MeshGroup member({String name = 'Cortège'}) => MeshGroup.fromInvite(
        crypto,
        GroupInvite(name: name, groupKey: groupKey, eventSecret: eventSecret),
      );
}

Future<MeshCrypto> newMeshCrypto() async => MeshCrypto(await VaultCrypto.create());
