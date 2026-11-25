import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/collection.dart';
import '../core/lyrics.dart' show TrackMatcher;
import '../core/models.dart';
import 'components.dart';
import 'song_actions.dart';
import 'covers.dart';
import 'share_card.dart';
import 'spotify_library.dart';

/// FG-01 Library ("내 컬렉션"), following the Figma home frame and the Notion home ideas:
/// album slide (default), stack, block grid and list, chosen in My page → 보기 방식 (feedback 11/23).
/// Recommendations sit under every layout, and an empty library shows default covers and a feed.
class LibraryView extends StatefulWidget {
  const LibraryView({super.key});
  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  int focus = 0;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final songs = model.collection.songsNewestFirst;
    final conquered = songs.where((s) => s.isConquered).length;
    focus = focus.clamp(0, max(0, songs.length - 1));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Figma top bar: brand + settings.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
            child: Row(children: [
              // The record mark from the Figma start frame, next to the wordmark (0.14.0).
              Image.asset('assets/brand/vinylo_logo.png', width: 22, height: 22, semanticLabel: 'Vinylo'),
              const SizedBox(width: 8),
              Text('Vinylo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: t.textPrimary)),
              const Spacer(),
              if (songs.isNotEmpty)
                IconButton(
                  tooltip: tr('내 컬렉션 자랑하기'),
                  onPressed: () => showShareCard(context),
                  icon: Icon(Icons.ios_share_rounded, size: 22, color: t.textSecondary),
                ),
              IconButton(
                tooltip: tr('설정'),
                onPressed: model.openSettings,
                icon: Icon(Icons.settings_outlined, size: 22, color: t.textSecondary),
              ),
            ]),
          ),
          // Figma "head": title + count.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              Text(tr('내 컬렉션'), style: TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary)),
              const Spacer(),
              Text(conquered > 0 ? tr('{0}곡 · 정복 {1}곡', [songs.length, conquered]) : tr('{0}곡', [songs.length]),
                  style: TextStyle(fontSize: 13, letterSpacing: -0.2, color: t.textSecondary)),
            ]),
          ),
          if (model.showMusicAppPrompt) const _MusicAppCard(),
          if (songs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(children: [
                const Spacer(),
                _AddPill(onTap: () => model.openAdd()),
              ]),
            ),
          Expanded(
            child: songs.isEmpty
                ? const _EmptyHome()
                : AnimatedSwitcher(
                    duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
                    child: switch (model.settings.libraryLayout) {
                      LibraryLayout.carousel => _CarouselPage(key: const ValueKey('carousel'), songs: songs, initial: focus, onFocus: (i) => focus = i),
                      LibraryLayout.grid => _Grid(key: const ValueKey('grid'), songs: songs),
                      LibraryLayout.list => _List(key: const ValueKey('list'), songs: songs),
                      LibraryLayout.stack => _StackView(key: const ValueKey('stack'), songs: songs),
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

class _AddPill extends StatelessWidget {
  final VoidCallback onTap;
  const _AddPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Material(
      color: t.surface,
      shape: StadiumBorder(side: BorderSide(color: t.stroke.withValues(alpha: 0.5))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 20, color: t.textPrimary),
            const SizedBox(width: 4),
            Text(tr('노래 추가'), style: TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w500, letterSpacing: -0.28, color: t.textPrimary)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────── Album plate (Figma "Album Card / Plate") ───────────────

/// Square sleeve with the Figma bevel and glint. Shows the user's cover, else a generated one.
/// Conquered songs get a gold rim (RQ-13).
class AlbumPlate extends StatelessWidget {
  final Song song;
  final double size;
  final bool translating;
  final List<BoxShadow> shadow;
  final bool showBadge;

  /// Paper-sleeve trim: the hairline rim, spine line and bevels. Off for the stack view's clear
  /// plastic plates, where that trim read as a second record behind the cover.
  final bool sleeve;
  const AlbumPlate(
      {super.key, required this.song, required this.size, this.translating = false, required this.shadow, this.showBadge = true, this.sleeve = true});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final k = size / 224;
    final file = song.coverPath == null ? null : CoverStore.file(song.coverPath!);
    final hasCover = file != null && file.existsSync();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: song.isConquered
            ? Border.all(color: t.gold, width: 2)
            : sleeve
                ? Border.all(color: const Color(0x14000000), width: 1)
                : null,
        boxShadow: shadow,
        image: hasCover ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
      ),
      child: ClipRect(
        child: Stack(children: [
          if (!hasCover) Positioned.fill(child: GeneratedCover(seed: song.id, label: song.title, radius: 0)),
          // glint
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(-1, -1),
                  end: const Alignment(1, 1),
                  colors: [Colors.white.withValues(alpha: .16), Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0)],
                  stops: const [0.07, 0.29, 0.79],
                ),
              ),
            ),
          ),
          // spine edge, line and bevels
          if (sleeve) ...[
            Positioned(left: 0, top: 0, bottom: 0, width: 10 * k, child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.white.withValues(alpha: .35), Colors.white.withValues(alpha: .12)])))),
            Positioned(left: 10 * k - 1, top: 0, bottom: 0, width: max(1, k), child: ColoredBox(color: Colors.white.withValues(alpha: .4))),
            Positioned(right: 0, top: 0, bottom: 0, width: 4 * k, child: ColoredBox(color: Colors.white.withValues(alpha: .2))),
            Positioned(left: 0, right: 0, top: 0, height: 3 * k, child: ColoredBox(color: Colors.white.withValues(alpha: .2))),
            Positioned(left: 0, right: 0, bottom: 0, height: 3 * k, child: const ColoredBox(color: Color(0x1A000000))),
          ],
          if (showBadge && (translating || song.status == SongStatus.failed || song.isConquered))
            Positioned(left: 8 * k + 6, top: 8 * k + 4, child: StatusBadge(_badge(song, translating))),
        ]),
      ),
    );
  }

  static BadgeStatus _badge(Song s, bool translating) {
    if (s.isConquered) return BadgeStatus.conquered;
    if (translating || s.status == SongStatus.translating) return BadgeStatus.translating;
    return BadgeStatus.retry;
  }
}

