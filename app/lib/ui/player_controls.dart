import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'components.dart';

/// Colours of the controls: the dark player, or the themed line popup.
class ControlColors {
  final Color fg, subtle, placeholder, line, brand, bubble;
  const ControlColors({required this.fg, required this.subtle, required this.placeholder, required this.line, required this.brand, required this.bubble});

  static ControlColors get player => ControlColors(
        fg: PlayerPalette.fg,
        subtle: PlayerPalette.subtle,
        placeholder: PlayerPalette.placeholder,
        line: PlayerPalette.line,
        brand: PlayerPalette.brand,
        bubble: const Color(0xF22B2E35),
      );

  static ControlColors of(AppTheme t) => ControlColors(
        fg: t.textPrimary,
        subtle: t.textSecondary,
        placeholder: t.textTertiary,
        line: t.stroke,
        brand: t.brand,
        bubble: t.isDark ? const Color(0xF22B2E35) : const Color(0xF21A1C20),
      );
}

/// Seek bar, times and transport (−5 s, play/pause, +5 s) for one song. It owns its 100 ms clock,
/// so only the controls repaint while music plays, not the whole player. Used by the player and,
/// in [compact] form, by the line explanation popup.
class PlaybackControls extends StatefulWidget {
  final String songID;
  final bool compact;
  final ControlColors? colors;

  /// Live scrub position while dragging, then null when the finger lifts.
  final ValueChanged<double?>? onScrub;

  /// After any seek (bar, ±5 s, line step), with the target position.
  final ValueChanged<double>? onSeek;

