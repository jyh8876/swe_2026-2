import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';

import '../app/i18n.dart';
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
          textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
          textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _labelRow(label, icon),
      ),
    );
  }
}

Widget _labelRow(String label, IconData? icon) => icon == null
    ? Text(tr(label))
    : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), SizedBox(width: 6), Flexible(child: Text(tr(label)))]);

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
  late final _c = AnimationController(vsync: this, duration: Duration(seconds: 4));

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
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: VinylRecord(grooves: 4));
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
              ? Image.file(f, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => SizedBox())
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
  BadgeStatus(this.label);
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
      label: '${song.title}, ${song.artist}, ${tr(_status.label)}',
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
          SizedBox(height: 6),
          Text(song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
          SizedBox(height: 2),
          Text(song.artist,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary, fontSize: 12)),
          SizedBox(height: 6),
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
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: conquered ? t.accent : t.surfaceRaised, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status == BadgeStatus.translating) ...[
          SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textSecondary)),
          SizedBox(width: 4),
        ],
        Text(tr(status.label),
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
      Availability.synced => tr('싱크 가사'),
      Availability.plain => tr('일반 가사'),
      Availability.none => tr('가사 없음'),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
      label: tr('번역 엔진: {0}', [label]),
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(label.startsWith('On-device') ? Icons.smartphone : Icons.cloud_outlined, size: 12, color: t.textSecondary),
          SizedBox(width: 4),
          Text(tr(label), style: TextStyle(fontSize: 11, color: t.textSecondary)),
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
  late final _c = AnimationController(vsync: this, duration: Duration(milliseconds: 800), lowerBound: 0.5)
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
      label: tr('해설을 불러오는 중'),
      child: FadeTransition(
        opacity: _c,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.count; i++)
              Padding(
                padding: EdgeInsets.only(bottom: 10),
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
  Widget build(BuildContext context) => Text(tr(text), style: TextStyle(fontSize: 13, color: context.theme.textSecondary));
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
        margin: EdgeInsets.symmetric(horizontal: 16),
        padding: EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(
          color: t.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 12)],
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 20, color: t.textPrimary),
          SizedBox(width: 12),
          Expanded(child: Text(tr(message), style: TextStyle(fontSize: 13, color: t.textPrimary))),
          if (actionTitle != null && action != null)
            TextButton(
                onPressed: action,
                child: Text(actionTitle!, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
          IconButton(
              onPressed: dismiss, icon: Icon(Icons.close, size: 18, color: t.textPrimary), tooltip: tr('닫기')),
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
  final Widget? suffix;
  const OutlinedField(
      {super.key,
      required this.controller,
      required this.hint,
      this.minLines,
      this.maxLines = 1,
      this.style,
      this.onChanged,
      this.obscure = false,
      this.suffix});

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
        hintText: tr(hint),
        hintMaxLines: 3,
        hintStyle: TextStyle(color: t.textTertiary, fontSize: 14),
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: t.textSecondary)),
        contentPadding: EdgeInsets.all(14),
        suffixIcon: suffix,
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
    useRootNavigator: true,
    backgroundColor: t.surface,
    showDragHandle: true,
    // Long menus (the song menu has eight items) scroll instead of overflowing short screens.
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(tr(title), textAlign: TextAlign.center, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
          ),
        if (message != null)
          Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(tr(message), textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          ),
        for (final a in actions)
          ListTile(
            leading: a.icon == null ? null : Icon(a.icon, color: a.destructive ? Color(0xFFE57373) : t.textPrimary),
            title: Text(tr(a.label), style: TextStyle(color: a.destructive ? Color(0xFFE57373) : t.textPrimary)),
            enabled: a.enabled,
            onTap: () => Navigator.pop(ctx, a.value),
          ),
        SizedBox(height: 8),
        ]),
      ),
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
      title: Text(tr(title), style: TextStyle(color: t.textPrimary, fontSize: 18)),
      content: message == null ? null : Text(tr(message), style: TextStyle(color: t.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(cancel), style: TextStyle(color: t.textSecondary))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr(confirm),
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
    ..showSnackBar(SnackBar(content: Text(tr(message))));
}

/// Explains notification access before opening Android's settings for it (music-app sync).
Future<bool> confirmMusicAppAccess(BuildContext context) => confirmDialog(
      context,
      title: tr('음악 앱과 연결할까요?'),
      message: Platform.isIOS
          ? tr('지금 듣는 곡과 재생 위치를 읽으려면 Apple Music 접근 권한이 필요해요. 다음 화면에서 허용해 주세요. 라이브러리 정보는 기기 밖으로 보내지 않아요.')
          : tr('지금 듣는 곡과 재생 위치를 읽으려면 Android의 \'알림 접근\' 권한이 필요해요. 다음 화면에서 Vinylo를 켜 주세요. 알림 내용은 읽거나 저장하지 않아요.'),
      confirm: Platform.isIOS ? tr('계속') : tr('설정 열기'),
    );

// ─────────────── Translation language (Figma 160:4943 "번역 언어 설정") ───────────────

/// A filled select box; tapping opens the "번역 언어 설정" sheet. [value] null = the app's
/// language ("기본").
class LanguageSelectField extends StatelessWidget {
  final String? value;
  final Language appTarget;
  final ValueChanged<String?> onChanged;
  const LanguageSelectField({super.key, required this.value, required this.appTarget, required this.onChanged});

  String _label(String? code) =>
      code == null ? tr('{0}(기본)', [appTarget.nativeName]) : Language.supported.firstWhere((l) => l.code == code, orElse: () => appTarget).nativeName;

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          final picked = await _pick(context);
          if (picked != null) onChanged(picked.isEmpty ? null : picked);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(children: [
            Expanded(child: Text(_label(value), style: TextStyle(fontSize: 15, color: t.textPrimary))),
            Icon(Icons.keyboard_arrow_down, color: t.textSecondary),
          ]),
        ),
      ),
    );
  }

  /// '' = the default, a language code otherwise; null when dismissed.
  Future<String?> _pick(BuildContext context) {
    final t = context.theme;
    final options = <(String, String)>[
      ('', _label(null)),
      for (final l in Language.supported.where((l) => l.code != appTarget.code)) (l.code, l.nativeName),
    ];
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      backgroundColor: t.surfaceRaised,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(children: [
              Expanded(child: Text(tr('번역 언어 설정'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: t.textPrimary))),
              IconButton(tooltip: tr('닫기'), icon: Icon(Icons.close, color: t.textPrimary), onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final (code, label) in options)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  title: Text(label, style: TextStyle(fontSize: 16, color: t.textPrimary)),
                  trailing: (value ?? '') == code ? const Icon(Icons.check, color: Color(0xFF3B82F6)) : null,
                  onTap: () => Navigator.pop(ctx, code),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Korean wraps between any two syllables, which strands one character on the last line.
/// A word joiner between the syllables of each word keeps words whole and breaks only at spaces.
String keepWords(String s) => s.split(' ').map((w) => w.runes.map(String.fromCharCode).join('\u2060')).join(' ');

/// Fades and lifts its child in once, [index] steps after the screen opens (list rows).
class FadeIn extends StatelessWidget {
  final Widget child;
  final int index;
  const FadeIn({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final i = index.clamp(0, 8);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + i * 50),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 10), child: c)),
      child: child,
    );
  }
}

/// Gives a tappable a small press-down response, so taps feel acknowledged.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.97});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _down && !MediaQuery.of(context).disableAnimations ? widget.scale : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}
