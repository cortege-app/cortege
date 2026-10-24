import 'dart:typed_data';

import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/mesh/mesh_node.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_sim.dart';

void main() {
  late MeshCrypto crypto;

  setUpAll(() async {
    crypto = await newMeshCrypto();
  });

  /// Une chaîne de [count] téléphones : p0 - p1 - p2 - ...
  SimNetwork chain(int count, SimGroups groups, {Set<int> relayOnly = const {}}) {
    final net = SimNetwork(crypto);
    for (var i = 0; i < count; i++) {
      net.add('p$i', groups: relayOnly.contains(i) ? [] : [groups.member()]);
    }
    for (var i = 0; i < count - 1; i++) {
      net.connectBoth('p$i', 'p${i + 1}');
    }
    return net;
  }

  group('livraison', () {
    test('deux téléphones voisins', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);

      final sent = net.phones['p0']!.node.send(
        net.phones['p0']!.groups.first,
        senderName: 'Alex',
        text: 'on est place de la République',
      );
      net.run();

      final got = net.phones['p1']!.inbox.single;
      expect(got.text, 'on est place de la République');
      expect(got.senderName, 'Alex');
      expect(got.mine, isFalse);
      expect(got.id, sent.id);
      expect(sent.mine, isTrue);
      expect(net.phones['p0']!.inbox, isEmpty, reason: 'l\'expéditeur ne se reçoit pas');
    });

    test('accents et caractères spéciaux', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      const text = 'Rendez-vous à 18 h, près du café « Le Métro » (ça va ?) 你好';
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'Zoé', text: text);
      net.run();
      expect(net.phones['p1']!.inbox.single.text, text);
      expect(net.phones['p1']!.inbox.single.senderName, 'Zoé');
    });

    test('à travers une chaîne de relais', () {
      final groups = SimGroups(crypto);
      final net = chain(5, groups);
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'bonjour');
      net.run();
      for (var i = 1; i < 5; i++) {
        expect(net.phones['p$i']!.texts, {'bonjour'}, reason: 'p$i');
      }
    });

    test('un relais qui n\'est pas dans le groupe transporte sans pouvoir lire', () {
      final groups = SimGroups(crypto);
      final net = chain(3, groups, relayOnly: {1});
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'secret');
      net.run();

      expect(net.phones['p2']!.texts, {'secret'});
      expect(net.phones['p1']!.inbox, isEmpty);
      expect(net.phones['p1']!.node.stats.relayed, 1);
    });

    test('un autre groupe sur le même maillage ne lit rien', () {
      final ours = SimGroups(crypto);
      final theirs = SimGroups(crypto);
      final net = SimNetwork(crypto)
        ..add('a', groups: [ours.member()])
        ..add('x', groups: [theirs.member()])
        ..add('b', groups: [ours.member()])
        ..connectBoth('a', 'x')
        ..connectBoth('x', 'b');
      net.phones['a']!.node.send(net.phones['a']!.groups.first, senderName: 'A', text: 'pour nous');
      net.run();

      expect(net.phones['b']!.texts, {'pour nous'});
      expect(net.phones['x']!.inbox, isEmpty);
    });

    test('plusieurs messages dans les deux sens', () {
      final groups = SimGroups(crypto);
      final net = chain(3, groups);
      final p0 = net.phones['p0']!;
      final p2 = net.phones['p2']!;
      p0.node.send(p0.groups.first, senderName: 'A', text: 'un');
      p2.node.send(p2.groups.first, senderName: 'C', text: 'deux');
      p0.node.send(p0.groups.first, senderName: 'A', text: 'trois');
      net.run();

      expect(p2.texts, {'un', 'trois'});
      expect(p0.texts, {'deux'});
      expect(net.phones['p1']!.texts, {'un', 'deux', 'trois'});
    });

    test('grille de 4 sur 5 : le coin opposé est à 7 sauts et reçoit', () {
      final groups = SimGroups(crypto);
      final net = SimNetwork(crypto);
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 5; c++) {
          net.add('$r,$c', groups: [groups.member()]);
        }
      }
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 5; c++) {
          if (c < 4) net.connectBoth('$r,$c', '$r,${c + 1}');
          if (r < 3) net.connectBoth('$r,$c', '${r + 1},$c');
        }
      }
      final origin = net.phones['0,0']!;
      origin.node.send(origin.groups.first, senderName: 'A', text: 'tout le monde');
      net.run();

      for (final phone in net.phones.values) {
        if (phone == origin) continue;
        expect(phone.texts, {'tout le monde'}, reason: phone.name);
        expect(phone.inbox, hasLength(1), reason: '${phone.name} reçoit une seule fois');
      }
    });
  });

  group('boucles et doublons', () {
    test('graphe complet : chaque message livré une fois, trafic borné', () {
      final groups = SimGroups(crypto);
      final net = SimNetwork(crypto);
      const count = 6;
      for (var i = 0; i < count; i++) {
        net.add('p$i', groups: [groups.member()]);
      }
      for (var i = 0; i < count; i++) {
        for (var j = 0; j < count; j++) {
          if (i != j) net.connect('p$i', 'p$j');
        }
      }
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'x');
      net.run();

      for (var i = 1; i < count; i++) {
        expect(net.phones['p$i']!.inbox, hasLength(1), reason: 'p$i');
      }
      // Chacun envoie la trame au plus une fois à chacun des autres.
      expect(net.framesOnAir, lessThanOrEqualTo(count * (count - 1)));
    });

    test('anneau : le message fait le tour sans tourner indéfiniment', () {
      final groups = SimGroups(crypto);
      final net = SimNetwork(crypto);
      const count = 8;
      for (var i = 0; i < count; i++) {
        net.add('p$i', groups: [groups.member()]);
      }
      for (var i = 0; i < count; i++) {
        net.connectBoth('p$i', 'p${(i + 1) % count}');
      }
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'boucle');
      net.run();

      for (var i = 1; i < count; i++) {
        expect(net.phones['p$i']!.inbox, hasLength(1), reason: 'p$i');
      }
      expect(net.framesOnAir, lessThanOrEqualTo(count * 2));
    });

    test('la même trame rejouée n\'est livrée qu\'une fois', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'une fois');
      net.run();
      final frame = net.onAir.first;

      net.phones['p1']!.node.onFrame('rejeu', frame);
      net.phones['p1']!.node.onFrame('rejeu', frame);
      net.run();

      expect(net.phones['p1']!.inbox, hasLength(1));
      expect(net.phones['p1']!.node.stats.duplicates, greaterThanOrEqualTo(2));
    });
  });

  group('limite de sauts', () {
    test('un message s\'arrête après 7 sauts', () {
      final groups = SimGroups(crypto);
      final net = chain(12, groups);
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'loin');
      net.run();

      for (var i = 1; i <= 7; i++) {
        expect(net.phones['p$i']!.texts, {'loin'}, reason: 'p$i est à $i sauts');
      }
      for (var i = 8; i < 12; i++) {
        expect(net.phones['p$i']!.inbox, isEmpty, reason: 'p$i est trop loin');
      }
    });

    test('un relais hostile qui annonce un TTL de 255 ne prolonge pas la portée', () {
      final groups = SimGroups(crypto);
      final net = chain(21, groups);

      // Un message fabriqué à part, puis injecté au milieu de la chaîne avec un
      // TTL gonflé (le TTL n'est pas authentifié, un relais peut le changer).
      final author = SimNetwork(crypto).add('auteur', groups: [groups.member()]);
      final captured = <Uint8List>[];
      author.node.addLink(_Capture(captured));
      author.node.send(author.groups.first, senderName: 'A', text: 'plafonné');
      final inflated = Uint8List.fromList(captured.single)..[1] = 255;

      net.phones['p10']!.node.onFrame('hostile', inflated);
      net.run();

      // Plafonné à 7 : la trame atteint 6 sauts de chaque côté de p10.
      for (var i = 4; i <= 16; i++) {
        expect(net.phones['p$i']!.texts, {'plafonné'}, reason: 'p$i');
      }
      for (final i in [0, 1, 2, 3, 17, 18, 19, 20]) {
        expect(net.phones['p$i']!.inbox, isEmpty, reason: 'p$i est trop loin');
      }
    });

    test('un TTL de 0 ou 1 est livré mais jamais rediffusé', () {
      final groups = SimGroups(crypto);
      final author = SimNetwork(crypto).add('auteur', groups: [groups.member()]);
      final captured = <Uint8List>[];
      author.node.addLink(_Capture(captured));
      author.node.send(author.groups.first, senderName: 'A', text: 'dernier saut');

      for (final ttl in [0, 1]) {
        final copy = Uint8List.fromList(captured.single)..[1] = ttl;
        final fresh = SimNetwork(crypto);
        final a = fresh.add('a', groups: [groups.member()]);
        fresh.add('b', groups: [groups.member()]);
        fresh.connect('a', 'b');
        a.node.onFrame('x', copy);
        fresh.run();
        expect(a.inbox, hasLength(1), reason: 'ttl $ttl livré');
        expect(fresh.phones['b']!.inbox, isEmpty, reason: 'ttl $ttl non rediffusé');
      }
    });
  });

  group('trames refusées', () {
    test('octet modifié en route : rejeté et jamais rediffusé', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'intact');
      final bytes = Uint8List.fromList(net.onAir.first);
      bytes[bytes.length - 3] ^= 1;

      final victim = net.add('victime', groups: [groups.member()]);
      final next = net.add('suivant', groups: [groups.member()]);
      net.connect('victime', 'suivant');
      victim.node.onFrame('attaquant', bytes);
      net.run();

      expect(victim.inbox, isEmpty);
      expect(victim.node.stats.rejected, 1);
      expect(next.inbox, isEmpty, reason: 'une trame falsifiée ne doit pas être relayée');
      expect(victim.node.stats.relayed, 0);
    });

    test('étiquette modifiée : traitée comme un autre groupe', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      net.phones['p0']!.node.send(net.phones['p0']!.groups.first, senderName: 'A', text: 'x');
      final bytes = Uint8List.fromList(net.onAir.first)..[5] ^= 1;
      final other = net.add('autre', groups: [groups.member()]);
      other.node.onFrame('attaquant', bytes);
      expect(other.inbox, isEmpty);
    });

    test('un membre ne peut pas se faire passer pour un autre', () {
      final groups = SimGroups(crypto);
      final victim = groups.member();
      final attacker = groups.member();
      // Annonce la clé publique de la victime mais signe avec sa propre clé.
      final forger = MeshGroup.create(
        crypto,
        name: 'forge',
        groupKey: groups.groupKey,
        signPublic: victim.signPublic,
        signSecret: attacker.signSecret.extractBytes(),
      );
      final net = SimNetwork(crypto)
        ..add('forgeron', groups: [forger])
        ..add('cible', groups: [groups.member()])
        ..connect('forgeron', 'cible');
      net.phones['forgeron']!.node.send(forger, senderName: 'Victime', text: 'faux message');
      net.run();

      expect(net.phones['cible']!.inbox, isEmpty);
      expect(net.phones['cible']!.node.stats.rejected, 1);
    });

    test('un membre présent dans deux groupes ne passe pas de l\'un à l\'autre', () {
      final first = SimGroups(crypto);
      final second = SimGroups(crypto);
      final inFirst = first.member();
      final inSecond = MeshGroup.create(
        crypto,
        name: 'second',
        groupKey: second.groupKey,
        signPublic: inFirst.signPublic,
        signSecret: inFirst.signSecret.extractBytes(),
      );
      final net = SimNetwork(crypto)
        ..add('moi', groups: [inFirst])
        ..add('autre', groups: [inSecond]);
      net.connect('moi', 'autre');
      net.phones['moi']!.node.send(inFirst, senderName: 'A', text: 'premier groupe');
      net.run();
      expect(net.phones['autre']!.inbox, isEmpty);
    });

    test('trames malformées ignorées sans planter', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final node = net.phones['p1']!.node;
      node.onFrame('x', Uint8List(0));
      node.onFrame('x', Uint8List(10));
      node.onFrame('x', Uint8List.fromList(List.filled(300, 7)));
      node.onFrame('x', Uint8List(5000));
      expect(node.stats.malformed, 4);
      expect(net.phones['p1']!.inbox, isEmpty);
    });
  });

  group('limite de débit', () {
    test('un voisin trop bavard est ignoré le temps de la fenêtre', () {
      var now = DateTime.utc(2026, 10, 18, 12);
      final groups = SimGroups(crypto);
      final sender = SimNetwork(crypto).add('s', groups: [groups.member()], now: () => now);
      final net = SimNetwork(crypto);
      final receiver = net.add('r', groups: [groups.member()], now: () => now, maxFramesPerWindow: 5);

      final frames = <Uint8List>[];
      sender.node.addLink(_Capture(frames));
      for (var i = 0; i < 8; i++) {
        sender.node.send(sender.groups.first, senderName: 'S', text: 'm$i');
      }
      for (final frame in frames) {
        receiver.node.onFrame('bavard', frame);
      }
      expect(receiver.inbox, hasLength(5));
      expect(receiver.node.stats.rateLimited, 3);

      now = now.add(const Duration(seconds: 11));
      receiver.node.onFrame('bavard', frames[5]);
      expect(receiver.inbox, hasLength(6), reason: 'la fenêtre suivante repart');
    });

    test('le débit est compté par voisin', () {
      final groups = SimGroups(crypto);
      final sender = SimNetwork(crypto).add('s', groups: [groups.member()]);
      final receiver = SimNetwork(crypto).add('r', groups: [groups.member()], maxFramesPerWindow: 2);
      final frames = <Uint8List>[];
      sender.node.addLink(_Capture(frames));
      for (var i = 0; i < 4; i++) {
        sender.node.send(sender.groups.first, senderName: 'S', text: 'm$i');
      }
      receiver.node.onFrame('a', frames[0]);
      receiver.node.onFrame('a', frames[1]);
      receiver.node.onFrame('b', frames[2]);
      receiver.node.onFrame('b', frames[3]);
      expect(receiver.inbox, hasLength(4));
    });
  });

  group('horloge', () {
    final base = DateTime.utc(2026, 10, 18, 12);

    Future<List<String>> receiveWith({
      required DateTime senderClock,
      required DateTime receiverClock,
      Duration maxAge = const Duration(hours: 24),
    }) async {
      final groups = SimGroups(crypto);
      final net = SimNetwork(crypto);
      final a = net.add('a', groups: [groups.member()], now: () => senderClock);
      final b = net.add('b', groups: [groups.member()], now: () => receiverClock);
      b.node.maxMessageAge = maxAge;
      net.connect('a', 'b');
      a.node.send(a.groups.first, senderName: 'A', text: 'heure');
      net.run();
      return b.inbox.map((m) => m.text).toList();
    }

    test('même heure : livré', () async {
      expect(await receiveWith(senderClock: base, receiverClock: base), ['heure']);
    });

    test('une heure d\'écart : toujours livré (étiquettes des heures voisines)', () async {
      expect(
        await receiveWith(
          senderClock: base.subtract(const Duration(minutes: 59)),
          receiverClock: base,
        ),
        ['heure'],
      );
    });

    test('message de plus de 24 h : refusé', () async {
      expect(
        await receiveWith(
          senderClock: base.subtract(const Duration(hours: 25)),
          receiverClock: base,
        ),
        isEmpty,
      );
    });

    test('la durée d\'effacement des réglages s\'applique à l\'âge accepté', () async {
      expect(
        await receiveWith(
          senderClock: base.subtract(const Duration(hours: 3)),
          receiverClock: base,
          maxAge: const Duration(hours: 1),
        ),
        isEmpty,
      );
    });

    test('message daté du futur : refusé au-delà de 10 minutes', () async {
      expect(
        await receiveWith(
          senderClock: base.add(const Duration(minutes: 5)),
          receiverClock: base,
        ),
        ['heure'],
      );
      expect(
        await receiveWith(
          senderClock: base.add(const Duration(minutes: 30)),
          receiverClock: base,
        ),
        isEmpty,
      );
    });
  });

  group('ce qu\'un observateur voit', () {
    test('le texte n\'apparaît nulle part dans la trame', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      net.phones['p0']!.node.send(
        net.phones['p0']!.groups.first,
        senderName: 'Camille',
        text: 'rendez-vous derrière la gare',
      );
      final text = String.fromCharCodes(net.onAir.first);
      expect(text.contains('gare'), isFalse);
      expect(text.contains('Camille'), isFalse);
    });

    test('deux envois du même texte donnent des trames différentes', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final p0 = net.phones['p0']!;
      p0.node.send(p0.groups.first, senderName: 'A', text: 'même texte');
      p0.node.send(p0.groups.first, senderName: 'A', text: 'même texte');
      expect(net.onAir[0], isNot(net.onAir[1]));
    });

    test('la longueur ne trahit pas la longueur exacte du texte', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final p0 = net.phones['p0']!;
      p0.node.send(p0.groups.first, senderName: 'A', text: 'a');
      p0.node.send(p0.groups.first, senderName: 'A', text: 'b' * 20);
      expect(net.onAir[0].length, net.onAir[1].length);
    });

    test('l\'étiquette du groupe change d\'une heure à l\'autre', () {
      var now = DateTime.utc(2026, 10, 18, 12);
      final groups = SimGroups(crypto);
      final net = SimNetwork(crypto);
      final a = net.add('a', groups: [groups.member()], now: () => now);
      net.add('b', groups: [groups.member()]);
      net.connect('a', 'b');
      a.node.send(a.groups.first, senderName: 'A', text: '1');
      now = now.add(const Duration(hours: 2));
      a.node.send(a.groups.first, senderName: 'A', text: '2');
      final tagOne = net.onAir[0].sublist(2, 18);
      final tagTwo = net.onAir[1].sublist(2, 18);
      expect(tagOne, isNot(tagTwo));
    });

    test('deux groupes n\'ont jamais la même étiquette', () {
      final net = SimNetwork(crypto);
      final one = net.add('a', groups: [SimGroups(crypto).member()]);
      final two = net.add('b', groups: [SimGroups(crypto).member()]);
      net.add('c');
      net.connect('a', 'c');
      net.connect('b', 'c');
      one.node.send(one.groups.first, senderName: 'A', text: 'x');
      two.node.send(two.groups.first, senderName: 'B', text: 'x');
      expect(net.onAir[0].sublist(2, 18), isNot(net.onAir[1].sublist(2, 18)));
    });
  });

  group('envoi', () {
    test('message vide ou trop long refusé', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final p0 = net.phones['p0']!;
      expect(() => p0.node.send(p0.groups.first, senderName: 'A', text: ''), throwsArgumentError);
      expect(
        () => p0.node.send(p0.groups.first, senderName: 'A', text: 'x' * 301),
        throwsArgumentError,
      );
      p0.node.send(p0.groups.first, senderName: 'A', text: 'x' * 300);
    });

    test('pseudo trop long refusé', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final p0 = net.phones['p0']!;
      expect(
        () => p0.node.send(p0.groups.first, senderName: 'n' * 25, text: 'a'),
        throwsArgumentError,
      );
    });

    test('le plus gros message tient dans une écriture Bluetooth de 512 octets', () {
      final groups = SimGroups(crypto);
      final net = chain(2, groups);
      final p0 = net.phones['p0']!;
      p0.node.send(p0.groups.first, senderName: 'n' * 24, text: 'é' * 150);
      expect(net.onAir.first.length + 2, lessThanOrEqualTo(512));
    });
  });
}

/// Un faux voisin qui garde les trames qu'on lui envoie.
class _Capture implements MeshLink {
  _Capture(this.frames);

  final List<Uint8List> frames;

  @override
  String get id => 'capture';

  @override
  Future<void> send(Uint8List frame) async => frames.add(frame);
}