  const PlaybackControls({super.key, required this.songID, this.compact = false, this.colors, this.onScrub, this.onSeek});

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> with SingleTickerProviderStateMixin {
  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  late final Timer _clock = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (mounted) setState(() {});
  });
  double? _scrub;
  int? _snapIndex;

  @override
  void initState() {
    super.initState();
    _clock; // start the clock
  }

  @override
  void dispose() {
    _clock.cancel();
    _zoom.dispose();
    super.dispose();
  }

  static double durationOf(AppModel model, Song song, List<LyricLine> lines) {
    final d = song.duration ?? (model.isNowPlaying(song) ? model.nowPlaying?.track.duration : null);
    if (d != null && d > 0) return d;
    final last = lines.lastWhere((l) => l.start != null, orElse: () => LyricLine(songID: song.id, index: 0, start: 0, text: ''));
    return (last.start ?? 0) + 5;
  }

  void _seek(AppModel model, Song song, double target, double duration) {
    final t = target.clamp(0.0, duration);
    model.seekSong(song, t);
    widget.onSeek?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final song = model.collection.song(widget.songID);
    if (song == null) return const SizedBox();
    final c = widget.colors ?? ControlColors.player;
    final lines = model.collection.linesFor(song.id);
    final synced = song.lyricsType == LyricsType.synced;
    final duration = durationOf(model, song, lines);
    final live = model.positionOf(song);
    final position = (_scrub ?? live ?? 0).clamp(0.0, duration);
    final active = live != null;
    final isPlaying = active && model.isPlayingSong(song);
    final canSeek = synced && duration > 0;
    final timeStyle = TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: -0.18, color: c.subtle, fontFeatures: const [FontFeature.tabularFigures()]);

    final transport = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _ctrl(c, Icons.replay_5_rounded, tr('5초 뒤로'), active ? () => _seek(model, song, position - 5, duration) : null, widget.compact),
      SizedBox(width: widget.compact ? 28 : 44),
      Semantics(
        button: true,
        label: isPlaying ? tr('일시정지') : tr('재생'),
        excludeSemantics: true,
        child: Material(
          color: c.fg.withValues(alpha: 0.1),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            // Always enabled: plain-lyrics songs (common from Spotify) play too.
            onTap: () => model.togglePlaySong(song),
            child: SizedBox(
              width: widget.compact ? 48 : 60,
              height: widget.compact ? 48 : 60,
              child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: widget.compact ? 26 : 30, color: c.fg),
            ),
          ),
        ),
      ),
      SizedBox(width: widget.compact ? 28 : 44),
      _ctrl(c, Icons.forward_5_rounded, tr('5초 앞으로'), active ? () => _seek(model, song, position + 5, duration) : null, widget.compact),
    ]);

    final bar = _SeekBar(
      colors: c,
      duration: duration,
      position: position,
      enabled: canSeek,
      scrubbing: _scrub != null,
      zoom: _zoom,
      height: widget.compact ? 40 : 56,
      snapIndex: _snapIndex,
      ticks: [for (final l in lines) if (l.start != null && l.text.trim().isNotEmpty) l.start!],
      segments: [
        for (final l in lines)
          if (l.start != null && model.collection.isSaved(song.id, l.index)) (l.index, l.start!, l.end ?? l.start! + 5),
      ],
      preview: (sec) {
        final i = SyncEngine.lineIndex(sec - song.offset, lines);
        if (i == null) return null;
        final l = lines[i];
        final tr0 = model.settings.showTranslation && !model.translationSkipped(song.id) ? model.collection.translationText(song.id, l.index, model.target.code) : null;
        return (l.text, tr0, model.collection.isSaved(song.id, l.index));
      },
      onScrubStart: () {
        HapticFeedback.selectionClick();
        _zoom.forward();
      },
      onScrub: (raw, threshold) {
        // The playhead catches on line starts: strongly on saved lines, lightly on the others,
        // so a release lands exactly where a line begins.
        int? hit;
        var best = double.infinity;
        for (final l in lines) {
          if (l.start == null || l.text.trim().isEmpty) continue;
          final saved = model.collection.isSaved(song.id, l.index);
          final reach = saved ? threshold * 1.6 : threshold * 0.6;
          final d = (raw - l.start!).abs();
          if (d <= reach && d < best) {
            best = d;
            hit = l.index;
          }
        }
        final before = _scrub == null ? null : SyncEngine.lineIndex(_scrub!, lines);
        final value = hit != null ? lines.firstWhere((l) => l.index == hit).start! : raw;
        final after = SyncEngine.lineIndex(value, lines);
        if (hit != _snapIndex && hit != null && model.collection.isSaved(song.id, hit)) {
          HapticFeedback.lightImpact();
        } else if (before != null && after != before) {
          HapticFeedback.selectionClick(); // a soft tick for each line crossed
        }
        setState(() {
          _snapIndex = hit;
          _scrub = value;
        });
        widget.onScrub?.call(value);
      },
      onScrubEnd: () {
        final target = _scrub;
        _zoom.reverse();
        setState(() {
          _scrub = null;
          _snapIndex = null;
        });
        widget.onScrub?.call(null);
        if (target != null) _seek(model, song, target, duration);
      },
      onStep: (forward) {
        // Screen readers: one line forward or back.
        final cur = SyncEngine.lineIndex(position - song.offset, lines) ?? -1;
        final next = forward ? lines.where((l) => l.start != null && l.index > cur).firstOrNull : lines.where((l) => l.start != null && l.index < cur).lastOrNull;
        _seek(model, song, next == null ? (forward ? duration : 0.0) : next.start! + song.offset, duration);
      },
    );

    final times = Row(children: [
      AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 150),
        style: _scrub != null ? timeStyle.copyWith(color: c.fg, fontWeight: FontWeight.w600) : timeStyle,
        child: Text(position.mmss),
      ),
      const Spacer(),
      if (!synced)
        Text(tr('일반 가사라 위치 이동이 없어요'), style: timeStyle)
      else
        Text('-${max(0.0, duration - position).mmss}', style: timeStyle),
    ]);

    return Column(mainAxisSize: MainAxisSize.min, children: [
      bar,
      Padding(padding: const EdgeInsets.only(top: 2), child: times),
      SizedBox(height: widget.compact ? 4 : 10),
      transport,
    ]);
  }

  Widget _ctrl(ControlColors c, IconData icon, String label, VoidCallback? onTap, bool compact) => IconButton(
        tooltip: label,
        onPressed: onTap,
        iconSize: compact ? 24 : 28,
        color: c.fg,
        disabledColor: c.line,
        icon: Icon(icon),
      );
}

