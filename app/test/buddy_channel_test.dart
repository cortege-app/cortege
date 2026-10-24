import 'dart:convert';
import 'dart:typed_data';

import 'package:cortege/mesh/channels.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/mesh/mesh_node.dart';
import 'package:cortege/vault/vault_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/buddy_sim.dart';
import 'support/mesh_sim.dart';

class _Capture implements MeshLink {
  _Capture(this.frames);

  final List<Uint8List> frames;

  @override
  String get id => 'capture';

  @override
  Future<void> send(Uint8List frame) async => frames.add(frame);
}

void main() {
  late MeshCrypto crypto;

  setUpAll(() async {
    crypto = await newMeshCrypto();
  });

  /// Un téléphone de plus : un moteur et le canal de binôme d'une personne.
  ({MeshNode node, BuddyChannel channel, List<ReceivedMessage> inbox}) phone(
    SimBuddies buddies,
    int index,
  ) {
    final node = MeshNode(crypto: crypto);
    final channel = buddies.channel(index);
    node.setChannels([channel]);
    final inbox = <ReceivedMessage>[];
    node.messages.listen(inbox.add);
    return (node: node, channel: channel, inbox: inbox);
  }

  Uint8List body(String text) => Uint8List.fromList(utf8.encode(text));

  /// Les trames qu'une personne émet, dans l'ordre.
  List<Uint8List> framesFrom(SimBuddies buddies, int sender, int count) {
    final p = phone(buddies, sender);
    final frames = <Uint8List>[];
    p.node.addLink(_Capture(frames));
    for (var i = 0; i < count; i++) {
      p.node.sendOn(p.channel, type: MessageType.checkIn, body: body('ok $i'), senderName: 'P$sender');
    }
    return frames;
  }

  group('échange', () {
    test('de l\'un à l\'autre, dans les deux sens', () {
      final buddies = SimBuddies(crypto, 2);
      final a = phone(buddies, 0);
      final b = phone(buddies, 1);
      final toB = <Uint8List>[];
      final toA = <Uint8List>[];
      a.node.addLink(_Capture(toB));
      b.node.addLink(_Capture(toA));

      a.node.sendOn(a.channel, type: MessageType.checkIn, body: body('bien'), senderName: 'P0');
      b.node.onFrame('a', toB.single);
      toA.clear(); // B a aussi rediffusé la trame d'A vers A : sans intérêt ici
      b.node.sendOn(b.channel, type: MessageType.checkIn, body: body('reçu'), senderName: 'P1');
      a.node.onFrame('b', toA.single);

      expect(b.inbox.single.type, MessageType.checkIn);
      expect(utf8.decode(b.inbox.single.body), 'bien');
      expect(b.inbox.single.senderName, 'P0');
      expect(b.inbox.single.mine, isFalse);
      expect(utf8.decode(a.inbox.single.body), 'reçu');
    });

    test('à trois, chacun lit ce que les deux autres écrivent', () {
      final buddies = SimBuddies(crypto, 3);
      final frames = framesFrom(buddies, 0, 2);
      for (final index in [1, 2]) {
        final p = phone(buddies, index);
        for (final frame in frames) {
          p.node.onFrame('x', frame);
        }
        expect(p.inbox.map((m) => utf8.decode(m.body)), ['ok 0', 'ok 1'], reason: 'P$index');
      }
    });

    test('à quatre aussi', () {
      final buddies = SimBuddies(crypto, 4);
      final frames = framesFrom(buddies, 3, 1);
      for (final index in [0, 1, 2]) {
        final p = phone(buddies, index);
        p.node.onFrame('x', frames.single);
        expect(p.inbox, hasLength(1), reason: 'P$index');
      }
    });

    test('quelqu\'un hors du binôme ne lit rien', () {
      final buddies = SimBuddies(crypto, 2);
      final other = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 1);
      final stranger = phone(other, 1);
      stranger.node.onFrame('x', frames.single);
      expect(stranger.inbox, isEmpty);
    });

    test('un relais sans le binôme transporte sans lire', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 1);
      final relay = MeshNode(crypto: crypto);
      final out = <Uint8List>[];
      relay.addLink(_Capture(out));
      relay.onFrame('x', frames.single);
      expect(out, hasLength(1));
      expect(out.single[1], lessThan(frames.single[1]), reason: 'le TTL baisse d\'un saut');
    });
  });

  group('confidentialité persistante', () {
    test('la clé du message n\'existe plus une fois lu : on ne peut pas le relire', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 5);
      final b = phone(buddies, 1);
      for (final frame in frames) {
        b.node.onFrame('x', frame);
      }
      expect(b.inbox, hasLength(5));

      // Un attaquant obtient l'état de B après coup (téléphone saisi, coffre ouvert).
      final captured = BuddyRecord.fromJson(
        Map<String, Object?>.from(buddies.records[1].toJson()),
      );
      final attacker = MeshNode(crypto: crypto);
      attacker.setChannels([BuddyChannel(crypto, captured)]);
      final stolen = <ReceivedMessage>[];
      attacker.messages.listen(stolen.add);
      for (final frame in frames) {
        attacker.onFrame('x', frame);
      }
      expect(stolen, isEmpty, reason: 'les messages déjà reçus sont illisibles avec l\'état actuel');
    });

    test('la chaîne avance à chaque message et les anciennes clés disparaissent', () {
      final buddies = SimBuddies(crypto, 2);
      final before = Uint8List.fromList(buddies.records[1].members.single.chainKey);
      final frames = framesFrom(buddies, 0, 3);
      final b = phone(buddies, 1);
      for (final frame in frames) {
        b.node.onFrame('x', frame);
      }
      final member = buddies.records[1].members.single;
      expect(member.nextIndex, 3);
      expect(member.chainKey, isNot(before));
      expect(member.skipped, isEmpty);
    });

    test('à l\'envoi aussi : la chaîne d\'envoi avance', () {
      final buddies = SimBuddies(crypto, 2);
      final before = Uint8List.fromList(buddies.records[0].sendChainKey);
      framesFrom(buddies, 0, 4);
      expect(buddies.records[0].sendIndex, 4);
      expect(buddies.records[0].sendChainKey, isNot(before));
    });

    test('deux messages identiques donnent des trames différentes', () {
      final buddies = SimBuddies(crypto, 2);
      final p = phone(buddies, 0);
      final out = <Uint8List>[];
      p.node.addLink(_Capture(out));
      p.node.sendOn(p.channel, type: MessageType.checkIn, body: body('ok'));
      p.node.sendOn(p.channel, type: MessageType.checkIn, body: body('ok'));
      expect(out[0], isNot(out[1]));
    });

    test('l\'état survit à un enregistrement dans le coffre', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 4);
      final first = phone(buddies, 1);
      first.node.onFrame('x', frames[0]);
      first.node.onFrame('x', frames[1]);

      // Le coffre est refermé puis rouvert : l'état passe par du JSON.
      final reopened = BuddyRecord.fromJson(
        Map<String, Object?>.from(buddies.records[1].toJson()),
      );
      final node = MeshNode(crypto: crypto);
      node.setChannels([BuddyChannel(crypto, reopened)]);
      final inbox = <ReceivedMessage>[];
      node.messages.listen(inbox.add);
      node.onFrame('x', frames[2]);
      node.onFrame('x', frames[3]);

      expect(inbox.map((m) => utf8.decode(m.body)), ['ok 2', 'ok 3']);
    });
  });

  group('désordre et pertes', () {
    test('messages dans le désordre : tous lus', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 5);
      final b = phone(buddies, 1);
      for (final i in [2, 0, 4, 1, 3]) {
        b.node.onFrame('x', frames[i]);
      }
      expect(b.inbox.map((m) => utf8.decode(m.body)).toSet(), {'ok 0', 'ok 1', 'ok 2', 'ok 3', 'ok 4'});
      expect(buddies.records[1].members.single.skipped, isEmpty);
      expect(buddies.records[1].members.single.nextIndex, 5);
    });

    test('messages perdus en route : la chaîne rattrape', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 12);
      final b = phone(buddies, 1);
      b.node.onFrame('x', frames[0]);
      b.node.onFrame('x', frames[11]);
      expect(b.inbox.map((m) => utf8.decode(m.body)), ['ok 0', 'ok 11']);
      // Un message sauté qui arrive en retard est encore lisible.
      b.node.onFrame('x', frames[5]);
      expect(b.inbox.map((m) => utf8.decode(m.body)).last, 'ok 5');
    });

    test('un saut de plus de 64 messages est refusé et ne casse rien', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 80);
      final b = phone(buddies, 1);
      b.node.onFrame('x', frames[75]);
      expect(b.inbox, isEmpty);
      expect(b.node.stats.rejected, 1);
      expect(buddies.records[1].members.single.nextIndex, 0, reason: 'rien n\'a avancé');

      b.node.onFrame('x', frames[3]);
      expect(utf8.decode(b.inbox.single.body), 'ok 3');
    });

    test('un message rejoué n\'est livré qu\'une fois', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 1);
      final b = phone(buddies, 1);
      b.node.onFrame('x', frames.single);
      b.node.onFrame('y', frames.single);
      expect(b.inbox, hasLength(1));
    });

    test('un message rejoué après un redémarrage est refusé (clé déjà jetée)', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 2);
      final b = phone(buddies, 1);
      b.node.onFrame('x', frames[0]);
      b.node.onFrame('x', frames[1]);

      // Nouveau moteur : le cache « déjà vu » est vide, mais la clé est jetée.
      final fresh = MeshNode(crypto: crypto);
      fresh.setChannels([BuddyChannel(crypto, buddies.records[1])]);
      final inbox = <ReceivedMessage>[];
      fresh.messages.listen(inbox.add);
      fresh.onFrame('x', frames[0]);
      expect(inbox, isEmpty);
    });
  });

  group('trames falsifiées', () {
    test('un octet modifié : refusé, et la chaîne n\'avance pas', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 2);
      final b = phone(buddies, 1);
      final broken = Uint8List.fromList(frames[0])..[frames[0].length - 5] ^= 1;

      b.node.onFrame('x', broken);
      expect(b.inbox, isEmpty);
      expect(buddies.records[1].members.single.nextIndex, 0);

      // Le vrai message passe ensuite : le faux n'a rien bloqué.
      b.node.onFrame('x', frames[0]);
      expect(b.inbox, hasLength(1));
    });

    test('un numéro de message trafiqué : refusé', () {
      final buddies = SimBuddies(crypto, 2);
      final frames = framesFrom(buddies, 0, 3);
      final b = phone(buddies, 1);
      final moved = Uint8List.fromList(frames[0]);
      // Le numéro est dans les 4 premiers octets du nonce (après l'en-tête de 18 octets).
      moved[18 + 3] ^= 2;
      b.node.onFrame('x', moved);
      expect(b.inbox, isEmpty);
      expect(buddies.records[1].members.single.nextIndex, 0);
    });

    test('un proche ne peut pas écrire à la place d\'un autre', () {
      // C connaît la chaîne de A (il la reçoit) mais pas sa clé de signature.
      final buddies = SimBuddies(crypto, 3);
      final aChain = Uint8List.fromList(buddies.records[2].members[0].chainKey);
      final forgerRecord = BuddyRecord.fromJson(
        Map<String, Object?>.from(buddies.records[2].toJson()),
      )
        ..sendChainKey = aChain
        ..sendIndex = 0;
      final forger = MeshNode(crypto: crypto);
      final forgerChannel = BuddyChannel(crypto, forgerRecord);
      final out = <Uint8List>[];
      forger.addLink(_Capture(out));
      forger.sendOn(forgerChannel, type: MessageType.checkIn, body: body('je suis P0'), senderName: 'P0');

      final b = phone(buddies, 1);
      b.node.onFrame('x', out.single);
      expect(b.inbox, isEmpty, reason: 'la chaîne de P0 déchiffre, mais la signature n\'est pas la sienne');
      expect(b.node.stats.rejected, 1);
      expect(buddies.records[1].members[0].nextIndex, 0, reason: 'la chaîne de P0 n\'a pas avancé');
    });

    test('un message du binôme n\'est pas lisible dans un autre binôme', () {
      final one = SimBuddies(crypto, 2);
      final two = SimBuddies(crypto, 2);
      final frames = framesFrom(one, 0, 1);
      final intruder = phone(two, 1);
      intruder.node.onFrame('x', frames.single);
      expect(intruder.inbox, isEmpty);
    });
  });

  group('forme des trames', () {
    test('l\'étiquette du binôme change d\'une heure à l\'autre', () {
      final buddies = SimBuddies(crypto, 2);
      final channel = buddies.channel(0);
      final now = DateTime.utc(2026, 10, 18, 12).millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;
      expect(channel.tagFor(now), isNot(channel.tagFor(now + 1)));
      expect(channel.tagFor(now), channel.tagFor(now));
    });

    test('deux binômes n\'ont jamais la même étiquette', () {
      final one = SimBuddies(crypto, 2).channel(0);
      final two = SimBuddies(crypto, 2).channel(0);
      expect(one.tagFor(100), isNot(two.tagFor(100)));
    });

    test('un message de binôme tient dans une écriture Bluetooth', () {
      final buddies = SimBuddies(crypto, 4);
      final p = phone(buddies, 0);
      final out = <Uint8List>[];
      p.node.addLink(_Capture(out));
      p.node.sendOn(
        p.channel,
        type: MessageType.roster,
        body: Uint8List(280),
        senderName: 'n' * 24,
      );
      expect(out.single.length + 2, lessThanOrEqualTo(512));
    });
  });
}
