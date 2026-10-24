import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../mesh/compass.dart';
import 'theme.dart';

/// Une flèche qui montre où aller. [bearing] est le cap de la cible depuis ici
/// (degrés depuis le nord) ; [headings] le cap du téléphone. La flèche tourne
/// avec le téléphone : elle pointe toujours vers la cible.
class CompassView extends StatefulWidget {
  const CompassView({
    super.key,
    required this.bearing,
    required this.headings,
    this.indicative = false,
  });

  final double bearing;
  final Stream<double> headings;

  /// Vrai quand la cible est plus proche que l'incertitude des positions : la
  /// flèche est grisée et dit qu'elle n'est pas fiable.
  final bool indicative;

  @override
  State<CompassView> createState() => _CompassViewState();
}

class _CompassViewState extends State<CompassView> {
  StreamSubscription<double>? _subscription;
  double? _heading;
  var _failed = false;
  var _ended = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(CompassView old) {
    super.didUpdateWidget(old);
    if (old.headings != widget.headings) _listen();
  }

  void _listen() {
    _subscription?.cancel();
    _failed = false;
    _ended = false;
    _subscription = widget.headings.listen(
      (heading) => setState(() => _heading = smoothAngle(_heading, heading)),
      onError: (Object _) => setState(() => _failed = true),
      onDone: () => setState(() => _ended = true),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final heading = _heading;
    if (heading == null) {
      return Text(
        _failed || _ended
            ? 'Ce téléphone n\'a pas de boussole. Utilise la direction écrite.'
            : 'La boussole démarre...',
        style: theme.bodyMedium?.copyWith(color: Palette.muted),
      );
    }
    final relative = relativeAngle(widget.bearing, heading);
    return Column(
      children: [
        Semantics(
          label: turnInstruction(relative),
          child: SizedBox(
            width: 240,
            height: 240,
            child: CustomPaint(
              painter: _CompassPainter(
                relative: relative,
                north: -heading,
                indicative: widget.indicative,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.indicative ? 'Indicatif : ${turnInstruction(relative).toLowerCase()}' : turnInstruction(relative),
          style: theme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'Le téléphone regarde vers ${heading.round()}°, la cible est vers ${widget.bearing.round()}° (0° : nord, 90° : est).',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'Tiens le téléphone à plat, ou debout devant toi. Éloigne-le des objets en métal.',
          style: theme.bodyMedium?.copyWith(color: Palette.muted),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _CompassPainter extends CustomPainter {
  _CompassPainter({required this.relative, required this.north, required this.indicative});

  /// Flèche grisée : la direction n'est pas fiable à cette distance.
  final bool indicative;

  /// Angle de la cible par rapport au haut du téléphone, en degrés.
  final double relative;

  /// Angle du nord par rapport au haut du téléphone, en degrés.
  final double north;

  static double _rad(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;
    final ring = Paint()
      ..color = Palette.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, ring);

    // Le nord : un repère sur le cercle, tourné avec le téléphone.
    final northAngle = _rad(north);
    final northMark = center + Offset(math.sin(northAngle), -math.cos(northAngle)) * radius;
    canvas.drawCircle(northMark, 9, Paint()..color = Palette.text);
    final label = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, northMark - Offset(label.width / 2, label.height / 2));

    // La flèche vers la cible.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(_rad(relative));
    final arrow = Path()
      ..moveTo(0, -radius * 0.78)
      ..lineTo(radius * 0.34, radius * 0.1)
      ..lineTo(radius * 0.11, radius * 0.1)
      ..lineTo(radius * 0.11, radius * 0.6)
      ..lineTo(-radius * 0.11, radius * 0.6)
      ..lineTo(-radius * 0.11, radius * 0.1)
      ..lineTo(-radius * 0.34, radius * 0.1)
      ..close();
    canvas.drawPath(arrow, Paint()..color = indicative ? Palette.line : Palette.accent);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CompassPainter old) =>
      old.relative != relative || old.north != north || old.indicative != indicative;
}
