import 'dart:typed_data';

import 'package:cortege/mesh/channels.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/vault/vault_state.dart';

/// Fabrique les états de [count] personnes qui se sont toutes appairées : chacune
/// connaît la clé de signature et la chaîne de départ de toutes les autres.
class SimBuddies {
  SimBuddies(this.crypto, int count, {List<String>? names}) {
    tagKey = crypto.randomBytes(32);
    id = crypto.randomBytes(8);
    final pairs = [for (var i = 0; i < count; i++) crypto.newSigningKeyPair()];
    final chains = [for (var i = 0; i < count; i++) crypto.randomBytes(32)];
    final pairNames = names ?? [for (var i = 0; i < count; i++) 'P$i'];
    final now = DateTime.utc(2026, 10, 18, 12);
    for (var i = 0; i < count; i++) {
      records.add(
        BuddyRecord(
          id: id,
          tagKey: tagKey,
          ownName: pairNames[i],
          signPublic: pairs[i].publicKey,
          signSecret: pairs[i].secretKey.extractBytes(),
          sendChainKey: Uint8List.fromList(chains[i]),
          sendIndex: 0,
          members: [
            for (var j = 0; j < count; j++)
              if (j != i)
                BuddyMemberRecord(
                  name: pairNames[j],
                  signPublic: pairs[j].publicKey,
                  chainKey: Uint8List.fromList(chains[j]),
                  nextIndex: 0,
                ),
          ],
          createdAt: now,
          lastActivity: now,
        ),
      );
    }
  }

  final MeshCrypto crypto;
  late final Uint8List tagKey;
  late final Uint8List id;
  final records = <BuddyRecord>[];

  BuddyChannel channel(int index) => BuddyChannel(crypto, records[index]);
}