/// Figma album card: the sleeve with the record peeking out on the right.
class SleeveWithDisc extends StatelessWidget {
  final Song song;
  final double width;
  final bool translating;
  const SleeveWithDisc({super.key, required this.song, required this.width, this.translating = false});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final plate = width * 0.86;
    final disc = plate * 0.92;
    return SizedBox(
      width: width,
      height: plate,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: width - disc,
          top: (plate - disc) / 2,
          width: disc,
          height: disc,
          child: Container(
            decoration: BoxDecoration(shape: BoxShape.circle, border: song.isConquered ? Border.all(color: t.gold, width: 2) : null),
            child: VinylRecord(labelColor: song.isConquered ? t.gold : t.brand, grooves: 3, filled: true),
          ),
        ),
        AlbumPlate(
          song: song,
          size: plate,
          translating: translating,
          showBadge: false,
          shadow: const [BoxShadow(color: Color(0x33000000), offset: Offset(4, 4), blurRadius: 10, spreadRadius: -2)],
        ),
      ]),
    );
  }
}

BadgeStatus songBadge(AppModel model, Song song) {
  if (song.isConquered) return BadgeStatus.conquered;
  if (model.isTranslating(song.id) || song.status == SongStatus.translating) return BadgeStatus.translating;
  if (song.status == SongStatus.failed) return BadgeStatus.retry;
  return BadgeStatus.done;
}

void _openSong(AppModel model, Song song) =>
    model.push(model.isTranslating(song.id) ? TranslatingRoute(song.id) : PlayerRoute(song.id));

TextStyle _titleStyle(AppTheme t) => TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary);
TextStyle _artistStyle(AppTheme t) => TextStyle(fontSize: 14, height: 18 / 14, letterSpacing: -0.21, color: t.textTertiary);

// The mini player is docked above the tab bar, so content never needs extra room for it.
double _bottomPad(AppModel model) => 24.0;

// ─────────────── Carousel ───────────────

/// Where album [i] sits relative to the centre when the slide is at [pos], on a loop of [n]
/// albums: 0 is the front, negative is left, positive is right, in (-n/2, n/2].
double carouselOffset(int i, double pos, int n) {
  if (n <= 1) return i - pos;
  var d = (i - pos) % n; // Dart's % is never negative
  if (d > n / 2) d -= n;
  return d;
}

class _CarouselPage extends StatelessWidget {
  final List<Song> songs;
  final int initial;
  final ValueChanged<int> onFocus;
  const _CarouselPage({super.key, required this.songs, required this.initial, required this.onFocus});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    return ListView(padding: EdgeInsets.only(bottom: _bottomPad(model)), children: [
      SizedBox(height: 452, child: _Carousel(songs: songs, initial: initial, onFocus: onFocus)),
      const SpotifyShelf(),
      RecommendRow(title: tr('이런 노래는 어때요?'), entries: model.recommendations(after: songs.first)),
      const MoreShelves(),
    ]);
  }
}

/// Album slide (Notion "디폴트 - 앨범 슬라이드 형식"): the front album stands apart from its tilted
/// neighbours, with the title, artist and a lyric line under it.
class _Carousel extends StatefulWidget {
  final List<Song> songs;
  final int initial;
  final ValueChanged<int> onFocus;
  const _Carousel({required this.songs, required this.initial, required this.onFocus});
  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> with SingleTickerProviderStateMixin {
  static const spacing = 244.0, tilt = 32 * pi / 180, shrink = 0.16, plate = 224.0;
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: widget.initial.toDouble())
    ..addListener(() => setState(() {}));
  double _dragStartPos = 0, _dragStartX = 0;
  int get n => widget.songs.length;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  int get _current => n == 1 ? 0 : _c.value.round() % n;

