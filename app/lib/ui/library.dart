import 'dart:math';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/collection.dart';
import '../core/models.dart';
import 'components.dart';

enum _LibraryView { carousel, grid }

/// FG-01 Library, following the UI prototype "내 컬렉션": a 3D album carousel with a scrubber,
/// or a two-column grid, switched by the toggle next to "노래 추가" (RQ-9, RQ-13, RQ-17).
class LibraryView extends StatefulWidget {
  const LibraryView({super.key});
  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  _LibraryView view = _LibraryView.carousel;
  int focus = 0;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final songs = model.collection.songsNewestFirst;
    focus = focus.clamp(0, max(0, songs.length - 1));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Figma "head": big title + count.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Row(children: [
              Text('내 컬렉션', style: TextStyle(fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w700, letterSpacing: -0.36, color: t.textPrimary)),
              const Spacer(),
              Text('${songs.length}곡', style: TextStyle(fontSize: 16, height: 22 / 16, letterSpacing: -0.24, color: t.textSecondary)),
            ]),
          ),
          // Figma "toolbar": view toggle + add button.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(children: [
              if (songs.isNotEmpty) _ViewToggle(value: view, onChanged: (v) => setState(() => view = v)),
              const Spacer(),
              _AddPill(onTap: () => model.push(const SearchRoute())),
            ]),
          ),
          Expanded(
            child: songs.isEmpty
                ? _EmptyState(shelves: model.shelves)
                : AnimatedSwitcher(
                    duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
                    child: view == _LibraryView.carousel
                        ? _Carousel(key: const ValueKey('carousel'), songs: songs, initial: focus, onFocus: (i) => focus = i)
                        : _Grid(key: const ValueKey('grid'), songs: songs),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final _LibraryView value;
  final ValueChanged<_LibraryView> onChanged;
  const _ViewToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    Widget btn(_LibraryView v, IconData icon, String label) {
      final on = value == v;
      return Semantics(
        label: label,
        selected: on,
        button: true,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => onChanged(v),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: const Cubic(.3, .8, .3, 1),
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: on ? t.background : Colors.transparent, shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: on ? t.textPrimary : t.disabled),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 2, offset: Offset(2, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(_LibraryView.carousel, Icons.view_carousel_outlined, '캐러셀로 보기'),
        const SizedBox(width: 2),
        btn(_LibraryView.grid, Icons.grid_view_outlined, '격자로 보기'),
      ]),
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
      shape: const StadiumBorder(),
      shadowColor: const Color(0x1A000000),
      elevation: 1,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 20, color: t.textPrimary),
            const SizedBox(width: 4),
            Text('노래 추가', style: TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w500, letterSpacing: -0.28, color: t.textPrimary)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────── Album plate (Figma "Album Card / Plate") ───────────────

/// Square sleeve with the Figma bevel and glint. Shows the user's cover, else the default gradient.
/// Conquered songs get a gold rim (RQ-13).
class AlbumPlate extends StatelessWidget {
  final Song song;
  final double size;
  final bool translating;
  final List<BoxShadow> shadow;
  const AlbumPlate({super.key, required this.song, required this.size, this.translating = false, required this.shadow});

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
        border: Border.all(color: song.isConquered ? t.gold : const Color(0x0D000000), width: song.isConquered ? 2 : 1),
        boxShadow: shadow,
        gradient: hasCover
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFB7A3), Color(0xFFFFE0B0), Color(0xFFA9C2FF)],
                stops: [0.14, 0.5, 0.86],
              ),
        image: hasCover ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
      ),
      child: ClipRect(
        child: Stack(children: [
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
          Positioned(left: 0, top: 0, bottom: 0, width: 10 * k, child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.white.withValues(alpha: .6), Colors.white.withValues(alpha: .3)])))),
          Positioned(left: 10 * k - 1, top: 0, bottom: 0, width: max(1, k), child: ColoredBox(color: Colors.white.withValues(alpha: .7))),
          Positioned(right: 0, top: 0, bottom: 0, width: 4 * k, child: ColoredBox(color: Colors.white.withValues(alpha: .4))),
          Positioned(left: 0, right: 0, top: 0, height: 3 * k, child: ColoredBox(color: Colors.white.withValues(alpha: .4))),
          Positioned(left: 0, right: 0, bottom: 0, height: 3 * k, child: const ColoredBox(color: Color(0x1A000000))),
          if (!hasCover)
            Center(
              child: Text(song.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, letterSpacing: -0.24, color: Colors.white.withValues(alpha: .85))),
            ),
          if (translating || song.status == SongStatus.failed || song.isConquered)
            Positioned(left: 8 * k + 6, bottom: 8 * k + 4, child: StatusBadge(_badge(song, translating))),
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

