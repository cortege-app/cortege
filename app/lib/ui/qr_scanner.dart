import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mesh/qr_codec.dart';
import 'theme.dart';
import 'widgets.dart';

/// Caméra et lecture d'un code QR, à l'intérieur de l'appli : le décodage se
/// fait en Dart, sans service de Google. À chaque texte lu, [onText] est appelé ;
/// c'est à l'écran qui l'utilise d'arrêter la lecture ([paused]) dès qu'il a ce
/// qu'il voulait.
///
/// Le bouton de collage sert de secours quand la caméra n'y arrive pas
/// (reflets, soleil) : le code copié sur l'autre téléphone, transmis par un
/// autre moyen, se colle ici.
class QrScanner extends StatefulWidget {
  const QrScanner({
    super.key,
    required this.onText,
    this.paused = false,
    this.message,
    this.messageIsError = false,
    this.pasteLabel = 'Coller le code copié',
  });

  final void Function(String text) onText;
  final bool paused;
  final String? message;
  final bool messageIsError;
  final String pasteLabel;

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  CameraController? _camera;
  String? _error;
  var _busy = false;
  var _streaming = false;
  var _analyzed = 0;
  var _lastTry = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_openCamera());
  }

  @override
  void didUpdateWidget(QrScanner old) {
    super.didUpdateWidget(old);
    if (old.paused != widget.paused) unawaited(_syncStream());
  }

  @override
  void dispose() {
    final camera = _camera;
    _camera = null;
    if (camera != null) unawaited(camera.dispose());
    super.dispose();
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _error = 'Pas de caméra sur ce téléphone.');
        return;
      }
      final description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        description,
        // Haute définition : un QR dense vu de 20 centimètres demande au moins
        // 4 à 6 pixels par carré pour être lu malgré le flou.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      _camera = camera;
      await _syncStream();
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code.toLowerCase().contains('denied')
            ? 'La caméra est refusée. Autorise-la dans les réglages d\'Android pour scanner un QR.'
            : 'La caméra ne démarre pas.';
      });
    }
  }

  Future<void> _syncStream() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      if (widget.paused && _streaming) {
        _streaming = false;
        await camera.stopImageStream();
      } else if (!widget.paused && !_streaming) {
        _streaming = true;
        await camera.startImageStream(_onImage);
      }
    } on CameraException {
      _streaming = false;
      if (mounted) setState(() => _error = 'La caméra ne redémarre pas.');
    }
  }

  void _onImage(CameraImage image) {
    if (_busy || widget.paused) return;
    final now = DateTime.now();
    if (now.difference(_lastTry) < const Duration(milliseconds: 400)) return;
    _lastTry = now;
    _busy = true;
    _analyzed++;
    if (mounted && _analyzed % 3 == 0) setState(() {});

    final width = image.width;
    final height = image.height;
    final plane = image.planes.first;
    // Le plan de luminance peut avoir du remplissage en bout de ligne.
    final luminance = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final start = y * plane.bytesPerRow;
      luminance.setRange(y * width, (y + 1) * width, plane.bytes, start);
    }
    unawaited(
      decodeQrInBackground(luminance: luminance, width: width, height: height)
          .then(_onDecoded, onError: (Object error) {
        if (kDebugMode) debugPrint('cortege: lecture du QR impossible ($error)');
      }).whenComplete(() => _busy = false),
    );
  }

  void _onDecoded(String? text) {
    if (text == null || !mounted || widget.paused) return;
    widget.onText(text);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    if (mounted) widget.onText(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final camera = _camera;
    final message = _error ?? widget.message;
    final isError = _error != null || widget.messageIsError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _error != null && camera == null
              ? const SizedBox.shrink()
              : camera != null && camera.value.isInitialized
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        Center(child: CameraPreview(camera)),
                        // Cadre pour viser : le QR doit le remplir.
                        FractionallySizedBox(
                          widthFactor: 0.8,
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Palette.accent, width: 4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            message ??
                'Remplis le cadre avec le QR, à 15 ou 25 cm, sans bouger. Monte la luminosité de l\'autre écran.',
            style: theme.bodyLarge?.copyWith(color: isError ? Palette.danger : Palette.text),
          ),
        ),
        if (camera != null && _error == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Images analysées : $_analyzed',
              style: theme.bodyMedium?.copyWith(color: Palette.muted),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: BigButton(label: widget.pasteLabel, primary: false, onPressed: _paste),
        ),
      ],
    );
  }
}
