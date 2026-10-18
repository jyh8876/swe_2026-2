import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'components.dart';
import 'line_detail.dart';

/// FG-06 Player · Lyrics, following the UI prototype (Figma 06 플레이어 · 가사 v2):
/// dark drifting backdrop, lyrics that follow the current line until the user scrolls,
/// "현재 줄로 이동" to resume, and a seek bar that marks saved lines and snaps to them.
/// Requirements: RQ-4, RQ-10, RQ-13, SSRD 3.1.1 modes, DCR-4, DCR-6, DCR-7.
class PlayerView extends StatefulWidget {
  final String songID;
  const PlayerView({super.key, required this.songID});
  @override
  State<PlayerView> createState() => _PlayerViewState();
}

enum _Mode { linkedSynced, linkedPlain, studyOnly }

class _PlayerViewState extends State<PlayerView> with TickerProviderStateMixin {
  late ListenSession _session = ListenSession(songID: widget.songID);
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 28));
  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  late final Timer _ticker;
  late AppModel _model;
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int? _lastIndex;
  bool _following = true;
  bool _programmaticScroll = false;
  double? _scrub;
  int? _snapIndex;
  bool _goldBurst = false;

  String get id => widget.songID;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _model = context.readModel;
    if (MediaQuery.of(context).disableAnimations) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ticker.cancel();
    _drift.dispose();
    _zoom.dispose();
    _scroll.dispose();
    _recordLater(_session);
    super.dispose();
  }

  // ── Derived state ──

  bool _isLinked(AppModel model, Song song) {
    final snap = model.nowPlaying;
    return snap != null && TrackMatcher.matches(song.trackKey, snap.track);
  }

  _Mode _mode(AppModel model, Song song) {
    if (!_isLinked(model, song)) return _Mode.studyOnly;
    return song.lyricsType == LyricsType.synced ? _Mode.linkedSynced : _Mode.linkedPlain;
  }

  SyncEngine _sync(AppModel model, Song song) {
    final e = SyncEngine(offset: song.offset);
    if (_isLinked(model, song) && model.nowPlaying != null) e.update(model.nowPlaying!);
    return e;
  }

  double _duration(AppModel model, Song song, List<LyricLine> lines) {
    final d = song.duration ?? (_isLinked(model, song) ? model.nowPlaying?.track.duration : null);
    if (d != null && d > 0) return d;
    final last = lines.lastWhere((l) => l.start != null, orElse: () => LyricLine(songID: id, index: 0, start: 0, text: ''));
    return (last.start ?? 0) + 5;
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final song = model.collection.song(id);
    if (song == null) {
      return const Scaffold(
        backgroundColor: PlayerPalette.background,
        body: Center(child: Text('노래를 찾을 수 없어요', style: TextStyle(color: PlayerPalette.subtle))),
      );
    }
    final lines = model.collection.linesFor(id);
    final mode = _mode(model, song);
    final engine = _sync(model, song);
    final current = mode == _Mode.linkedSynced ? engine.currentLineIndex(lines) : null;
    _onCurrentChanged(current, lines);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: PlayerPalette.background,
        body: Stack(children: [
          Positioned.fill(child: _Backdrop(animation: _drift)),
          SafeArea(
            child: Column(children: [
              _header(model, song, lines),
              if (mode == _Mode.studyOnly) _studyOnlyNote(song),
              Expanded(child: _lyrics(model, lines, current, mode)),
              _transport(model, song, lines, engine, mode),
            ]),
          ),
          if (_goldBurst) _goldOverlay(),
        ]),
      ),
    );
  }

  Widget _header(AppModel model, Song song, List<LyricLine> lines) {
    return SizedBox(
      height: 72,
      child: Row(children: [
        IconButton(
          tooltip: '홈으로 돌아가기',
          onPressed: () => model.pop(),
          icon: const Icon(Icons.chevron_left_rounded, size: 30, color: PlayerPalette.fg),
        ),
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: PlayerPalette.weak, borderRadius: BorderRadius.circular(10.2)),
          clipBehavior: Clip.antiAlias,
          child: song.coverPath != null ? CoverArt(path: song.coverPath, radius: 0) : const Icon(Icons.music_note_rounded, color: PlayerPalette.subtle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: PlayerPalette.fg)),
              ),
              if (song.isConquered) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.emoji_events_rounded, size: 16, color: Color(0xFFE3B341))),
            ]),
            const SizedBox(height: 2),
            Text(song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 18 / 14, letterSpacing: -0.21, color: PlayerPalette.subtle)),
          ]),
        ),
        IconButton(
          tooltip: '더보기',
          onPressed: () => _menu(model, song, lines),
          icon: const Icon(Icons.more_horiz_rounded, color: PlayerPalette.fg),
        ),
        const SizedBox(width: 8),
      ]),
    );
  }

  /// DCR-7: study-only state, stated once and quietly.
  Widget _studyOnlyNote(Song song) {
    final synced = song.lyricsType == LyricsType.synced;
    return Padding(
      padding: const EdgeInsets.fromLTRB(21, 0, 21, 4),
      child: Row(children: [
        const Icon(Icons.menu_book_rounded, size: 14, color: PlayerPalette.placeholder),
        const SizedBox(width: 6),
        Expanded(
          child: Text(synced ? '가사 공부 모드 · 재생을 누르면 데모로 싱크를 볼 수 있어요' : '가사 공부 모드 · 싱크 정보가 없는 가사예요',
              style: const TextStyle(fontSize: 12, color: PlayerPalette.placeholder)),
        ),
      ]),
    );
  }

  // ── Lyrics ──

  void _onCurrentChanged(int? index, List<LyricLine> lines) {
    if (index == _lastIndex) return;
    _lastIndex = index;
    if (index == null) return;
    _session.linesReached.add(index);
    if (_following) WidgetsBinding.instance.addPostFrameCallback((_) => _placeList(index));
    // End of a play-through: store the session and maybe suggest "Conquered" (RQ-13).
    if (index == lines.length - 1) {
      _endSession();
      if (_model.shouldSuggestConquered(id)) WidgetsBinding.instance.addPostFrameCallback((_) => _suggestConquer());
    }
  }

  /// Puts the current line at 42 % of the lyrics viewport, as in the prototype.
  void _placeList(int index, {bool instant = false, double at = 0.42}) {
    if (!mounted) return;
    final ctx = _keys[index]?.currentContext;
    if (ctx == null) return;
    _programmaticScroll = true;
    Scrollable.ensureVisible(
      ctx,
      alignment: at,
      duration: instant || MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 380),
      curve: Curves.easeInOutCubic,
    ).whenComplete(() => _programmaticScroll = false);
  }

  void _setFollowing(bool on) {
    if (on == _following) return;
    setState(() => _following = on);
    if (on && _lastIndex != null) _placeList(_lastIndex!);
  }

  Widget _lyrics(AppModel model, List<LyricLine> lines, int? current, _Mode mode) {
    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollStartNotification && n.dragDetails != null && !_programmaticScroll) _setFollowing(false);
          return false;
        },
        child: ShaderMask(
          // Lyrics fade out at the top and bottom edges.
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.14, 0.78, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: LayoutBuilder(
            builder: (context, c) => ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(21, c.maxHeight * 0.3, 13, c.maxHeight * 0.5),
              children: [for (final line in lines) _lyricRow(model, line, current, mode)],
            ),
          ),
        ),
      ),
      if (!_following && current != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 14,
          child: Center(
            child: Material(
              color: Colors.white,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _setFollowing(true),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Text('현재 줄로 이동', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF15171C))),
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _lyricRow(AppModel model, LyricLine line, int? current, _Mode mode) {
    // In study-only or plain mode every line is readable at full strength.
    final active = mode != _Mode.linkedSynced || line.index == current;
    final target = model.target.code;
    final translation = model.collection.translationText(id, line.index, target);
    final failed = model.collection.translation(id, line.index, target)?.outcome == Outcome.failed;
    final saved = model.collection.isSaved(id, line.index);

    return Padding(
      key: _keys.putIfAbsent(line.index, GlobalKey.new),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Semantics(
            button: true,
            hint: '탭하면 세부 설명을 볼 수 있어요',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openLine(line.index, mode),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    fontFamily: AppTheme.fontFamilyOverride,
                    fontSize: 18,
                    height: 24 / 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.36,
                    color: active ? PlayerPalette.fg : PlayerPalette.placeholder,
                  ),
                  child: Text(line.text),
                ),
                if (model.settings.showTranslation) ...[
                  const SizedBox(height: 4),
                  if (translation != null)
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamilyOverride,
                          fontSize: 14,
                          height: 18 / 14,
                          letterSpacing: -0.21,
                          color: active ? PlayerPalette.subtle : PlayerPalette.placeholder),
                      child: Text(translation),
                    )
                  else if (failed)
                    GestureDetector(
                      onTap: () => model.startTranslation(id),
                      child: const Text('번역 실패 — 다시 시도',
                          style: TextStyle(fontSize: 12, color: PlayerPalette.placeholder, decoration: TextDecoration.underline, decorationColor: PlayerPalette.placeholder)),
                    )
                  else if (model.isTranslating(id))
                    const Text('번역 중…', style: TextStyle(fontSize: 12, color: PlayerPalette.placeholder)),
                ],
              ]),
            ),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            padding: EdgeInsets.zero,
            tooltip: saved ? '저장한 문장에서 빼기' : '문장 저장',
            onPressed: () => model.toggleSaved(id, line.index),
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(saved ? Icons.star_rounded : Icons.star_outline_rounded,
                  key: ValueKey(saved), size: 22, color: saved ? PlayerPalette.brand : PlayerPalette.placeholder),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _openLine(int index, _Mode mode) async {
    _session.explanationsOpened.add(index);
    final wasFollowing = _following;
    _setFollowing(false);
    _placeList(index, at: 0.18);
    final replay = await showLineDetail(context, songID: id, index: index, canReplay: _model.collection.line(id, index)?.start != null);
    if (!mounted) return;
    if (replay == true) {
      _replayLine(index);
    } else if (wasFollowing) {
      _setFollowing(true);
    }
  }

  // ── Transport (RQ-4) ──

  Widget _transport(AppModel model, Song song, List<LyricLine> lines, SyncEngine engine, _Mode mode) {
    final synced = song.lyricsType == LyricsType.synced;
    final duration = _duration(model, song, lines);
    final position = (_scrub ?? engine.position() ?? 0).clamp(0.0, duration);
    final isPlaying = mode != _Mode.studyOnly && (model.nowPlaying?.isPlaying ?? false);
    final source = mode == _Mode.studyOnly ? null : model.source;
    final canSeek = synced && (mode == _Mode.studyOnly || (source?.capabilities.contains(SourceCapability.seek) ?? false));

    void togglePlay() {
      if (mode == _Mode.studyOnly) {
        if (synced) model.playDemo(song);
        return;
      }
      if (isPlaying) {
        source?.pause();
      } else {
        if (position >= duration - 0.2) source?.seek(0);
        source?.play();
      }
    }

    void jump(double delta) {
      if (mode == _Mode.studyOnly) return;
      source?.seek((position + delta).clamp(0.0, duration));
      _setFollowing(true);
    }

    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: PlayerPalette.line))),
      padding: const EdgeInsets.fromLTRB(21, 5, 21, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _SeekBar(
          duration: duration,
          position: position,
          enabled: canSeek,
          zoom: _zoom,
          snapIndex: _snapIndex,
          segments: [
            for (final l in lines)
              if (l.start != null && model.collection.isSaved(id, l.index)) (l.index, l.start!, l.end ?? l.start! + 5),
          ],
          onScrubStart: () {
            HapticFeedback.selectionClick();
            _zoom.forward();
            _setFollowing(true);
          },
          onScrub: (raw, threshold) {
            // The playhead catches on saved lines.
            int? hit;
            var best = double.infinity;
            for (final l in lines) {
              if (l.start == null || !model.collection.isSaved(id, l.index)) continue;
              final end = max(l.end ?? l.start! + 5, l.start! + threshold);
              if (raw >= l.start! - threshold && raw <= end) {
                final d = (raw - l.start!).abs();
                if (d < best) {
                  best = d;
                  hit = l.index;
                }
              }
            }
            if (hit != _snapIndex && hit != null) HapticFeedback.lightImpact();
            setState(() {
              _snapIndex = hit;
              _scrub = hit != null ? lines.firstWhere((l) => l.index == hit).start : raw;
            });
          },
          onScrubEnd: () {
            final target = _scrub;
            _zoom.reverse();
            setState(() {
              _scrub = null;
              _snapIndex = null;
            });
            if (target == null) return;
            if (mode == _Mode.studyOnly) {
              model.playDemo(song);
              model.source?.seek(target);
            } else {
              source?.seek(target);
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(children: [
            Text(position.mmss, style: _timeStyle),
            const Spacer(),
            Text('-${max(0.0, duration - position).mmss}', style: _timeStyle),
          ]),
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _ctrl(Icons.replay_5_rounded, '5초 뒤로', mode == _Mode.studyOnly ? null : () => jump(-5)),
          const SizedBox(width: 44),
          Semantics(
            button: true,
            label: isPlaying ? '일시정지' : '재생',
            excludeSemantics: true,
            child: Material(
              color: Colors.white.withValues(alpha: 0.1),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: synced || mode != _Mode.studyOnly ? togglePlay : null,
                child: SizedBox(
                  width: 60,
                  height: 60,
                  child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: PlayerPalette.fg),
                ),
              ),
            ),
          ),
          const SizedBox(width: 44),
          _ctrl(Icons.forward_5_rounded, '5초 앞으로', mode == _Mode.studyOnly ? null : () => jump(5)),
        ]),
      ]),
    );
  }

  static const _timeStyle = TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: -0.18, color: PlayerPalette.subtle, fontFeatures: [FontFeature.tabularFigures()]);

  Widget _ctrl(IconData icon, String label, VoidCallback? onTap) => IconButton(
        tooltip: label,
        onPressed: onTap,
        iconSize: 28,
        color: PlayerPalette.fg,
        disabledColor: PlayerPalette.line,
        icon: Icon(icon),
      );

  /// "이 줄 다시 듣기": jump to the line and play (starts the demo link in study-only mode).
  void _replayLine(int index) {
    final song = _model.collection.song(id);
    final line = _model.collection.line(id, index);
    if (song == null || line?.start == null) return;
    if (!_isLinked(_model, song)) _model.playDemo(song);
    final target = _sync(_model, song).seekTarget(line!) ?? max(0.0, line.start! + song.offset);
    _model.source?.seek(target);
    _model.source?.play();
    _setFollowing(true);
  }

  // ── Menu: timing, wrong lyrics, retranslate, conquer (DCR-4, RQ-10, RQ-13) ──

  Future<void> _menu(AppModel model, Song song, List<LyricLine> lines) async {
    final canConquer = model.canMarkConquered(id) || _session.linesReached.length >= max(1, (lines.length * 0.9).floor());
    final action = await showActionSheet<String>(
      context,
      title: '엔진: ${EngineFactory.label(model.settings.engine)}',
      message: '타이밍 조절 (현재 ${song.offset >= 0 ? '+' : ''}${song.offset.toStringAsFixed(1)}초)',
      actions: [
        const SheetAction('가사 0.5초 빠르게', 'faster', icon: Icons.remove),
        const SheetAction('가사 0.5초 느리게', 'slower', icon: Icons.add),
        if (song.offset != 0) const SheetAction('타이밍 초기화', 'reset', icon: Icons.restart_alt),
        const SheetAction('가사가 이상해요?', 'wrong', icon: Icons.help_outline),
        const SheetAction('현재 엔진으로 다시 번역', 'retranslate', icon: Icons.translate),
        if (song.isConquered)
          const SheetAction('정복 취소', 'unconquer', icon: Icons.undo)
        else
          SheetAction('이 노래 정복!', 'conquer', icon: Icons.emoji_events_outlined, enabled: canConquer),
      ],
    );
    switch (action) {
      case 'faster':
        model.setOffset(id, song.offset - SyncEngine.offsetStep);
      case 'slower':
        model.setOffset(id, song.offset + SyncEngine.offsetStep);
      case 'reset':
        model.setOffset(id, 0);
      case 'wrong':
        model.push(SearchRoute('${song.title} ${song.artist}'));
      case 'retranslate':
        model.retranslate(id);
      case 'unconquer':
        model.setConquered(id, false);
      case 'conquer':
        _conquer();
    }
  }

  // ── Mastery (RQ-13) — signature motion #3: the LP turns gold ──

  void _endSession() {
    _recordLater(_session);
    _session = ListenSession(songID: id);
  }

  /// Sessions end during build or dispose, when the model must not notify listeners;
  /// the write happens right after the current frame work.
  void _recordLater(ListenSession s) {
    final model = _model;
    scheduleMicrotask(() => model.recordSession(s));
  }

  Future<void> _suggestConquer() async {
    if (!mounted) return;
    final ok = await confirmDialog(context,
        title: '이 노래를 정복한 것 같아요!', message: '세 번 넘게 끝까지 들으며 공부했어요. 골드 LP로 바꿀까요?', confirm: '정복 완료', cancel: '아직이에요');
    if (ok) _conquer();
  }

  void _conquer() {
    _model.setConquered(id, true);
    Haptics.success();
    if (MediaQuery.of(context).disableAnimations) return;
    setState(() => _goldBurst = true);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _goldBurst = false);
    });
  }

  Widget _goldOverlay() {
    const gold = Color(0xFFE3B341);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutBack,
        builder: (_, s, _) => Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Transform.scale(
              scale: s,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: gold, width: 4),
                  boxShadow: [BoxShadow(color: gold.withValues(alpha: 0.6), blurRadius: 30)],
                ),
                child: const VinylRecord(labelColor: gold, grooves: 4, filled: true),
              ),
            ),
            const SizedBox(height: 40),
            const Text('골드 LP 획득!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: gold)),
          ]),
        ),
      ),
    );
  }
}

