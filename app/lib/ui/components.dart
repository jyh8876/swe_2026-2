import 'dart:math';

import 'package:flutter/material.dart';

import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/models.dart';

// ─────────────── Buttons (FG-00 note: "Later" and "Connect" are the same size) ───────────────

class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const PrimaryButton(this.label, {super.key, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.accent.withValues(alpha: 0.4),
          disabledForegroundColor: t.onAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _labelRow(label, icon),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const SecondaryButton(this.label, {super.key, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: t.textPrimary,
          disabledForegroundColor: t.textPrimary.withValues(alpha: 0.4),
          side: BorderSide(color: t.textPrimary.withValues(alpha: onPressed == null ? 0.3 : 0.8)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _labelRow(label, icon),
      ),
    );
  }
}

Widget _labelRow(String label, IconData? icon) => icon == null
    ? Text(label)
    : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 6), Flexible(child: Text(label))]);

// ─────────────── Vinyl record ───────────────

/// Concentric-groove record used on onboarding, translating and in LP cards.
class VinylRecord extends StatelessWidget {
  final Color? labelColor;
  final int grooves;
  final bool filled;
  const VinylRecord({super.key, this.labelColor, this.grooves = 3, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _VinylPainter(
          fill: filled ? t.vinyl : null,
          groove: filled ? t.background.withValues(alpha: 0.15) : t.stroke,
          label: labelColor ?? t.surfaceRaised,
          hole: t.background,
          grooves: grooves,
        ),
      ),
    );
  }
}

class _VinylPainter extends CustomPainter {
  final Color? fill;
  final Color groove, label, hole;
  final int grooves;
  _VinylPainter({this.fill, required this.groove, required this.label, required this.hole, required this.grooves});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = min(size.width, size.height) / 2;
    if (fill != null) canvas.drawCircle(c, r, Paint()..color = fill!);
    final stroke = Paint()
      ..color = groove
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < grooves; i++) {
      canvas.drawCircle(c, r * (1 - i * 0.1) - 0.5, stroke);
    }
    canvas.drawCircle(c, r * 0.36, Paint()..color = label);
    canvas.drawCircle(c, r * 0.04, Paint()..color = hole);
  }

  @override
  bool shouldRepaint(_VinylPainter old) =>
      old.fill != fill || old.groove != groove || old.label != label || old.grooves != grooves;
}

/// Spinning record for FG-04. Respects reduced motion (SIR-2).
class SpinningRecord extends StatefulWidget {
  const SpinningRecord({super.key});
  @override
  State<SpinningRecord> createState() => _SpinningRecordState();
}

class _SpinningRecordState extends State<SpinningRecord> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: const VinylRecord(grooves: 4));
}

// ─────────────── Cover art ───────────────

class CoverArt extends StatelessWidget {
  final String? path;
  final double radius;
  const CoverArt({super.key, this.path, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final f = path == null ? null : CoverStore.file(path!);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          color: t.surfaceRaised,
          child: (f != null && f.existsSync())
              ? Image.file(f, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox())
              : null,
        ),
      ),
    );
  }
}

// ─────────────── LP card (FG-01: record peeking out of the sleeve) ───────────────

enum BadgeStatus {
  translating('번역 중'),
  done('완료'),
  conquered('정복 완료'),
  retry('재시도');

  final String label;
  const BadgeStatus(this.label);
}

class LPCard extends StatelessWidget {
  final Song song;
  final bool isTranslating;
  final bool highlighted;
  const LPCard({super.key, required this.song, this.isTranslating = false, this.highlighted = false});

  BadgeStatus get _status {
    if (song.isConquered) return BadgeStatus.conquered;
    if (isTranslating || song.status == SongStatus.translating) return BadgeStatus.translating;
    if (song.status == SongStatus.failed) return BadgeStatus.retry;
    return BadgeStatus.done;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Semantics(
      label: '${song.title}, ${song.artist}, ${_status.label}',
      button: true,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.15,
            child: LayoutBuilder(builder: (context, c) {
              final sleeve = c.maxHeight;
              final disc = sleeve * 0.92;
              return ClipRect(
                child: Stack(children: [
                  Positioned(
                    left: c.maxWidth - disc + sleeve * 0.05,
                    top: (sleeve - disc) / 2,
                    width: disc,
                    height: disc,
                    child: Container(
                      decoration: song.isConquered
                          ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.gold, width: 2))
                          : null,
                      child: VinylRecord(labelColor: song.isConquered ? t.gold : t.surfaceRaised, grooves: 2, filled: true),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    width: sleeve,
                    height: sleeve,
                    child: Container(
                      foregroundDecoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: highlighted ? Border.all(color: t.textPrimary, width: 2) : null,
                      ),
                      child: CoverArt(path: song.coverPath),
                    ),
                  ),
                ]),
              );
            }),
          ),
          const SizedBox(height: 6),
          Text(song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(song.artist,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          StatusBadge(_status),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final BadgeStatus status;
  const StatusBadge(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final conquered = status == BadgeStatus.conquered;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: conquered ? t.accent : t.surfaceRaised, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status == BadgeStatus.translating) ...[
          SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textSecondary)),
          const SizedBox(width: 4),
        ],
        Text(status.label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: conquered ? t.onAccent : t.textSecondary)),
      ]),
    );
  }
}