  /// Moves to album [i] the short way round (the slide loops, so both directions always work).
  void _goTo(int i) {
    final from = _c.value.roundToDouble();
    _settle(n == 1 ? 0 : from + carouselOffset(i % n, from, n));
  }

  void _settle(double raw) {
    final target = n == 1 ? 0.0 : raw.roundToDouble();
    widget.onFocus(n == 1 ? 0 : target.round() % n);
    if (target.round() != _c.value.round()) HapticFeedback.selectionClick();
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = target;
    } else {
      _c.animateTo(target, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final pos = _c.value;
    final current = _current;
    // Back to front, so the album nearest the centre is painted last.
    final order = List.generate(n, (i) => i)..sort((a, b) => carouselOffset(b, pos, n).abs().compareTo(carouselOffset(a, pos, n).abs()));
    final song = widget.songs[current];
    final line = model.featuredLine(song.id);

    return LayoutBuilder(builder: (context, c) {
      final cx = c.maxWidth / 2;
      const top = 28.0;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (d) {
          _c.stop();
          _dragStartPos = _c.value;
          _dragStartX = d.globalPosition.dx;
        },
        onHorizontalDragUpdate: (d) {
          var p = _dragStartPos - (d.globalPosition.dx - _dragStartX) / spacing;
          if (n == 1) p *= 0.35; // a single album only gives a little
          _c.value = p;
        },
        onHorizontalDragEnd: (d) => _settle(_c.value - d.velocity.pixelsPerSecond.dx / spacing * 0.16),
        child: Stack(clipBehavior: Clip.none, children: [
          for (final i in order)
            if (carouselOffset(i, pos, n).abs() <= 2.5) _item(model, i, carouselOffset(i, pos, n), cx, top),
          // Meta and a lyric line of the front album.
          Positioned(
            left: 28,
            right: 28,
            top: top + plate + 22,
            child: Opacity(
              opacity: (1 - (pos - pos.roundToDouble()).abs() * 1.6).clamp(0.0, 1.0),
              child: Column(children: [
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: _titleStyle(t)),
                const SizedBox(height: 2),
                Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: _artistStyle(t)),
                const SizedBox(height: 6),
                StatusBadge(songBadge(model, song)),
                if (line != null) ...[
                  const SizedBox(height: 12),
                  Text('“${line.$1}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, height: 1.35, fontStyle: FontStyle.italic, color: t.textSecondary)),
                  if (line.$2 != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(line.$2!, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: t.brandInk)),
                    ),
                ],
              ]),
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 4, child: Center(child: _pager(t, current))),
        ]),
      );
    });
  }

  Widget _item(AppModel model, int i, double d, double cx, double top) {
    final ad = d.abs();
    final s = 1 - shrink * min(ad, 1.5);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 1 / 1100)
      ..rotateY(-d.clamp(-1.0, 1.0) * tilt)
      ..scaleByDouble(s, s, 1, 1);
    final song = widget.songs[i];
    return Positioned(
      left: cx - plate / 2 + d * spacing,
      top: top,
      width: plate,
      height: plate,
      child: Opacity(
        opacity: (1 - 0.35 * min(ad, 1.0)).clamp(0.0, 1.0),
        child: Transform(
          alignment: Alignment.center,
          transform: m,
          child: Semantics(
            button: true,
            label: tr('{0}, {1} 재생', [song.title, song.artist]),
            child: Pressable(
              scale: 0.98,
              onTap: () => ad < 0.05 ? _openSong(model, song) : _goTo(i),
              onLongPress: () {
                HapticFeedback.mediumImpact();
                showSongMenu(context, song);
              },
              // Flat sleeve (feedback 11/22 #17): the thick "slab" edges made the cover look like a box.
              child: AlbumPlate(
                song: song,
                size: plate,
                translating: model.isTranslating(song.id),
                shadow: const [BoxShadow(color: Color(0x40000000), offset: Offset(0, 24), blurRadius: 36, spreadRadius: -16)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Scrubber: the thumb jumps one album at a time.
  Widget _pager(AppTheme t, int current) {
    const w = 184.0;
    void scrub(double x) => _goTo((x / w * (n - 1)).round());
    return Semantics(
      slider: true,
      label: tr('앨범 위치'),
      value: '${current + 1} / $n, ${widget.songs[current].title}',
      increasedValue: '${(current + 1) % n + 1} / $n',
      decreasedValue: '${(current - 1 + n) % n + 1} / $n',
      onIncrease: () => _goTo(current + 1),
      onDecrease: () => _goTo(current - 1 + n),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => scrub(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => scrub(d.localPosition.dx),
          child: SizedBox(
            width: w,
            height: 30,
            child: Stack(alignment: Alignment.centerLeft, children: [
              Container(height: 4, decoration: BoxDecoration(color: t.stroke, borderRadius: BorderRadius.circular(999))),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: const Cubic(.22, 1, .36, 1),
                left: n > 1 ? current / (n - 1) * (w - 3) : 0,
                child: Container(
                  width: 3,
                  height: 20,
                  decoration: BoxDecoration(
                    color: t.accent,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [BoxShadow(color: t.background, offset: const Offset(2, 0)), BoxShadow(color: t.background, offset: const Offset(-2, 0))],
                  ),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        Text('${current + 1} / $n',
            style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, letterSpacing: -0.24, color: t.textTertiary, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

// ─────────────── Stack (glass planes on a diagonal, like the UNVEIL reference) ───────────────

/// Covers stand as translucent planes in 3D along a diagonal, front at the bottom left. Swipe up or
/// right to slide deeper. Tapping the front cover plays it; after that, settling on another cover
/// plays it too, so the stack works like a playlist.
class _StackView extends StatefulWidget {
  final List<Song> songs;
  const _StackView({super.key, required this.songs});
  @override
  State<_StackView> createState() => _StackViewState();
}

class _StackViewState extends State<_StackView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this)..addListener(() => setState(() {}));
  double _start = 0;
  Offset _origin = Offset.zero;
  bool _playlist = false; // set once the user plays from this view
  int _played = -1;

  int get n => widget.songs.length;
  int get _front => _c.value.round().clamp(0, n - 1);

  /// The plate colour of [song]; a photo cover's average colour arrives a moment later.
  Color _tint(Song song) {
    final c = coverTint(song);
    if (c != null) return c;
    coverTintAsync(song).then((_) {
      if (mounted) setState(() {});
    });
    return const Color(0xFF8C939C);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _settle(double raw) {
    final target = raw.round().clamp(0, n - 1).toDouble();
    if (target.round() != _c.value.round()) HapticFeedback.selectionClick();
    final done = MediaQuery.of(context).disableAnimations
        ? Future<void>.sync(() => _c.value = target)
        : _c.animateTo(target, duration: const Duration(milliseconds: 460), curve: Curves.easeOutCubic);
    done.whenComplete(() {
      if (mounted && _playlist && _front != _played) _play(_front);
    });
  }

  void _play(int i) {
    final model = context.readModel;
    _playlist = true;
    _played = i;
    model.playSong(widget.songs[i]);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final pos = _c.value;
    final front = widget.songs[_front];
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final card = min(w * 0.56, h * 0.44);
      // Back cards first so the front one is painted on top.
      final order = [for (var i = 0; i < n; i++) if (i - pos > -1.6 && i - pos < 9) i]..sort((a, b) => b.compareTo(a));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _c.stop();
          _start = _c.value;
          _origin = d.globalPosition;
        },
        onPanUpdate: (d) {
          final delta = d.globalPosition - _origin;
          // Pull the next cover forward by swiping toward the bottom left.
          var p = _start - (delta.dx - delta.dy) / 120;
          if (p < 0) p *= 0.3;
          if (p > n - 1) p = n - 1 + (p - (n - 1)) * 0.3;
          _c.value = p;
        },
        onPanEnd: (d) => _settle(_c.value - (d.velocity.pixelsPerSecond.dx - d.velocity.pixelsPerSecond.dy) / 120 * 0.18),
        child: Stack(clipBehavior: Clip.hardEdge, children: [
          for (final i in order) _plane(model, i, i - pos, w, h, card),
          // Front song and its actions, bottom right.
          Positioned(
            right: 20,
            bottom: 16,
            width: w * 0.5,
            child: Opacity(
              opacity: (1 - (pos - pos.roundToDouble()).abs() * 1.8).clamp(0.0, 1.0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${_front + 1} / $n', style: TextStyle(fontSize: 12, color: t.textTertiary, fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 4),
                Text(front.title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: _titleStyle(t)),
                Text(front.artist, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: _artistStyle(t)),
                const SizedBox(height: 10),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: tr('가사 보기'),
                    onPressed: () => _openSong(model, front),
                    icon: Icon(Icons.lyrics_outlined, color: t.textSecondary),
                  ),
                  const SizedBox(width: 4),
                  Material(
                    color: t.brand,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => model.isPlayingSong(front) ? model.togglePlaySong(front) : _play(_front),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(model.isPlayingSong(front) ? Icons.pause_rounded : Icons.play_arrow_rounded, color: const Color(0xFF16171B), size: 28),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          Positioned(
            left: 20,
            top: 4,
            child: Text(_playlist ? tr('밀어서 다음 곡 재생') : tr('아래로 밀어 넘기고, 앞의 앨범을 눌러 재생'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ),
        ]),
      );
    });
  }

  // One camera for every cover; covers are pushed back along their own normal, so the stack's
  // axis — and the sliding direction — is perpendicular to the covers (the UNVEIL reference).
  static const _pitch = 0.50, _yaw = 0.66, _gap = 0.66, _depth = 0.0010;

  /// One cover as a glass plane. d = 0 is the front cover; d > 0 lies further back (up and right on
  /// screen), d < 0 has passed the viewer and fades out at the bottom left.
  Widget _plane(AppModel model, int i, double d, double w, double h, double card) {
    final song = widget.songs[i];
    final m = Matrix4.identity()
      ..setEntry(3, 2, _depth)
      ..rotateX(_pitch)
      ..rotateY(_yaw)
      ..translateByDouble(0.0, 0.0, d * card * _gap, 1.0);
    // Frosted glass: the front cover is nearly solid, the ones behind it let the stack show through.
    final opacity = d < 0 ? (1 + d / 1.3).clamp(0.0, 1.0) : (0.96 - min(d, 1.0) * 0.12 - max(0.0, d - 1) * 0.05).clamp(0.35, 0.96);
    return Positioned(
      left: w * 0.30 - card / 2,
      top: h * 0.66 - card / 2,
      width: card,
      height: card,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.center,
          transform: m,
          // A thin glass plate tinted with the album's colour: edges behind, the cover inset on top.
          child: Stack(clipBehavior: Clip.none, children: [
            ..._slab(card, _tint(song)),
            Semantics(
              button: true,
              label: tr('{0}, {1} 재생', [song.title, song.artist]),
              child: GestureDetector(
                onTap: () => d.abs() < 0.5 ? _play(i) : _settle(i.toDouble()),
                onLongPress: () => showSongMenu(context, song),
                child: _GlassPlate(song: song, size: card, tint: _tint(song), translating: model.isTranslating(song.id)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─────────────── LP slab ───────────────

/// Thickness of a cover plate, as a share of the cover size: a thin glass sheet
/// (4.5 % → 2.25 % on 11/19 #12 → 8.5 % on 11/21 → 2.5 % on 11/25 #12, like the UNVEIL reference).
const _slabDepth = 0.025;

/// The stack's plate for one song, after the UNVEIL reference: a translucent glass sheet in the
/// album's colour, the cover inset on it with its edges melting into the glass, and a rim in the
/// album's colour. No paper-sleeve trim, so it never reads as two records.
class _GlassPlate extends StatelessWidget {
  final Song song;
  final double size;
  final Color tint;
  final bool translating;
  const _GlassPlate({required this.song, required this.size, required this.tint, required this.translating});

  @override
  Widget build(BuildContext context) {
    final inset = size * 0.07;
    final light = Color.lerp(tint, Colors.white, 0.35)!;
    final dark = Color.lerp(tint, Colors.black, 0.25)!;
    final k = size / 224;
    Shader fade(Rect r, Alignment begin, Alignment end) => LinearGradient(
          begin: begin,
          end: end,
          colors: const [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
          stops: const [0, 0.14, 0.86, 1],
        ).createShader(r);
    final showBadge = translating || song.status == SongStatus.failed || song.isConquered;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light.withValues(alpha: 0.78), tint.withValues(alpha: 0.70), dark.withValues(alpha: 0.82)],
        ),
      ),
      foregroundDecoration: BoxDecoration(
        border: Border.all(color: song.isConquered ? context.theme.gold : dark.withValues(alpha: 0.9), width: song.isConquered ? 2 : 1),
      ),
      child: Stack(children: [
        Positioned.fill(
          left: inset,
          top: inset,
          right: inset,
          bottom: inset,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => fade(r, Alignment.centerLeft, Alignment.centerRight),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => fade(r, Alignment.topCenter, Alignment.bottomCenter),
              child: AlbumPlate(song: song, size: size - inset * 2, shadow: const [], showBadge: false, sleeve: false),
            ),
          ),
        ),
        if (showBadge) Positioned(left: 8 * k + 6, top: 8 * k + 4, child: StatusBadge(AlbumPlate._badge(song, translating))),
      ]),
    );
  }
}

/// Average colours of covers, by cover file (photos) or song id (generated covers).
final _tints = <String, Color>{};
final _tintLoads = <String, Future<Color>>{};

/// The colour of [song]'s cover if it is known now: always for a generated cover, after
/// [coverTintAsync] has finished for a photo.
Color? coverTint(Song song) {
  final path = song.coverPath;
  final file = path == null ? null : CoverStore.file(path);
  if (file == null || !file.existsSync()) {
    // The generated cover: a dark square with a coloured disc, so a dark shade of the disc colour.
    final (a, _) = CoverPainter(seed: song.id).colors;
    return Color.lerp(const Color(0xFF2A2C31), a, 0.45);
  }
  return _tints[path];
}

/// Works out the average colour of [song]'s photo cover from an 8×8 thumbnail, once per cover.
Future<Color> coverTintAsync(Song song) {
  final known = coverTint(song);
  if (known != null) return Future.value(known);
  final path = song.coverPath!;
  return _tintLoads[path] ??= () async {
    var c = const Color(0xFF8C939C);
    try {
      final bytes = await CoverStore.file(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 8, targetHeight: 8);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data != null) {
        var r = 0, g = 0, b = 0;
        final px = data.lengthInBytes ~/ 4;
        for (var i = 0; i < px; i++) {
          r += data.getUint8(i * 4);
          g += data.getUint8(i * 4 + 1);
          b += data.getUint8(i * 4 + 2);
        }
        c = Color.fromARGB(255, r ~/ px, g ~/ px, b ~/ px);
      }
    } catch (_) {}
    return _tints[path] = c;
  }();
}

/// The back face and the four edges of a plate of [card] size, standing behind a cover drawn at
/// z = 0 (further away is +z, as in the stack's camera). Painted before the cover. [tint] is the
/// album's colour, so the plate's rim shows it like the reference.
List<Widget> _slab(double card, Color tint) {
  final th = card * _slabDepth;
  final edge = tint.withValues(alpha: 0.30);
  Widget face(double w, double h, Matrix4 m, {Gradient? g}) => Positioned(
        left: (card - w) / 2,
        top: (card - h) / 2,
        width: w,
        height: h,
        child: Transform(
          alignment: Alignment.center,
          transform: m,
          child: DecoratedBox(decoration: BoxDecoration(color: g == null ? edge : null, gradient: g)),
        ),
      );
  // Coloured glass edge: solid where the faces meet, a little see-through in the middle.
  final rim = Color.lerp(tint, Colors.black, 0.2)!;
  final side = LinearGradient(colors: [rim.withValues(alpha: 0.95), tint.withValues(alpha: 0.65), rim.withValues(alpha: 0.95)]);
  return [
    face(card, card, Matrix4.identity()..translateByDouble(0.0, 0.0, th, 1.0), g: LinearGradient(colors: [tint.withValues(alpha: 0.35), tint.withValues(alpha: 0.20)])),
    face(th, card, Matrix4.identity()..translateByDouble(card / 2, 0.0, th / 2, 1.0)..rotateY(pi / 2), g: side),
    face(th, card, Matrix4.identity()..translateByDouble(-card / 2, 0.0, th / 2, 1.0)..rotateY(pi / 2), g: side),
    face(card, th, Matrix4.identity()..translateByDouble(0.0, -card / 2, th / 2, 1.0)..rotateX(pi / 2), g: side.withRotation()),
    face(card, th, Matrix4.identity()..translateByDouble(0.0, card / 2, th / 2, 1.0)..rotateX(pi / 2), g: side.withRotation()),
  ];
}

extension on LinearGradient {
  /// The same bands across the short side of a horizontal edge.
  LinearGradient withRotation() => LinearGradient(colors: colors, stops: stops, begin: Alignment.topCenter, end: Alignment.bottomCenter);
}

// ─────────────── Grid (Figma 01 홈 · 라이브러리) ───────────────

class _Grid extends StatelessWidget {
  final List<Song> songs;
  const _Grid({super.key, required this.songs});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 40 - 16) / 2;
      final plate = w * 0.86;
      final ts = MediaQuery.textScalerOf(context);
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          sliver: SliverGrid(
            // Text rows grow with the system font size, so the cell height does too (no overflow).
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 20,
                mainAxisExtent: plate + 8 + ts.scale(22) + 2 + ts.scale(18) + 8 + ts.scale(24) + 6),
            delegate: SliverChildBuilderDelegate(childCount: songs.length + 1, (_, i) {
              // Figma: the dashed "노래 추가" tile comes first.
              if (i == 0) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: plate, height: plate, child: AddSongTile(onTap: () => model.openAdd())),
                );
              }
              final song = songs[i - 1];
              return Semantics(
                button: true,
                label: tr('{0}, {1} 재생', [song.title, song.artist]),
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: () => _openSong(model, song),
                  onLongPress: () => showSongMenu(context, song),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SleeveWithDisc(song: song, width: w, translating: model.isTranslating(song.id)),
                    const SizedBox(height: 8),
                    Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle(t)),
                    const SizedBox(height: 2),
                    Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: _artistStyle(t)),
                    const SizedBox(height: 8),
                    StatusBadge(songBadge(model, song)),
                  ]),
                ),
              );
            }),
          ),
        ),
        const SliverToBoxAdapter(child: SpotifyShelf()),
        SliverToBoxAdapter(child: RecommendRow(title: tr('이런 노래는 어때요?'), entries: model.recommendations(after: songs.first))),
        const SliverToBoxAdapter(child: MoreShelves()),
        SliverToBoxAdapter(child: SizedBox(height: _bottomPad(model))),
      ]);
    });
  }
}

// ─────────────── List (Notion "리스트 형식", swipe left to delete) ───────────────

class _List extends StatelessWidget {
  final List<Song> songs;
  const _List({super.key, required this.songs});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    return ListView(padding: EdgeInsets.only(top: 8, bottom: _bottomPad(model)), children: [
      for (final (i, song) in songs.indexed)
        Dismissible(
          key: ValueKey('row-${song.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: const Color(0xFFE5484D),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.delete_outline, color: Colors.white),
              SizedBox(width: 6),
              Text(tr('삭제'), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ]),
          ),
          confirmDismiss: (_) async => (await askDelete(context, song)) != null,
          onDismissed: (_) {},
          child: InkWell(
            onTap: () => _openSong(model, song),
            onLongPress: () => showSongMenu(context, song),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(children: [
                SizedBox(
                  width: 22,
                  child: Text((i + 1).toString().padLeft(2, '0'),
                      style: TextStyle(fontSize: 12, color: t.textTertiary, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                const SizedBox(width: 8),
                SleeveWithDisc(song: song, width: 84, translating: model.isTranslating(song.id)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle(t)),
                    const SizedBox(height: 2),
                    Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: _artistStyle(t)),
                    const SizedBox(height: 6),
                    StatusBadge(songBadge(model, song)),
                  ]),
                ),
                IconButton(
                  tooltip: tr('더보기'),
                  onPressed: () => showSongMenu(context, song),
                  icon: Icon(Icons.more_horiz, color: t.textTertiary),
                ),
              ]),
            ),
          ),
        ),
      const SpotifyShelf(),
      RecommendRow(title: tr('이런 노래는 어때요?'), entries: model.recommendations(after: songs.first)),
      const MoreShelves(),
    ]);
  }
}

