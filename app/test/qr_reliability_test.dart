import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/qr_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_sim.dart';

void main() {
  test('aucune invitation ne produit un QR illisible, même avec un nom répétitif', () async {
    final crypto = await newMeshCrypto();
    for (var i = 0; i < 300; i++) {
      final invite = GroupInvite(
        name: i.isEven ? 'x' * GroupInvite.maxNameBytes : 'Équipe $i',
        groupKey: crypto.randomBytes(32),
        eventSecret: crypto.randomBytes(32),
      );
      final text = invite.encode();
      final image = renderQr(encodeQr(text), moduleSize: 6);
      final read = decodeQr(luminance: image.pixels, width: image.side, height: image.side);
      expect(read, text, reason: 'invitation $i');
    }
  });
}
