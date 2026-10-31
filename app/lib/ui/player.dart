import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'components.dart';
import 'line_detail.dart';
import 'player_controls.dart';

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
  late final Timer _ticker;
  late AppModel _model;
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int? _lastIndex;
  bool _following = true;
  bool _programmaticScroll = false;
  int? _scrubLine;
  bool _goldBurst = false;

  String get id => widget.songID;

  @override
  void initState() {
    super.initState();
    // Only the current-line change rebuilds the lyrics; the controls run their own clock.
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final song = _model.collection.song(id);
      if (song != null && _currentIndex(_model, song, _model.collection.linesFor(id)) != _lastIndex) setState(() {});
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
    _scroll.dispose();
    _recordLater(_session);
    super.dispose();
  }

  // ── Derived state ──

  /// Linked while the music app plays this song, or right after a seek the app has not confirmed.
  _Mode _mode(AppModel model, Song song) {
    if (model.positionOf(song) == null) return _Mode.studyOnly;
    return song.lyricsType == LyricsType.synced ? _Mode.linkedSynced : _Mode.linkedPlain;
  }

  int? _currentIndex(AppModel model, Song song, List<LyricLine> lines) {
    if (song.lyricsType != LyricsType.synced) return null;
    final p = model.positionOf(song);
    return p == null ? null : SyncEngine.lineIndex(p - song.offset, lines);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final song = model.collection.song(id);
    if (song == null) {
      return Scaffold(
        backgroundColor: PlayerPalette.background,
        body: Center(child: Text(tr('노래를 찾을 수 없어요'), style: TextStyle(color: PlayerPalette.subtle))),
      );
    }
    final lines = model.collection.linesFor(id);
    final mode = _mode(model, song);
    final current = mode == _Mode.linkedSynced ? _currentIndex(model, song, lines) : null;
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
              if (model.translationSkipped(id)) _skippedNote(model),
              Expanded(child: _lyrics(model, song, lines, current, mode)),
              Container(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: PlayerPalette.line))),
                padding: const EdgeInsets.fromLTRB(21, 5, 21, 12),
                child: PlaybackControls(songID: id, onScrub: (p) => _onScrub(song, lines, p), onSeek: (p) => _onSeek(song, lines, p)),
              ),
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
          tooltip: tr('홈으로 돌아가기'),
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
          tooltip: tr('더보기'),
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
          child: Text(synced ? tr('재생하면 Spotify에서 노래가 나오고 가사가 따라와요') : tr('가사 공부 모드 · 싱크 정보가 없는 가사예요'),
              style: const TextStyle(fontSize: 12, color: PlayerPalette.placeholder)),
        ),
      ]),
    );
  }

  /// The song is already in the target language, so there are no translations to show.
  Widget _skippedNote(AppModel model) => Padding(
        padding: const EdgeInsets.fromLTRB(21, 0, 21, 4),
        child: Row(children: [
          const Icon(Icons.translate_rounded, size: 14, color: PlayerPalette.placeholder),
          const SizedBox(width: 6),
          Expanded(
            child: Text(tr('가사가 이미 {0}(이)라서 해석을 생략했어요.', [model.target.nativeName]), style: const TextStyle(fontSize: 12, color: PlayerPalette.placeholder)),
          ),
        ]),
      );

  // ── Seeking: the lyrics move to the target at once, before the music app reports back ──

  /// While dragging the seek bar, the list glides to the line under the playhead.
  void _onScrub(Song song, List<LyricLine> lines, double? position) {
    if (position == null) {
      _scrubLine = null;
      return;
    }
    final i = SyncEngine.lineIndex(position - song.offset, lines);
    if (i == null || i == _scrubLine) return;
    _scrubLine = i;
    if (!_following) setState(() => _following = true);
    _placeList(i);
  }

  void _onSeek(Song song, List<LyricLine> lines, double position) {
    final i = SyncEngine.lineIndex(position - song.offset, lines);
    if (!_following) setState(() => _following = true);
    if (i != null && i != _lastIndex) {
      _lastIndex = i;
      _placeList(i);
      setState(() {});
    }
  }

  void _seekToLine(Song song, List<LyricLine> lines, LyricLine line) {
    final target = max(0.0, line.start! + song.offset);
    HapticFeedback.selectionClick();
    _model.seekSong(song, target);
    _onSeek(song, lines, target);
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

  Widget _lyrics(AppModel model, Song song, List<LyricLine> lines, int? current, _Mode mode) {
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
              children: [for (final line in lines) _lyricRow(model, song, lines, line, current, mode)],
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
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Text(tr('현재 줄로 이동'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF15171C))),
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _lyricRow(AppModel model, Song song, List<LyricLine> lines, LyricLine line, int? current, _Mode mode) {
    // In study-only or plain mode every line is readable at full strength.
    final active = mode != _Mode.linkedSynced || line.index == current;
    final target = model.target.code;
    final translation = model.translationSkipped(id) ? null : model.collection.translationText(id, line.index, target);
    // While the song plays, a tap moves the music to that line; tapping the current line (or a
    // long press) opens the explanation.
    final seekable = mode == _Mode.linkedSynced && line.start != null && model.isPlayingSong(song);
    final failed = model.collection.translation(id, line.index, target)?.outcome == Outcome.failed;
    final saved = model.collection.isSaved(id, line.index);

    return Padding(
      key: _keys.putIfAbsent(line.index, GlobalKey.new),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Semantics(
            button: true,
            hint: seekable ? tr('탭하면 이 줄로 이동해요 · 길게 누르면 세부 설명') : tr('탭하면 세부 설명을 볼 수 있어요'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => seekable && line.index != current ? _seekToLine(song, lines, line) : _openLine(line.index, mode),
              onLongPress: () => _openLine(line.index, mode),
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
                if (model.settings.showTranslation)
                  // A translation fades and grows in the moment it arrives.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topLeft,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 360),
                      switchInCurve: Curves.easeOutCubic,
                      transitionBuilder: (c, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(a), child: c),
                      ),
                      child: translation != null
                          ? Padding(
                              key: const ValueKey('t'),
                              padding: const EdgeInsets.only(top: 4),
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 200),
                                style: TextStyle(
                                    fontFamily: AppTheme.fontFamilyOverride,
                                    fontSize: 14,
                                    height: 18 / 14,
                                    letterSpacing: -0.21,
                                    color: active ? PlayerPalette.subtle : PlayerPalette.placeholder),
                                child: Text(translation),
                              ),
                            )
                          : failed
                              ? Padding(
                                  key: const ValueKey('f'),
                                  padding: const EdgeInsets.only(top: 4),
                                  child: GestureDetector(
                                    onTap: () => model.startTranslation(id),
                                    child: Text(tr('번역 실패 — 다시 시도'),
                                        style: const TextStyle(fontSize: 12, color: PlayerPalette.placeholder, decoration: TextDecoration.underline, decorationColor: PlayerPalette.placeholder)),
                                  ),
                                )
                              : model.isTranslating(id)
                                  ? Padding(
                                      key: const ValueKey('w'),
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(tr('번역 중…'), style: const TextStyle(fontSize: 12, color: PlayerPalette.placeholder)),
                                    )
                                  : const SizedBox(key: ValueKey('n')),
                    ),
                  ),
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
            tooltip: saved ? tr('저장한 문장에서 빼기') : tr('문장 저장'),
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

  /// "이 줄 다시 듣기": jump to the line and play (starts the demo link in study-only mode).
  void _replayLine(int index) {
    final song = _model.collection.song(id);
    final line = _model.collection.line(id, index);
    if (song == null || line?.start == null) return;
    _setFollowing(true);
    _seekToLine(song, _model.collection.linesFor(id), line!);
    if (_model.isNowPlaying(song) && !_model.isPlayingSong(song)) _model.togglePlaySong(song);
  }

  // ── Menu: timing, wrong lyrics, retranslate, conquer (DCR-4, RQ-10, RQ-13) ──

  Future<void> _menu(AppModel model, Song song, List<LyricLine> lines) async {
    final canConquer = model.canMarkConquered(id) || _session.linesReached.length >= max(1, (lines.length * 0.9).floor());
    final action = await showActionSheet<String>(
      context,
      title: tr('엔진: {0}', [EngineFactory.label(model.settings.engine)]),
      message: tr('타이밍 조절 (현재 {0}{1}초)', [song.offset >= 0 ? '+' : '', song.offset.toStringAsFixed(1)]),
      actions: [
        SheetAction(tr('가사 0.5초 빠르게'), 'faster', icon: Icons.remove),
        SheetAction(tr('가사 0.5초 느리게'), 'slower', icon: Icons.add),
        if (song.offset != 0) SheetAction(tr('타이밍 초기화'), 'reset', icon: Icons.restart_alt),
        SheetAction(tr('가사가 이상해요?'), 'wrong', icon: Icons.help_outline),
        SheetAction(tr('현재 엔진으로 다시 번역'), 'retranslate', icon: Icons.translate),
        if (song.isConquered)
          SheetAction(tr('정복 취소'), 'unconquer', icon: Icons.undo)
        else
          SheetAction(tr('이 노래 정복!'), 'conquer', icon: Icons.emoji_events_outlined, enabled: canConquer),
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
        title: tr('이 노래를 정복한 것 같아요!'), message: tr('세 번 넘게 끝까지 들으며 공부했어요. 골드 LP로 바꿀까요?'), confirm: tr('정복 완료'), cancel: tr('아직이에요'));
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
            Text(tr('골드 LP 획득!'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: gold)),
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