/// Seek bar: elapsed fill, a faint tick for every lyric line, saved lines in the accent colour.
/// While scrubbing it zooms in, shows a bubble with the time and the lyric line you will land on,
/// and slows down (fine scrubbing) when the finger moves up away from the bar.
class _SeekBar extends StatefulWidget {
  final ControlColors colors;
  final double duration;
  final double position;
  final bool enabled;
  final bool scrubbing;
  final Animation<double> zoom;
  final double height;
  final int? snapIndex;
  final List<double> ticks;
  final List<(int, double, double)> segments;
  final (String, String?, bool)? Function(double sec) preview;
  final VoidCallback onScrubStart;
  final void Function(double raw, double threshold) onScrub;
  final VoidCallback onScrubEnd;
  final void Function(bool forward) onStep;

  const _SeekBar({
    required this.colors,
    required this.duration,
    required this.position,
    required this.enabled,
    required this.scrubbing,
    required this.zoom,
    required this.height,
    required this.snapIndex,
    required this.ticks,
    required this.segments,
    required this.preview,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onStep,
  });

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double _raw = 0; // unsnapped scrub position in seconds
  double _speed = 1;

  /// Finger above the bar: full speed within 40 px, half within 110 px, then a quarter.
  static double _speedFor(double dy) => dy > -40 ? 1 : (dy > -110 ? 0.5 : 0.25);