/// Slowly drifting, blurred grey blobs behind the player (prototype `pDrift`).
class _Backdrop extends AnimatedWidget {
  const _Backdrop({required Animation<double> animation}) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final v = Curves.easeInOut.transform((listenable as Animation<double>).value);
    Widget blob(Alignment a, Color c, double r) => Align(
          alignment: a,
          child: Container(
            width: r,
            height: r,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [c, c.withValues(alpha: 0)])),
          ),
        );
    return ClipRect(
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: PlayerPalette.background),
        Transform.translate(
          offset: Offset(lerpDouble(-12, 12, v)!, lerpDouble(-16, 16, v)!),
          child: Transform.rotate(
            angle: v * 8 * pi / 180,
            child: Transform.scale(
              scale: 1 + 0.06 * v,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48),
                child: Stack(fit: StackFit.expand, children: [
                  blob(const Alignment(-0.64, -0.76), const Color(0xFF5E5E5E), 420),
                  blob(const Alignment(0.64, -0.56), const Color(0xFF464646), 340),
                  blob(const Alignment(0.56, 0.64), const Color(0xFF333333), 460),
                  blob(const Alignment(-0.7, 0.56), const Color(0xFF3B3B3B), 380),
                ]),
              ),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x1F0A0C10), Color(0x6B0A0C10)]),
          ),
        ),
      ]),
    );
  }
}