// ─────────────── Song menu (long press) ───────────────

Future<void> showSongMenu(BuildContext context, Song song) async {
  final model = context.readModel;
  final hasLines = model.collection.linesFor(song.id).isNotEmpty;
  final action = await showActionSheet<String>(context, title: song.title, actions: [
    SheetAction(tr('노래·가사 수정'), 'edit', icon: Icons.edit_outlined),
    SheetAction(tr('앨범 커버 수정'), 'cover', icon: Icons.album_outlined),
    if (song.status == SongStatus.failed) SheetAction(tr('번역 재시도'), 'retry', icon: Icons.refresh),
    SheetAction(tr('현재 엔진으로 다시 번역'), 'retranslate', icon: Icons.translate),
    SheetAction(tr('싱크 맞추기'), 'timing', icon: Icons.av_timer, enabled: hasLines),
    SheetAction(tr('이 노래 퀴즈 풀기'), 'quiz', icon: Icons.quiz_outlined, enabled: hasLines),
    SheetAction(tr('AI 번역 신고하기'), 'report', icon: Icons.flag_outlined),
    SheetAction(tr('노래 삭제'), 'delete', icon: Icons.delete_outline, destructive: true),
  ]);
  if (!context.mounted) return;
  switch (action) {
    case 'edit':
      await showEditSong(context, song);
    case 'cover':
      await showCoverPicker(context, song);
    case 'report':
      await showReportTranslation(context, song.id);
    case 'timing':
      model.push(PlayerRoute(song.id, openTiming: true));
    case 'quiz':
      openSongQuiz(context, song);
    case 'retry':
      model.startTranslation(song.id);
    case 'retranslate':
      model.retranslate(song.id);
    case 'delete':
      await askDelete(context, song);
  }
}

