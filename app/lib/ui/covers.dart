import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import 'components.dart';

/// Disc colours offered for a generated cover ("CD 색만 고르면 자동으로").
const cdColors = [
  Color(0xFFFF6B9D),
  Color(0xFFFFA94D),
  Color(0xFFFFD43B),
  Color(0xFF8CE99A),
  Color(0xFF38D9A9),
  Color(0xFF4DABF7),
  Color(0xFF9775FA),
  Color(0xFFDEE2E6),
];

/// A generated album cover in the style of the Notion reference ("My Mix"): a gradient disc on a
/// dark square with the title in bold. The same seed always gives the same colours.
class GeneratedCover extends StatelessWidget {
  final String seed;
  final String? label;
  final Color? color;
  final double radius;
  const GeneratedCover({super.key, required this.seed, this.label, this.color, this.radius = 2});

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(painter: CoverPainter(seed: seed, label: label, color: color)),
        ),
      );
}

class CoverPainter extends CustomPainter {
  final String seed;
  final String? label;
  final Color? color;
  CoverPainter({required this.seed, this.label, this.color});

  /// Two disc colours: the chosen colour and a hue-shifted partner, or a pair picked by the seed.
  (Color, Color) get colors {
    final base = color ?? cdColors[_hash(seed) % cdColors.length];
    final hsl = HSLColor.fromColor(base);
    final shift = color == null ? 40.0 + _hash('$seed!') % 80 : 50.0;
    return (base, hsl.withHue((hsl.hue + shift) % 360).withLightness((hsl.lightness * 0.9).clamp(0.3, 0.8)).toColor());
  }

  static int _hash(String s) => s.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0x7fffffff);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final (a, b) = colors;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Color.alphaBlend(a.withValues(alpha: 0.10), const Color(0xFF2A2C31)));

    final c = Offset(w * 0.5, w * 0.46);
    final r = w * 0.40;
    final disc = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = ui.Gradient.sweep(c, [a, b, Color.lerp(a, b, 0.5)!.withValues(alpha: 1), a], [0, 0.45, 0.75, 1], TileMode.clamp, -pi / 2, 3 * pi / 2),
    );
    canvas.drawCircle(c, r, Paint()..shader = ui.Gradient.radial(c, r, [Colors.white.withValues(alpha: 0.18), Colors.transparent], [0, 1]));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(0.6, w / 300)
      ..color = Colors.black.withValues(alpha: 0.08);
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(c, r * (0.45 + i * 0.12), groove);
    }
    canvas.drawCircle(c, r * 0.13, Paint()..color = const Color(0xFF2A2C31).withValues(alpha: 0.9));
    canvas.drawCircle(c, r * 0.04, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawArc(disc.deflate(r * 0.08), -pi * 0.85, pi * 0.35, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w / 60
          ..color = Colors.white.withValues(alpha: 0.22));

    final text = label;
    if (text != null && text.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: w * 0.125,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -w * 0.003,
            color: Colors.white,
            fontFamily: AppTheme.fontFamilyOverride,
            shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: w / 40)],
          ),
        ),
        maxLines: 2,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w * 0.86);
      tp.paint(canvas, Offset(w * 0.07, w * 0.93 - tp.height));
    }
  }

  @override
  bool shouldRepaint(CoverPainter old) => old.seed != seed || old.label != label || old.color != color;

  /// Renders the cover to a PNG for the song's cover file.
  Future<Uint8List?> toPng({double size = 768}) async {
    final rec = ui.PictureRecorder();
    paint(Canvas(rec), Size(size, size));
    final img = await rec.endRecording().toImage(size.round(), size.round());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }
}

/// Cover choice shown while a song translates (Notion "번역하는 동안 시간 때울 거리"):
/// pick a photo from the gallery, or just a disc colour and a cover is made automatically.
class CoverPicker extends StatelessWidget {
  final String songID;
  const CoverPicker({super.key, required this.songID});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final song = model.collection.song(songID);
    if (song == null) return const SizedBox();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 56,
            height: 56,
            child: song.coverPath != null ? CoverArt(path: song.coverPath, radius: 2) : GeneratedCover(seed: song.id, label: song.title),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('기다리는 동안 앨범 커버를 골라요'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary)),
              const SizedBox(height: 2),
              Text(tr('CD 색만 고르면 커버가 자동으로 만들어져요'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            _GalleryButton(onTap: () => _pickPhoto(context)),
            for (final c in cdColors)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Semantics(
                  button: true,
                  label: tr('CD 색으로 커버 만들기'),
                  child: GestureDetector(
                    onTap: () => _generate(context, c),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(colors: [c, CoverPainter(seed: '', color: c).colors.$2, c]),
                        border: Border.all(color: t.stroke),
                      ),
                      child: Center(child: Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: t.background))),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _pickPhoto(BuildContext context) async {
    final model = context.readModel;
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
      if (x != null) model.setCoverFromFile(songID, x.path);
    } catch (_) {
      if (context.mounted) showMessage(context, tr('사진을 불러오지 못했어요.'));
    }
  }

  Future<void> _generate(BuildContext context, Color c) async {
    final model = context.readModel;
    final song = model.collection.song(songID);
    if (song == null) return;
    final png = await CoverPainter(seed: song.id, label: song.title, color: c).toPng();
    if (png != null) model.setCoverBytes(songID, png);
  }
}

class _GalleryButton extends StatelessWidget {
  final VoidCallback onTap;
  const _GalleryButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Material(
      color: t.surfaceRaised,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.photo_library_outlined, size: 18, color: t.textPrimary),
            const SizedBox(width: 6),
            Text(tr('앨범에서'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.textPrimary)),
          ]),
        ),
      ),
    );
  }
}
