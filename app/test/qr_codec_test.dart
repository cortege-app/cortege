import 'dart:typed_data';

import 'package:cortege/mesh/group.dart';
import 'package:cortege/mesh/mesh_crypto.dart';
import 'package:cortege/mesh/qr_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_sim.dart';

void main() {
  late MeshCrypto crypto;

  setUpAll(() async {
    crypto = await newMeshCrypto();
  });

  String roundTrip(String text, {int moduleSize = 6}) {
    final image = renderQr(encodeQr(text), moduleSize: moduleSize);
    return decodeQr(luminance: image.pixels, width: image.side, height: image.side)!;
  }

  test('un texte court survit à l\'aller-retour', () {
    expect(roundTrip('bonjour'), 'bonjour');
  });

  test('une vraie invitation de groupe survit à l\'aller-retour', () {
    final invite = GroupInvite(
      name: 'Équipe République',
      groupKey: crypto.randomBytes(32),
      eventSecret: crypto.randomBytes(32),
    );
    final read = roundTrip(invite.encode());
    final decoded = GroupInvite.decode(read);
    expect(decoded.name, 'Équipe République');
    expect(decoded.groupKey, invite.groupKey);
    expect(decoded.eventSecret, invite.eventSecret);
  });

  test('le plus gros nom de groupe tient dans un QR lisible', () {
    final invite = GroupInvite(
      name: 'x' * GroupInvite.maxNameBytes,
      groupKey: crypto.randomBytes(32),
      eventSecret: crypto.randomBytes(32),
    );
    expect(roundTrip(invite.encode()), invite.encode());
  });

  test('un QR vu de loin (petits modules) se lit encore', () {
    final invite = GroupInvite(
      name: 'Équipe',
      groupKey: crypto.randomBytes(32),
      eventSecret: crypto.randomBytes(32),
    );
    expect(roundTrip(invite.encode(), moduleSize: 3), invite.encode());
  });

  test('un QR flou et bruité, comme une photo d\'écran, se lit à 6 pixels par module', () {
    final invite = GroupInvite(
      name: 'Équipe',
      groupKey: crypto.randomBytes(32),
      eventSecret: crypto.randomBytes(32),
    );
    final clean = renderQr(encodeQr(invite.encode()), moduleSize: 6);
    final side = clean.side;
    // Flou 3 sur 3 puis bruit, grossièrement ce que voit une caméra de téléphone.
    final blurred = Uint8List(side * side);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        var sum = 0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            final yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= side || yy >= side) continue;
            sum += clean.pixels[yy * side + xx];
            count++;
          }
        }
        blurred[y * side + x] = (sum ~/ count + ((x * 7 + y * 13) % 41) - 20).clamp(0, 255);
      }
    }
    expect(decodeQr(luminance: blurred, width: side, height: side), invite.encode());
  });

  test('la lecture dans un autre isolate fonctionne', () async {
    final invite = GroupInvite(
      name: 'Équipe',
      groupKey: crypto.randomBytes(32),
      eventSecret: crypto.randomBytes(32),
    );
    final image = renderQr(encodeQr(invite.encode()), moduleSize: 5);
    final text = await decodeQrInBackground(
      luminance: image.pixels,
      width: image.side,
      height: image.side,
    );
    expect(text, invite.encode());
  });

  test('une image sans QR ne donne rien, sans exception', () {
    expect(decodeQr(luminance: Uint8List(200 * 200)..fillRange(0, 40000, 128), width: 200, height: 200), isNull);
    expect(decodeQr(luminance: Uint8List(10), width: 200, height: 200), isNull);
  });

  test('le QR n\'est pas reconnu comme invitation s\'il vient d\'ailleurs', () {
    final text = roundTrip('https://exemple.org/x');
    expect(() => GroupInvite.decode(text), throwsFormatException);
  });
}