/// Asks how to delete and deletes. Returns the choice, or null when cancelled.
Future<String?> askDelete(BuildContext context, Song song) async {
  final model = context.readModel;
  final choice = await showActionSheet<String>(context, title: tr('이 노래를 삭제할까요?'), actions: [
    SheetAction(tr('삭제 (저장한 문장은 유지)'), 'keep', destructive: true),
    SheetAction(tr('저장한 문장까지 모두 삭제'), 'all', destructive: true),
    SheetAction(tr('취소'), 'cancel'),
  ]);
  if (choice == 'keep') model.deleteSong(song.id, keepPhrases: true);
  if (choice == 'all') model.deleteSong(song.id, keepPhrases: false);
  return choice == 'keep' || choice == 'all' ? choice : null;
}

// ─────────────── Empty home (FG-01-1, Notion: default covers + "put your song", feed) ───────────────

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    void search() => model.openAdd();
    return ListView(padding: EdgeInsets.only(top: 12, bottom: _bottomPad(model)), children: [
      SizedBox(
        height: 250,
        child: LayoutBuilder(builder: (context, c) {
          final cx = c.maxWidth / 2;
          Widget side(double d) {
            final m = Matrix4.identity()
              ..setEntry(3, 2, 1 / 1100)
              ..rotateY(-d * 32 * pi / 180)
              ..scaleByDouble(0.84, 0.84, 1, 1);
            return Positioned(
              left: cx - 100 + d * 210,
              top: 16,
              width: 200,
              height: 200,
              child: Opacity(
                opacity: 0.7,
                child: Transform(
                  alignment: Alignment.center,
                  transform: m,
                  child: GestureDetector(onTap: search, child: const AddCoverTile()),
                ),
              ),
            );
          }

          return Stack(clipBehavior: Clip.none, children: [
            side(-1),
            side(1),
            Positioned(
              left: cx - 100,
              top: 16,
              width: 200,
              height: 200,
              child: Semantics(
                button: true,
                label: tr('노래 추가'),
                excludeSemantics: true,
                child: AddSongTile(onTap: search),
              ),
            ),
          ]);
        }),
      ),
      const SizedBox(height: 8),
      Text(tr('첫 노래를 추가해보세요'), textAlign: TextAlign.center, style: _titleStyle(t)),
      const SizedBox(height: 4),
      Text(tr('좋아하는 팝송을 검색해서 LP로 모아요'), textAlign: TextAlign.center, style: _artistStyle(t)),
      const SizedBox(height: 4),
      const SpotifyShelf(),
      const SizedBox(height: 12),
      // 삭제한 문구("가사를 바로 불러올 수 있는 곡")가 있던 자리. 아래 목록 위치를 그대로 두려고 높이만 남겨요.
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: SizedBox(height: 19.5),
      ),
      CuratedShelvesView(shelves: model.shelves, onSelect: (e, _) => model.openAdd(e.trackKey)),
    ]);
  }
}