/// Seek bar from the prototype: saved lines are mint segments with star pins; while scrubbing
/// the track thickens and the playhead snaps onto saved lines.
class _SeekBar extends StatelessWidget {
  final double duration;
  final double position;
  final bool enabled;
  final Animation<double> zoom;
  final int? snapIndex;
  final List<(int, double, double)> segments;
  final VoidCallback onScrubStart;
  final void Function(double raw, double threshold) onScrub;
  final VoidCallback onScrubEnd;

  const _SeekBar({
    required this.duration,
    required this.position,
    required this.enabled,
    required this.zoom,
    required this.snapIndex,
    required this.segments,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      void at(Offset p) => onScrub((p.dx / w).clamp(0.0, 1.0) * duration, 10 / w * duration);
      return Semantics(
        slider: true,
        label: '재생 위치',
        value: '${position.mmss} / ${duration.mmss}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) {
                  onScrubStart();
                  at(d.localPosition);
                }
              : null,
          onHorizontalDragUpdate: enabled ? (d) => at(d.localPosition) : null,
          onHorizontalDragEnd: enabled ? (_) => onScrubEnd() : null,
          onTapDown: enabled
              ? (d) {
                  onScrubStart();
                  at(d.localPosition);
                }
              : null,
          onTapUp: enabled ? (_) => onScrubEnd() : null,
          child: AnimatedBuilder(
            animation: zoom,
            builder: (_, _) => CustomPaint(
              size: Size(w, 56),
              painter: _SeekPainter(
                duration: duration,
                position: position,
                zoom: Curves.easeOut.transform(zoom.value),
                segments: segments,
                snapIndex: snapIndex,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _SeekPainter extends CustomPainter {
  final double duration, position, zoom;
  final List<(int, double, double)> segments;
  final int? snapIndex;
  _SeekPainter({required this.duration, required this.position, required this.zoom, required this.segments, required this.snapIndex});

  static const zMax = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final p = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final z = 1 + (zMax - 1) * zoom;
    final trackW = w * z;
    final dx = p * w * (1 - z); // zoom around the playhead
    final h = 8 + 6 * zoom;
    const cy = 36.0;
    double x(double sec) => dx + sec / duration * trackW;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(-21, 0, w + 42, size.height));
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(dx, cy - h / 2, trackW, h), Radius.circular(h / 2));
    canvas.drawRRect(track, Paint()..color = PlayerPalette.line);
    for (final (i, s, e) in segments) {
      final sh = i == snapIndex ? h * 1.7 : h;
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(x(s), cy - sh / 2, max(x(s) + 2, x(e)), cy + sh / 2), Radius.circular(sh / 2));
      canvas.drawRRect(r, Paint()..color = PlayerPalette.brand);
    }
    canvas.restore();

    // Star pins above saved lines; they fade out while zoomed.
    if (zoom < 1) {
      final pin = Paint()..color = PlayerPalette.brand.withValues(alpha: 1 - zoom);
      for (final (_, s, e) in segments) {
        canvas.drawPath(_star(Offset((s + e) / 2 / duration * w, 12 - 4 * zoom), 6), pin);
      }
    }

    // Playhead.
    final ph = p * w;
    final lineH = 32 * (1 + 0.5 * zoom);
    final head = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ph, cy), width: 3, height: lineH), const Radius.circular(2));
    canvas.drawRRect(head.inflate(2), Paint()..color = const Color(0x38000000));
    canvas.drawRRect(head, Paint()..color = Colors.white);
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
      o.position != position || o.zoom != zoom || o.duration != duration || o.snapIndex != snapIndex || o.segments.length != segments.length;
}
