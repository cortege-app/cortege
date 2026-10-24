import 'dart:io';

import 'package:cortege/app_controller.dart';
import 'package:cortege/crypto/vault_crypto.dart';
import 'package:cortege/share/app_sharer.dart';
import 'package:cortege/ui/app.dart';
import 'package:cortege/ui/share_screens.dart';
import 'package:cortege/ui/theme.dart';
import 'package:cortege/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_hardware.dart';

class _FakeSharer implements AppSharer {
  _FakeSharer({this.package, this.problem, this.opens = true});

  final AppPackage? package;
  final String? problem;
  final bool opens;
  var sent = 0;

  @override
  Future<AppPackage> prepare() async {
    if (problem != null) throw AppShareException(problem!);
    return package!;
  }

  @override
  Future<bool> send() async {
    sent++;
    return opens;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VaultCrypto crypto;
  late Directory dir;

  setUpAll(() async {
    crypto = await VaultCrypto.create();
  });

  setUp(() => dir = Directory.systemTemp.createTempSync('cortege_share'));

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Un fichier encore tenu : le dossier temporaire reste.
    }
  });

  AppController controllerWith(AppSharer sharer) => AppController(
        store: VaultStore(
          crypto: crypto,
          hardware: MemoryHardwareSecretStore(),
          directory: dir,
          kdf: KdfParams.cheapForTests,
        ),
        appSharer: sharer,
      );

  Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // Lire un fichier par morceaux demande autant de tours d'attente et d'images
  // simulées qu'il y a de morceaux : on s'arrête dès que ce qu'on attend est là.
  Future<void> settle(WidgetTester tester, {Finder? until}) async {
    for (var i = 0; i < 400; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (until != null && until.evaluate().isNotEmpty) return;
    }
  }

  test('l\'empreinte s\'écrit en quatre groupes de quatre signes', () {
    expect(shortFingerprint([0x0a, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5, 0x06, 0x17, 0x99, 0x99]), '0ab1 c2d3 e4f5 0617');
    expect(shortFingerprint(List.filled(32, 0)), '0000 0000 0000 0000');
  });

  testWidgets('l\'écran explique, montre la taille et l\'empreinte, et ouvre le partage', (tester) async {
    bigScreen(tester);
    final apk = File('${dir.path}/Cortege.apk')..writeAsBytesSync(Uint8List.fromList(List.generate(3 * 1024 * 1024, (i) => i % 251)));
    final sharer = _FakeSharer(package: AppPackage(apk, apk.lengthSync()));
    final controller = controllerWith(sharer);
    addTearDown(controller.dispose);

    await tester.pumpWidget(app(ShareAppScreen(controller: controller)));
    await settle(tester, until: find.text('Envoyer l\'appli'));

    expect(find.textContaining('sans internet'), findsOneWidget);
    expect(find.textContaining('Ton code, tes messages et tes groupes n\'y sont pas'), findsOneWidget);
    expect(find.textContaining('personne en qui tu as confiance'), findsOneWidget);
    expect(find.text('3.0 Mo'), findsOneWidget);
    final expected = shortFingerprint(
      await tester.runAsync(() async => (await _hash(crypto, apk))) as List<int>,
    );
    expect(find.text(expected), findsOneWidget);

    await tester.tap(find.text('Envoyer l\'appli'));
    await tester.pump();

    expect(sharer.sent, 1);
    expect(find.textContaining('Impossible d\'ouvrir'), findsNothing);
  });

  testWidgets('si le partage d\'Android ne s\'ouvre pas, on le dit', (tester) async {
    bigScreen(tester);
    final apk = File('${dir.path}/Cortege.apk')..writeAsBytesSync([1, 2, 3, 4]);
    final controller = controllerWith(_FakeSharer(package: AppPackage(apk, 4), opens: false));
    addTearDown(controller.dispose);

    await tester.pumpWidget(app(ShareAppScreen(controller: controller)));
    await settle(tester, until: find.text('Envoyer l\'appli'));
    await tester.tap(find.text('Envoyer l\'appli'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Impossible d\'ouvrir le partage d\'Android'), findsOneWidget);
  });

  testWidgets('une appli qui ne peut pas se copier n\'offre pas d\'envoi', (tester) async {
    bigScreen(tester);
    final controller = controllerWith(
      _FakeSharer(problem: 'Cette installation est en plusieurs morceaux : son fichier ne s\'installerait pas chez l\'autre personne.'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(app(ShareAppScreen(controller: controller)));
    await settle(tester, until: find.textContaining('plusieurs morceaux'));

    expect(find.textContaining('plusieurs morceaux'), findsOneWidget);
    expect(find.text('Envoyer l\'appli'), findsNothing);
    expect(find.text('Empreinte'), findsNothing);
  });

  group('le canal Android', () {
    const channel = MethodChannel('org.cortege.app/share');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('la copie préparée devient un fichier avec sa taille', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'prepare');
        return {'path': '/cache/share/Cortege.apk', 'size': 55000000};
      });

      final package = await const PlatformAppSharer().prepare();

      expect(package.file.path, '/cache/share/Cortege.apk');
      expect(package.size, 55000000);
    });

    test('une installation en plusieurs morceaux est refusée avec une phrase claire', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => {'error': 'split'});

      await expectLater(
        const PlatformAppSharer().prepare(),
        throwsA(isA<AppShareException>().having((e) => e.message, 'message', contains('plusieurs morceaux'))),
      );
    });

    test('une copie ratée, ou une réponse bizarre, est une erreur et pas un plantage', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => {'error': 'copy'});
      await expectLater(const PlatformAppSharer().prepare(), throwsA(isA<AppShareException>()));

      messenger.setMockMethodCallHandler(channel, (call) async => {'path': 3});
      await expectLater(const PlatformAppSharer().prepare(), throwsA(isA<AppShareException>()));

      messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
      await expectLater(const PlatformAppSharer().prepare(), throwsA(isA<AppShareException>()));
    });

    test('sans le code Android, l\'envoi dit non et la préparation dit pourquoi', () async {
      messenger.setMockMethodCallHandler(channel, null);

      expect(await const PlatformAppSharer().send(), isFalse);
      await expectLater(
        const PlatformAppSharer().prepare(),
        throwsA(isA<AppShareException>().having((e) => e.message, 'message', contains('pas disponible'))),
      );
    });

    test('l\'envoi rend ce qu\'Android répond', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'send');
      expect(await const PlatformAppSharer().send(), isTrue);

      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await const PlatformAppSharer().send(), isFalse);
    });
  });

  testWidgets('l\'accueil propose « Partager l\'appli »', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = controllerWith(const NoAppSharer());
    await tester.runAsync(() async {
      await controller.start();
      await controller.setUp(pin: '483920');
    });
    addTearDown(controller.dispose);

    await tester.pumpWidget(CortegeApp(controller: controller));
    await tester.pump();
    await tester.pump();

    expect(find.text('Partager l\'appli'), findsOneWidget);
    expect(find.textContaining('sans internet'), findsOneWidget);
    // Le code de ces tests n'a pas de minuteur d'effacement à laisser tourner.
    controller.lock();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<List<int>> _hash(VaultCrypto crypto, File file) async {
  // Le même calcul que l'écran : BLAKE2b par libsodium.
  final consumer = crypto.sodium.crypto.genericHash.createConsumer(outLen: 32);
  await for (final chunk in file.openRead()) {
    consumer.add(Uint8List.fromList(chunk));
  }
  return consumer.close();
}