class AddSongTile extends StatelessWidget {
  final VoidCallback onTap;
  const AddSongTile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: CustomPaint(
        painter: _DashedRect(t.stroke),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 28, color: t.textSecondary),
            const SizedBox(height: 8),
            Text(tr('노래 추가'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

/// The cover of a song not added yet (feedback 11/23: instead of a generated CD cover): a dashed
/// square with a plus.
class AddCoverTile extends StatelessWidget {
  const AddCoverTile({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return CustomPaint(
      painter: _DashedRect(t.stroke),
      child: Center(child: Icon(Icons.add, size: 28, color: t.textSecondary)),
    );
  }
}

class _DashedRect extends CustomPainter {
  final Color color;
  _DashedRect(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)).deflate(0.5));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRect old) => old.color != color;
}

// ─────────────── Recommendations ───────────────

/// A horizontal row of suggested songs with generated covers. Tapping one searches for it.
class RecommendRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<ShelfEntry> entries;
  final void Function(ShelfEntry)? onSelect;
  const RecommendRow({super.key, required this.title, this.subtitle, required this.entries, this.onSelect});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    if (entries.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.textTertiary)),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 166,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) {
              final e = entries[i];
              final owned = model.collection.existingSong(TrackKey(title: e.title, artist: e.artist)) != null;
              return Semantics(
                button: true,
                label: '${e.title}, ${e.artist}${owned ? ', ${tr('이미 추가됨')}' : ''}',
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: () => onSelect != null ? onSelect!(e) : model.openAdd(e.trackKey),
                  child: SizedBox(
                    width: 112,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Stack(children: [
                        const SizedBox(width: 112, height: 112, child: AddCoverTile()),
                        if (owned) Positioned(right: 6, top: 6, child: Icon(Icons.check_circle, size: 20, color: t.brand)),
                      ]),
                      const SizedBox(height: 8),
                      Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: -0.21, color: t.textPrimary)),
                      Text(e.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textTertiary)),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Curated shelves (RQ-17, DCR-8): easy songs, popular songs, slang and trending, as a feed of rows.