// ─────────────── Lyrics availability badge (FG-02) ───────────────

class LyricsBadge extends StatelessWidget {
  final Availability availability;
  const LyricsBadge(this.availability, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final label = switch (availability) {
      Availability.synced => '싱크 가사',
      Availability.plain => '일반 가사',
      Availability.none => '가사 없음',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: t.stroke), borderRadius: BorderRadius.circular(99)),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: availability == Availability.none ? t.textTertiary : t.textSecondary)),
    );
  }
}

// ─────────────── Engine badge (SIR-3) ───────────────

class EngineBadge extends StatelessWidget {
  final String label;
  const EngineBadge(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Semantics(
      label: '번역 엔진: $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(label.startsWith('On-device') ? Icons.smartphone : Icons.cloud_outlined, size: 12, color: t.textSecondary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: t.textSecondary)),
        ]),
      ),
    );
  }
}

// ─────────────── Skeleton loader (RQ-11) ───────────────

class SkeletonLines extends StatefulWidget {
  final int count;
  const SkeletonLines({super.key, this.count = 4});
  @override
  State<SkeletonLines> createState() => _SkeletonLinesState();
}

class _SkeletonLinesState extends State<SkeletonLines> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800), lowerBound: 0.5)
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Semantics(
      label: '해설을 불러오는 중',
      child: FadeTransition(
        opacity: _c,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.count; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  height: 14,
                  width: i == widget.count - 1 ? 180 : double.infinity,
                  decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(4)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────── Misc ───────────────

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 13, color: context.theme.textSecondary));
}

/// ONRQ-6: non-blocking, states cause and the one fixing action.
class BannerView extends StatelessWidget {
  final String message;
  final String? actionTitle;
  final VoidCallback? action;
  final VoidCallback dismiss;
  const BannerView({super.key, required this.message, this.actionTitle, this.action, required this.dismiss});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(
          color: t.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12)],
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 20, color: t.textPrimary),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: TextStyle(fontSize: 13, color: t.textPrimary))),
          if (actionTitle != null && action != null)
            TextButton(
                onPressed: action,
                child: Text(actionTitle!, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
          IconButton(
              onPressed: dismiss, icon: Icon(Icons.close, size: 18, color: t.textPrimary), tooltip: '닫기'),
        ]),
      ),
    );
  }
}

/// A rounded text field matching the Figma inputs.
class OutlinedField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int? minLines;
  final int? maxLines;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final bool obscure;
  const OutlinedField(
      {super.key,
      required this.controller,
      required this.hint,
      this.minLines,
      this.maxLines = 1,
      this.style,
      this.onChanged,
      this.obscure = false});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.stroke));
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      obscureText: obscure,
      autocorrect: false,
      style: style ?? TextStyle(color: t.textPrimary, fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintMaxLines: 3,
        hintStyle: TextStyle(color: t.textTertiary, fontSize: 14),
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: t.textSecondary)),
        contentPadding: const EdgeInsets.all(14),
      ),
    );
  }
}

extension Mmss on double {
  /// 72 → "1:12"
  String get mmss {
    final total = floor();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// A simple bottom-sheet action list (stands in for iOS context menus / confirmation dialogs).
Future<T?> showActionSheet<T>(BuildContext context,
    {String? title, String? message, required List<SheetAction<T>> actions}) {
  final t = context.theme;
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: t.surface,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(title, textAlign: TextAlign.center, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(message, textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          ),
        for (final a in actions)
          ListTile(
            leading: a.icon == null ? null : Icon(a.icon, color: a.destructive ? const Color(0xFFE57373) : t.textPrimary),
            title: Text(a.label, style: TextStyle(color: a.destructive ? const Color(0xFFE57373) : t.textPrimary)),
            enabled: a.enabled,
            onTap: () => Navigator.pop(ctx, a.value),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

class SheetAction<T> {
  final String label;
  final IconData? icon;
  final T value;
  final bool destructive;
  final bool enabled;
  const SheetAction(this.label, this.value, {this.icon, this.destructive = false, this.enabled = true});
}

Future<bool> confirmDialog(BuildContext context,
    {required String title, String? message, required String confirm, String cancel = '취소', bool destructive = false}) async {
  final t = context.theme;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: TextStyle(color: t.textPrimary, fontSize: 18)),
      content: message == null ? null : Text(message, style: TextStyle(color: t.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel, style: TextStyle(color: t.textSecondary))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm,
              style: TextStyle(color: destructive ? const Color(0xFFE57373) : t.textPrimary, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  return r ?? false;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