void _openSong(AppModel model, Song song) =>
    model.push(model.isTranslating(song.id) ? TranslatingRoute(song.id) : PlayerRoute(song.id));

TextStyle _titleStyle(AppTheme t) => TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary);
TextStyle _artistStyle(AppTheme t) => TextStyle(fontSize: 14, height: 18 / 14, letterSpacing: -0.21, color: t.textTertiary);

// ─────────────── Carousel ───────────────

/// Side albums sit 237.5 px from the centre at 90 % size, tilted 25° towards the middle (Figma).
class _Carousel extends StatefulWidget {
  final List<Song> songs;
  final int initial;
  final ValueChanged<int> onFocus;
  const _Carousel({super.key, required this.songs, required this.initial, required this.onFocus});
  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> with SingleTickerProviderStateMixin {
  static const spacing = 237.5, tilt = 25 * pi / 180, shrink = 0.10, plate = 224.0;
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: widget.initial.toDouble())
    ..addListener(() => setState(() {}));
  double _dragStartPos = 0, _dragStartX = 0;
  int get n => widget.songs.length;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    final target = i.clamp(0, n - 1).toDouble();
    widget.onFocus(target.round());
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
    final current = pos.round().clamp(0, n - 1);
    final order = List.generate(n, (i) => i)..sort((a, b) => (b - pos).abs().compareTo((a - pos).abs()));

    return LayoutBuilder(builder: (context, c) {
      final cx = c.maxWidth / 2;
      const top = 44.0;
      return GestureDetector(
        onHorizontalDragStart: (d) {
          _c.stop();
          _dragStartPos = _c.value;
          _dragStartX = d.globalPosition.dx;
        },
        onHorizontalDragUpdate: (d) {
          var p = _dragStartPos - (d.globalPosition.dx - _dragStartX) / spacing;
          if (p < 0) p *= 0.35; // resist past the first album
          if (p > n - 1) p = n - 1 + (p - (n - 1)) * 0.35; // and past the last
          _c.value = p;
        },
        onHorizontalDragEnd: (d) => _goTo((_c.value - d.velocity.pixelsPerSecond.dx / spacing * 0.16).round()),
        child: Stack(clipBehavior: Clip.none, children: [
          for (final i in order)
            if ((i - pos).abs() <= 2.5) _item(model, t, i, pos, cx, top),
          // Meta of the front album.
          Positioned(
            left: 20,
            right: 20,
            top: top + plate + 16,
            child: Opacity(
              opacity: (1 - (pos - current).abs() * 1.6).clamp(0.0, 1.0),
              child: Column(children: [
                Text(widget.songs[current].title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: _titleStyle(t)),
                const SizedBox(height: 2),
                Text(widget.songs[current].artist, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: _artistStyle(t)),
              ]),
            ),
          ),
          Positioned(left: 0, right: 0, top: top + plate + 87, child: Center(child: _pager(t, current))),
        ]),
      );
    });
  }

  Widget _item(AppModel model, AppTheme t, int i, double pos, double cx, double top) {
    final d = i - pos;
    final ad = d.abs();
    final s = 1 - shrink * min(ad, 1.5);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 1 / 1200)
      ..rotateY(-d.clamp(-1.0, 1.0) * tilt)
      ..scaleByDouble(s, s, 1, 1);
    final song = widget.songs[i];
    return Positioned(
      left: cx - plate / 2 + d * spacing,
      top: top,
      width: plate,
      height: plate,
      child: Transform(
        alignment: Alignment.center,
        transform: m,
        child: Semantics(
          button: true,
          label: '${song.title}, ${song.artist} 재생',
          child: GestureDetector(
            onTap: () => ad < 0.05 ? _openSong(model, song) : _goTo(i),
            onLongPress: () => showSongMenu(context, song),
            child: AlbumPlate(
              song: song,
              size: plate,
              translating: model.isTranslating(song.id),
              shadow: const [BoxShadow(color: Color(0x26000000), offset: Offset(0, 24), blurRadius: 36, spreadRadius: -18)],
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
      label: '앨범 위치',
      value: '${current + 1} / $n, ${widget.songs[current].title}',
      increasedValue: '${min(current + 2, n)} / $n',
      decreasedValue: '${max(current, 1)} / $n',
      onIncrease: () => _goTo(current + 1),
      onDecrease: () => _goTo(current - 1),
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

// ─────────────── Grid ───────────────

class _Grid extends StatelessWidget {
  final List<Song> songs;
  const _Grid({super.key, required this.songs});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final bottom = model.nowPlaying != null ? 104.0 : 20.0; // room for the mini player
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 40 - 15) / 2;
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(20, 20, 20, bottom),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 15, mainAxisSpacing: 16, mainAxisExtent: w + 8 + 44 + 2 + 18 + 4),
        itemCount: songs.length,
        itemBuilder: (_, i) {
          final song = songs[i];
          return Semantics(
            button: true,
            label: '${song.title}, ${song.artist} 재생',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: () => _openSong(model, song),
              onLongPress: () => showSongMenu(context, song),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AlbumPlate(
                  song: song,
                  size: w,
                  translating: model.isTranslating(song.id),
                  shadow: const [BoxShadow(color: Color(0x1A000000), offset: Offset(5, 5), blurRadius: 10, spreadRadius: -1)],
                ),
                const SizedBox(height: 8),
                Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle(t)),
                const SizedBox(height: 2),
                Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: _artistStyle(t)),
              ]),
            ),
          );
        },
      );
    });
  }
}

