import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/theme.dart';

/// The record on the translating screen. It reacts to the work: every new line gives it a spin
/// boost, a soft elastic bounce and a ripple; a ring in the accent colour fills with progress and
/// the label takes on the accent colour as the song gets translated. One ticker drives everything.
class TranslatingRecord extends StatefulWidget {
  /// 0…1.
  final double progress;

  /// Increases by one for each newly shown line; every change triggers a pulse.
  final int pulse;
  final bool done;
  const TranslatingRecord({super.key, required this.progress, required this.pulse, this.done = false});

  @override
  State<TranslatingRecord> createState() => _TranslatingRecordState();
}

class _TranslatingRecordState extends State<TranslatingRecord> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _angle = 0, _boost = 0, _bounce = 0, _bounceV = 0, _shownProgress = 0;
  final _ripples = <double>[]; // ages in seconds
  bool _reduced = false;

  static const _baseSpeed = 0.9; // radians per second

  @override
  void initState() {
    super.initState();
    _shownProgress = widget.progress;
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.of(context).disableAnimations;
  }

  @override
  void didUpdateWidget(TranslatingRecord old) {
    super.didUpdateWidget(old);
    if (widget.pulse > old.pulse) _kick(widget.done ? 2.2 : 1);
    if (widget.done && !old.done) _kick(2.6);
  }

  void _kick(double strength) {
    _boost = min(_boost + 5 * strength, 14);
    _bounceV += 2.4 * strength;
    if (_ripples.length < 6) _ripples.add(0);
  }

  void _tick(Duration now) {
    final dt = ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = now;
    if (_reduced) {
      _shownProgress = widget.progress;
    } else {
      _angle += (_baseSpeed + _boost) * dt;
      _boost *= exp(-3.2 * dt); // the spin boost settles in about a second
      // Damped spring for the bounce (scale = 1 + 0.06 · bounce).
      final force = -90 * _bounce - 9 * _bounceV;
      _bounceV += force * dt;
      _bounce += _bounceV * dt;
      _shownProgress += (widget.progress - _shownProgress) * min(1, dt * 6);
      for (var i = 0; i < _ripples.length; i++) {
        _ripples[i] += dt;
      }
      _ripples.removeWhere((a) => a > 1.1);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Semantics(
      label: '${(widget.progress * 100).round()}%',
      child: CustomPaint(
        painter: _RecordPainter(
          angle: _angle,
          scale: 1 + 0.06 * _bounce.clamp(-1.0, 1.5),
          progress: _shownProgress,
          ripples: List.of(_ripples),
          vinyl: t.isDark ? const Color(0xFF0E0F12) : const Color(0xFF1A1C20),
          track: t.stroke,
          brand: t.brand,
          label: Color.lerp(t.surfaceRaised, t.brand, (0.25 + 0.75 * _shownProgress).clamp(0.0, 1.0))!,
          hole: t.background,
        ),
      ),
    );
  }
}

class _RecordPainter extends CustomPainter {
  final double angle, scale, progress;
  final List<double> ripples;
  final Color vinyl, track, brand, label, hole;
  _RecordPainter({
    required this.angle,
    required this.scale,
    required this.progress,
    required this.ripples,
    required this.vinyl,
    required this.track,
    required this.brand,
    required this.label,
    required this.hole,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final full = min(size.width, size.height) / 2;
    final ringR = full * 0.96;
    final r = full * 0.84 * scale;

    // Ripples: one per new line, expanding and fading.
    for (final age in ripples) {
      final k = (age / 1.1).clamp(0.0, 1.0);
      canvas.drawCircle(
        c,
        r + (ringR - r) * 0.4 + full * 0.25 * Curves.easeOut.transform(k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - k)
          ..color = brand.withValues(alpha: 0.55 * (1 - k)),
      );
    }

    // Progress ring.
    final ring = Rect.fromCircle(center: c, radius: ringR);
    canvas.drawCircle(c, ringR, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = track.withValues(alpha: 0.6));
    canvas.drawArc(ring, -pi / 2, 2 * pi * progress.clamp(0.0, 1.0), false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = brand);

    // The disc.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    canvas.drawCircle(Offset.zero, r, Paint()..color = vinyl);
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.07);
    for (var i = 0; i < 9; i++) {
      canvas.drawCircle(Offset.zero, r * (0.46 + i * 0.058), groove);
    }
    // Sheen: two light wedges that turn with the record.
    final sheen = Paint()
      ..shader = SweepGradient(colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0.16),
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0.10),
        Colors.white.withValues(alpha: 0),
      ], stops: const [0.0, 0.08, 0.18, 0.5, 0.58, 0.68])
          .createShader(Rect.fromCircle(center: Offset.zero, radius: r));
    canvas.drawCircle(Offset.zero, r, sheen);
    // Label with a mark so the rotation is visible.
    canvas.drawCircle(Offset.zero, r * 0.34, Paint()..color = label);
    canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: r * 0.24), -0.6, 1.2, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.05
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.55));
    canvas.drawCircle(Offset.zero, r * 0.045, Paint()..color = hole);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RecordPainter o) => true;
}
