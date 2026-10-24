import 'dart:io';

import 'package:flutter/services.dart';

/// Lit les assets directement sur le disque, de façon synchrone. Dans
/// `testWidgets`, le temps est simulé : une vraie lecture asynchrone ne
/// se termine jamais et le test reste bloqué.
class DiskAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(File(key).readAsBytesSync());
}