// ─────────────── Song menu (long press) ───────────────

Future<void> showSongMenu(BuildContext context, Song song) async {
  final model = context.readModel;
  final action = await showActionSheet<String>(context, title: song.title, actions: [
    if (song.isConquered)
      const SheetAction('정복 취소', 'unconquer', icon: Icons.undo)
    else if (model.canMarkConquered(song.id))
      const SheetAction('이 노래 정복!', 'conquer', icon: Icons.emoji_events_outlined),
    if (song.status == SongStatus.failed) const SheetAction('번역 재시도', 'retry', icon: Icons.refresh),
    const SheetAction('현재 엔진으로 다시 번역', 'retranslate', icon: Icons.translate),
    const SheetAction('삭제', 'delete', icon: Icons.delete_outline, destructive: true),
  ]);
  if (!context.mounted) return;
  switch (action) {
    case 'unconquer':
      model.setConquered(song.id, false);
    case 'conquer':
      model.setConquered(song.id, true);
    case 'retry':
      model.startTranslation(song.id);
    case 'retranslate':
      model.retranslate(song.id);
    case 'delete':
      final choice = await showActionSheet<String>(context, title: '이 노래를 삭제할까요?', actions: const [
        SheetAction('삭제 (저장한 문장은 유지)', 'keep', destructive: true),
        SheetAction('저장한 문장까지 모두 삭제', 'all', destructive: true),
        SheetAction('취소', 'cancel'),
      ]);
      if (choice == 'keep') model.deleteSong(song.id, keepPhrases: true);
      if (choice == 'all') model.deleteSong(song.id, keepPhrases: false);
  }
}

// ─────────────── Empty state (FG-01-1, DCR-8) ───────────────

class _EmptyState extends StatelessWidget {
  final List<CuratedShelf> shelves;
  const _EmptyState({required this.shelves});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final model = context.readModel;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 24), children: [
      Center(
        child: Semantics(
          label: '노래 추가',
          button: true,
          excludeSemantics: true,
          child: SizedBox(width: 224, height: 224, child: AddSongTile(onTap: () => model.push(const SearchRoute()))),
        ),
      ),
      const SizedBox(height: 24),
      Text('첫 노래를 추가해보세요', textAlign: TextAlign.center, style: _titleStyle(t)),
      const SizedBox(height: 4),
      Text('좋아하는 팝송을 검색해서 LP로 모아요', textAlign: TextAlign.center, style: _artistStyle(t)),
      const SizedBox(height: 32),
      CuratedShelvesView(shelves: shelves, onSelect: (e, _) => model.push(SearchRoute('${e.title} ${e.artist}'))),
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
            Icon(Icons.add, size: 28, color: t.textTertiary),
            const SizedBox(height: 8),
            Text('노래 추가', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: t.textTertiary)),
          ]),
        ),
      ),
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

/// Curated shelves (RQ-17, DCR-8). Horizontal rows of small plates.
class CuratedShelvesView extends StatelessWidget {
  final List<CuratedShelf> shelves;
  final void Function(ShelfEntry, CuratedShelf) onSelect;
  const CuratedShelvesView({super.key, required this.shelves, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final shelf in shelves) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(shelf.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary)),
          const SizedBox(width: 8),
          Text(shelf.subtitle, style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: shelf.songs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) {
              final e = shelf.songs[i];
              return GestureDetector(
                onTap: () => onSelect(e, shelf),
                child: SizedBox(
                  width: 112,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: const Color(0x0D000000)),
                        boxShadow: const [BoxShadow(color: Color(0x14000000), offset: Offset(3, 3), blurRadius: 8, spreadRadius: -1)],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: const VinylRecord(grooves: 2),
                    ),
                    const SizedBox(height: 8),
                    Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: -0.21, color: t.textPrimary)),
                    Text(e.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textTertiary)),
                  ]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
      ],
    ]);
  }
}