  @override
  Widget build(BuildContext context) {
    final w0 = widget;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final threshold = 10 / w * w0.duration;
      void jumpTo(Offset p) {
        _raw = (p.dx / w).clamp(0.0, 1.0) * w0.duration;
        w0.onScrub(_raw, threshold);
      }

      final preview = w0.scrubbing ? w0.preview(w0.position) : null;
      final bubbleX = w0.duration > 0 ? (w0.position / w0.duration).clamp(0.0, 1.0) * w : 0.0;
      return Semantics(
        slider: true,
        label: tr('재생 위치'),
        value: '${w0.position.mmss} / ${w0.duration.mmss}',
        increasedValue: tr('다음 줄'),
        decreasedValue: tr('이전 줄'),
        onIncrease: w0.enabled ? () => w0.onStep(true) : null,
        onDecrease: w0.enabled ? () => w0.onStep(false) : null,
        child: Stack(clipBehavior: Clip.none, children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: w0.enabled
                ? (d) {
                    _speed = 1;
                    w0.onScrubStart();
                    jumpTo(d.localPosition);
                  }
                : null,
            onHorizontalDragUpdate: w0.enabled
                ? (d) {
                    final s = _speedFor(d.localPosition.dy);
                    if (s != _speed) setState(() => _speed = s);
                    _raw = (_raw + d.delta.dx / w * w0.duration * s).clamp(0.0, w0.duration);
                    w0.onScrub(_raw, threshold * s);
                  }
                : null,
            onHorizontalDragEnd: w0.enabled ? (_) => w0.onScrubEnd() : null,
            onHorizontalDragCancel: w0.enabled ? w0.onScrubEnd : null,
            onTapDown: w0.enabled
                ? (d) {
                    w0.onScrubStart();
                    jumpTo(d.localPosition);
                  }
                : null,
            onTapUp: w0.enabled ? (_) => w0.onScrubEnd() : null,
            child: AnimatedBuilder(
              animation: w0.zoom,
              builder: (_, _) => CustomPaint(
                size: Size(w, w0.height),
                painter: _SeekPainter(
                  colors: w0.colors,
                  duration: w0.duration,
                  position: w0.position,
                  zoom: Curves.easeOut.transform(w0.zoom.value),
                  ticks: w0.ticks,
                  segments: w0.segments,
                  snapIndex: w0.snapIndex,
                  enabled: w0.enabled,
                ),
              ),
            ),
          ),
          if (w0.scrubbing) _bubble(w, bubbleX, preview),
        ]),
      );
    });
  }

  /// Time, the line under the playhead and its translation, kept inside the screen edges.
  Widget _bubble(double w, double x, (String, String?, bool)? line) {
    const bw = 248.0;
    final c = widget.colors;
    final left = (x - bw / 2).clamp(-8.0, w - bw + 8);
    const fg = Color(0xFFF3F4F5), sub = Color(0xFFB0B3BA);
    return Positioned(
      left: left,
      bottom: widget.height + 2,
      width: bw,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: c.bubble,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: line?.$3 == true ? c.brand : const Color(0xFF393D46)),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(widget.position.mmss, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg, fontFeatures: [FontFeature.tabularFigures()])),
              if (line?.$3 == true) ...[
                const SizedBox(width: 6),
                Icon(Icons.star_rounded, size: 14, color: c.brand),
              ],
              const Spacer(),
              if (_speed < 1) Text(_speed == 0.5 ? tr('정밀 ½×') : tr('정밀 ¼×'), style: const TextStyle(fontSize: 11, color: sub)),
            ]),
            if (line != null) ...[
              const SizedBox(height: 4),
              Text(line.$1, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.3, color: fg)),
              if (line.$2 != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(line.$2!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: sub)),
                ),
            ] else
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('♪ 간주'), style: const TextStyle(fontSize: 13, color: sub))),
            if (_speed == 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('위로 끌어올리면 더 세밀하게 움직여요'), style: const TextStyle(fontSize: 10, color: Color(0xFF868B94))),
              ),
          ]),
        ),
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  final ControlColors colors;
  final double duration, position, zoom;
  final List<double> ticks;
  final List<(int, double, double)> segments;
  final int? snapIndex;
  final bool enabled;
  _SeekPainter({
    required this.colors,
    required this.duration,
    required this.position,
    required this.zoom,
    required this.ticks,
    required this.segments,
    required this.snapIndex,
    required this.enabled,
  });

  static const zMax = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final w = size.width;
    final p = (position / duration).clamp(0.0, 1.0);
    final z = 1 + (zMax - 1) * zoom;
    final trackW = w * z;
    final dx = p * w * (1 - z); // zoom around the playhead
    final h = 6 + 6 * zoom;
    final cy = size.height * 0.64;
    final ph = p * w;
    double x(double sec) => dx + sec / duration * trackW;
    final dim = enabled ? 1.0 : 0.45;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(-21, 0, w + 42, size.height));
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(dx, cy - h / 2, trackW, h), Radius.circular(h / 2));
    canvas.drawRRect(track, Paint()..color = colors.line.withValues(alpha: dim));
    // Elapsed part.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(-21, 0, ph, size.height));
    canvas.drawRRect(track, Paint()..color = colors.fg.withValues(alpha: 0.55 * dim));
    canvas.restore();
    // A faint tick at every line start, clearer while zoomed.
    final tick = Paint()
      ..color = Colors.black.withValues(alpha: 0.35 + 0.2 * zoom)
      ..strokeWidth = 1;
    for (final t in ticks) {
      final tx = x(t);
      canvas.drawLine(Offset(tx, cy - h / 2 + 1), Offset(tx, cy + h / 2 - 1), tick);
    }
    for (final (i, s, e) in segments) {
      final sh = i == snapIndex ? h * 1.7 : h;
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(x(s), cy - sh / 2, max(x(s) + 2, x(e)), cy + sh / 2), Radius.circular(sh / 2));
      canvas.drawRRect(r, Paint()..color = colors.brand.withValues(alpha: dim));
    }
    canvas.restore();

    // Star pins above saved lines; they fade out while zoomed.
    if (zoom < 1) {
      final pin = Paint()..color = colors.brand.withValues(alpha: (1 - zoom) * dim);
      for (final (_, s, e) in segments) {
        canvas.drawPath(_star(Offset((s + e) / 2 / duration * w, cy - 24 - 4 * zoom), 6), pin);
      }
    }

    // Playhead: a slim bar that grows into a knob while scrubbing.
    final lineH = 22 + 14 * zoom;
    final head = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ph, cy), width: 3 + 2 * zoom, height: lineH), const Radius.circular(3));
    canvas.drawRRect(head.inflate(2), Paint()..color = const Color(0x38000000));
    canvas.drawRRect(head, Paint()..color = colors.fg.withValues(alpha: enabled ? 1 : 0.6));
  }

  Path _star(Offset c, double r) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.45;
      final a = -pi / 2 + i * pi / 5;
      final pt = c + Offset(cos(a) * rr, sin(a) * rr);
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_SeekPainter o) =>
      o.position != position ||
      o.zoom != zoom ||
      o.duration != duration ||
      o.snapIndex != snapIndex ||
      o.enabled != enabled ||
      o.colors != colors ||
      o.segments.length != segments.length ||
      o.ticks.length != ticks.length;
}