class CuratedShelvesView extends StatelessWidget {
  final List<CuratedShelf> shelves;
  final void Function(ShelfEntry, CuratedShelf) onSelect;
  const CuratedShelvesView({super.key, required this.shelves, required this.onSelect});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final shelf in shelves) RecommendRow(title: shelf.title, subtitle: shelf.subtitle, entries: shelf.songs, onSelect: (e) => onSelect(e, shelf)),
      ]);
}

/// The curated shelves of the empty home ("가사를 바로 불러올 수 있는 곡", slang songs and so on), kept
/// under the library after the first song is added, minus what is already in the collection.
class MoreShelves extends StatelessWidget {
  const MoreShelves({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    bool owned(ShelfEntry e) =>
        model.collection.songs.any((s) => TrackMatcher.matches(TrackKey(title: s.title, artist: s.artist), TrackKey(title: e.title, artist: e.artist)));
    final rows = <Widget>[
      for (final shelf in model.shelves)
        if (shelf.songs.where((e) => !owned(e)).toList() case final left when left.isNotEmpty)
          RecommendRow(title: shelf.title, subtitle: shelf.subtitle, entries: left, onSelect: (e) => model.openAdd(e.trackKey)),
    ];
    if (rows.isEmpty) return const SizedBox();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      // 삭제한 문구("가사를 바로 불러올 수 있는 곡")가 있던 자리. 아래 목록 위치를 그대로 두려고 높이만 남겨요.
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: SizedBox(height: 19.5),
      ),
      ...rows,
    ]);
  }
}

/// Suggests following the user's music app (any app, through notification access).
class _MusicAppCard extends StatelessWidget {
  const _MusicAppCard();

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.model;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.stroke)),
        child: Row(children: [
          Icon(Icons.graphic_eq_rounded, color: t.brand),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('음악 앱과 연결하기'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
            ]),
          ),
          TextButton(
            onPressed: () async {
              if (await confirmMusicAppAccess(context)) await model.requestMusicAppAccess();
            },
            child: Text(tr('연결'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: tr('닫기'),
            onPressed: model.dismissMusicAppPrompt,
            icon: Icon(Icons.close, size: 18, color: t.textTertiary),
          ),
        ]),
      ),
    );
  }
}
