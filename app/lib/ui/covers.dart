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
    // Under ~72 px the title is unreadable and only clutters the sleeve (list rows, calendar).
    if (text != null && text.isNotEmpty && w >= 72) {
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
              Text(tr('기본 커버를 고르거나 앨범에서 사진을 골라요'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            _GalleryButton(onTap: () => _pickPhoto(context)),
            for (var i = 0; i < DiscCoverStyle.presets.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Semantics(
                  button: true,
                  label: tr('기본 커버 {0}', [i + 1]),
                  child: GestureDetector(
                    onTap: () => _generate(context, DiscCoverStyle.presets[i]),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(colors: [DiscCoverStyle.presets[i].a, DiscCoverStyle.presets[i].b, DiscCoverStyle.presets[i].a]),
                        border: Border.all(color: t.stroke),
                      ),
                      child: Center(
                          child: Container(
                              width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: DiscCoverStyle.presets[i].background))),
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

  Future<void> _generate(BuildContext context, DiscCoverStyle style) async {
    final model = context.readModel;
    final png = await DiscCoverPainter(style).toPng();
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

/// The eight default covers of the Figma component '커버 기본 이미지' (node 290:2996), as used by
/// the cover-select prototype: a gradient disc on a dark square.
class DiscCoverStyle {
  final Color background, a, b;
  const DiscCoverStyle(this.background, this.a, this.b);

  static const presets = [
    DiscCoverStyle(Color(0xFF3F323C), Color(0xFFFF6E9B), Color(0xFFFF9D54)),
    DiscCoverStyle(Color(0xFF3E3933), Color(0xFFFFA75A), Color(0xFFB1F94E)),
    DiscCoverStyle(Color(0xFF3F3D31), Color(0xFFFFD051), Color(0xFF5DF945)),
    DiscCoverStyle(Color(0xFF343F3B), Color(0xFF7EE7A0), Color(0xFF44E4E0)),
    DiscCoverStyle(Color(0xFF2C3E3E), Color(0xFF00D7AB), Color(0xFF007CC9)),
    DiscCoverStyle(Color(0xFF2A3E50), Color(0xFF00ADF3), Color(0xFF5648F1)),
    DiscCoverStyle(Color(0xFF363346), Color(0xFF927EF5), Color(0xFFFF5EE6)),
    DiscCoverStyle(Color(0xFF3C3E40), Color(0xFFDDE1E6), Color(0xFFB0ABC2)),
  ];

  /// The preset for a song without album art, picked from its title as in the prototype
  /// (h = h × 31 + code point, unsigned 32-bit).
  static int indexFor(String title) {
    var h = 0;
    for (final r in title.runes) {
      h = (h * 31 + r) & 0xFFFFFFFF;
    }
    return h % presets.length;
  }
}

class DiscCoverPainter extends CustomPainter {
  final DiscCoverStyle style;
  const DiscCoverPainter(this.style);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = style.background);
    final c = Offset(w / 2, w / 2);
    final r = w * 0.36;
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = ui.Gradient.sweep(c, [style.a, style.b, style.a], const [0, 0.5, 1], TileMode.clamp, -pi / 2, 3 * pi / 2));
    canvas.drawCircle(c, r * 0.22, Paint()..color = style.background);
  }

  @override
  bool shouldRepaint(DiscCoverPainter old) => old.style != style;

  Future<Uint8List?> toPng({double size = 768}) async {
    final rec = ui.PictureRecorder();
    paint(Canvas(rec), Size(size, size));
    final img = await rec.endRecording().toImage(size.round(), size.round());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }
}

class DiscCover extends StatelessWidget {
  final DiscCoverStyle style;
  final double radius;
  const DiscCover(this.style, {super.key, this.radius = 0});

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: CustomPaint(painter: DiscCoverPainter(style))),
      );
}
