import 'dart:io';
import 'dart:typed_data';

import 'package:cortege/organizer/event_file.dart';
import 'package:cortege/organizer/organizer_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  final fixture = File('test/fixtures/paris_fixture.pmtiles');

  setUp(() => dir = Directory.systemTemp.createTempSync('cortege_event_file'));
  tearDown(() => dir.deleteSync(recursive: true));

  File file(String name, List<int> bytes) => File('${dir.path}/$name')..writeAsBytesSync(bytes);

  Matcher rejected(PacketProblem problem) =>
      throwsA(isA<PacketRejected>().having((e) => e.problem, 'problème', problem));

  test('le paquet et la carte écrits ensemble se retrouvent séparément', () async {
    const packet = '{"cortege":"org1","key":"a","sig":"b","body":"c"}';
    final target = File('${dir.path}/evenement.cortege');

    await EventFile.write(packet: packet, map: fixture, target: target);
    final head = await EventFile.readHead(target);

    expect(head.kind, EventFileKind.bundle);
    expect(head.packetText, packet);
    expect(head.mapLength, fixture.lengthSync());
    expect(target.lengthSync(), head.mapStart + head.mapLength);
    final joined = target.readAsBytesSync().sublist(head.mapStart);
    expect(joined, fixture.readAsBytesSync());
    expect(File('${target.path}.tmp').existsSync(), isFalse);
  });

  test('un paquet seul reste un simple texte', () async {
    const packet = '{"cortege":"org1","key":"a","sig":"b","body":"c"}';
    final head = await EventFile.readHead(file('paquet.cortege', packet.codeUnits));

    expect(head.kind, EventFileKind.packet);
    expect(head.packetText, packet);
    expect(head.mapLength, 0);
  });

  test('une carte PMTiles seule est reconnue', () async {
    final head = await EventFile.readHead(fixture);

    expect(head.kind, EventFileKind.map);
    expect(head.packetText, isNull);
    expect(head.mapStart, 0);
    expect(head.mapLength, fixture.lengthSync());
  });

  test('le texte et la carte peuvent être lus sans charger la carte', () async {
    // 20 Mo de carte jointe : seule l'en-tête et le paquet sont lus.
    final big = File('${dir.path}/grosse.bin')..writeAsBytesSync(Uint8List(20 * 1024 * 1024));
    final target = File('${dir.path}/gros.cortege');
    await EventFile.write(packet: '{"x":1}', map: big, target: target);

    final head = await EventFile.readHead(target);

    expect(head.packetText, '{"x":1}');
    expect(head.mapLength, big.lengthSync());
  });

  test('un fichier qui n\'est pas à nous est refusé sans planter', () async {
    await expectLater(EventFile.readHead(file('vide.bin', const [])), rejected(PacketProblem.malformed));
    await expectLater(
      EventFile.readHead(file('gros.bin', Uint8List(OrganizerPacket.maxRawLength + 10)..fillRange(0, 10, 7))),
      rejected(PacketProblem.malformed),
    );
    // Le texte n'est pas de l'UTF-8.
    await expectLater(
      EventFile.readHead(file('latin1.txt', const [0x7b, 0xe9, 0xff, 0x7d])),
      rejected(PacketProblem.malformed),
    );
  });

  test('un en-tête de fichier unique abîmé est refusé', () async {
    final magic = EventFile.magic;
    List<int> withLength(int length, [List<int> rest = const []]) => [
          ...magic,
          (length >> 24) & 255,
          (length >> 16) & 255,
          (length >> 8) & 255,
          length & 255,
          ...rest,
        ];

    // Coupé avant la taille du paquet.
    await expectLater(EventFile.readHead(file('court.bin', magic)), rejected(PacketProblem.malformed));
    // Paquet de taille nulle.
    await expectLater(EventFile.readHead(file('zero.bin', withLength(0))), rejected(PacketProblem.malformed));
    // Taille annoncée plus grande que le fichier.
    await expectLater(
      EventFile.readHead(file('tronque.bin', withLength(500, List.filled(10, 0x41)))),
      rejected(PacketProblem.malformed),
    );
    // Paquet absurdement gros.
    await expectLater(
      EventFile.readHead(file('enorme.bin', withLength(OrganizerPacket.maxRawLength + 1))),
      rejected(PacketProblem.tooBig),
    );
  });
}
