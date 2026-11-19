import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/spotify_library.dart';
import '../app/theme.dart';
import '../app/web_artwork.dart';
import 'add_song.dart';
import 'components.dart';
import 'covers.dart';

/// Where the chosen cover comes from (Figma 커버 이미지 선택; GitHub swe-2026_2_UI cover-select-prototype).
enum CoverSource { album, gallery, pinterest, preset }

enum _AlbumState { loading, found, none }

/// Cover choice between the add form and the collection. The album cover (Spotify art, else the
/// iTunes Search API) is applied as soon as it arrives unless the user already picked something;
/// without one, the default cover chosen by the song title is applied.
class CoverSelectView extends StatefulWidget {
  final AddSongDraft draft;

  /// Set when changing the cover of a song already in the collection ("앨범 커버 수정"): the
  /// button saves the cover and closes the screen instead of adding the song.
  final String? songID;
  const CoverSelectView({super.key, required this.draft, this.songID});

  /// Test hook: replaces the album-art lookup (returns a local file path or null).
  static Future<String?> Function(AddSongDraft)? debugAlbumArt;

  @override
  State<CoverSelectView> createState() => _CoverSelectViewState();
}

class _CoverSelectViewState extends State<CoverSelectView> {
  _AlbumState _album = _AlbumState.loading;
  String? _albumPath, _galleryPath, _pinterestPath;
  CoverSource? _source;
  int _preset = 0;
  bool _touched = false;
  bool _saving = false;
  final _swatches = ScrollController();

  AddSongDraft get draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _loadAlbumArt();
  }

  @override
  void dispose() {
    _swatches.dispose();
    super.dispose();
  }

  Future<void> _loadAlbumArt() async {
    String? path;
    try {
      final hook = CoverSelectView.debugAlbumArt;
      if (hook != null) {
        path = await hook(draft);
      } else {
        final url = draft.coverURL ?? await WebArtwork().find(draft.title, draft.artist);
        if (url != null) path = (await SpotifyLibrary.downloadToTemp(url, await getTemporaryDirectory()))?.path;
      }
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _album = _AlbumState.found;
        _albumPath = path;
        if (!_touched) _source = CoverSource.album;
      });
      return;
    }
    // No album cover: its tile leaves quietly and the title's default cover is applied.
    setState(() {
      _album = _AlbumState.none;
      if (!_touched) {
        _source = CoverSource.preset;
        _preset = DiscCoverStyle.indexFor(draft.title);
      }
    });
    if (!_touched) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPreset(_preset));
  }

  void _scrollToPreset(int i) {
    if (!_swatches.hasClients) return;
    const step = 56.0;
    final target = (i * step - (_swatches.position.viewportDimension - 44) / 2).clamp(0.0, _swatches.position.maxScrollExtent);
    _swatches.animateTo(target, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
  }

  void _select(CoverSource s, {int? preset}) {
    HapticFeedback.selectionClick();
    setState(() {
      _touched = true;
      _source = s;
      if (preset != null) _preset = preset;
    });
  }

  Future<String?> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
      return x?.path;
    } catch (_) {
      if (mounted) showMessage(context, tr('사진을 불러오지 못했어요.'));
      return null;
    }
  }

  Future<void> _onGallery() async {
    if (_galleryPath != null && _source != CoverSource.gallery) return _select(CoverSource.gallery);
    final p = await _pickPhoto();
    if (p == null || !mounted) return;
    _galleryPath = p;
    _select(CoverSource.gallery);
  }

  Future<void> _onPinterest() async {
    if (_pinterestPath != null && _source != CoverSource.pinterest) return _select(CoverSource.pinterest);
    final p = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.theme.surfaceRaised,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      // Artist name only: Pinterest has far more artist photos than pins for one song title.
      builder: (_) => _PinterestSheet(query: (draft.artist.trim().isEmpty ? draft.title : draft.artist).trim(), pick: _pickPhoto),
    );
    if (p == null || !mounted) return;
    _pinterestPath = p;
    _select(CoverSource.pinterest);
  }

  /// The chosen cover as a local file for [AppModel.addSong]; default covers are rendered to PNG.
  Future<String?> _coverFile() async {
    switch (_source) {
      case CoverSource.album:
        return _albumPath;
      case CoverSource.gallery:
        return _galleryPath;
      case CoverSource.pinterest:
        return _pinterestPath;
      case CoverSource.preset:
        final png = await DiscCoverPainter(DiscCoverStyle.presets[_preset]).toPng();
        if (png == null) return null;
        final f = File('${(await getTemporaryDirectory()).path}/cover-${DateTime.now().millisecondsSinceEpoch}.png');
        await f.writeAsBytes(png);
        return f.path;
      case null:
        return null;
    }
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    final path = await _coverFile();
    if (!mounted) return;
    final songID = widget.songID;
    if (songID != null) {
      if (path != null) context.readModel.setCoverFromFile(songID, path);
      Navigator.of(context).pop();
      return;
    }
    await addToCollection(context, draft, coverPath: path);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.songID == null ? tr('커버 이미지 추가') : tr('앨범 커버 수정')), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        children: [
          Center(child: SizedBox(width: 220, height: 220, child: _plate())),
          const SizedBox(height: 14),
          Text(
            draft.title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            draft.artist,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: t.textTertiary),
          ),
          const SizedBox(height: 22),
          _sources(),
          const SizedBox(height: 22),
          SectionLabel(tr('기본 커버')),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: ListView.separated(
              controller: _swatches,
              scrollDirection: Axis.horizontal,
              itemCount: DiscCoverStyle.presets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _swatch(i),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: PrimaryButton(widget.songID == null ? tr('컬렉션에 추가') : tr('저장'), onPressed: _source == null || _saving ? null : _confirm),
        ),
      ),
    );
  }

  Widget _coverWidget(CoverSource s) => switch (s) {
    CoverSource.album => Image.file(File(_albumPath!), fit: BoxFit.cover),
    CoverSource.gallery => Image.file(File(_galleryPath!), fit: BoxFit.cover),
    CoverSource.pinterest => Image.file(File(_pinterestPath!), fit: BoxFit.cover),
    CoverSource.preset => DiscCover(DiscCoverStyle.presets[_preset]),
  };

  /// The LP sleeve: a skeleton until something is chosen, then a cross-fade on every change.
  Widget _plate() {
    final t = context.theme;
    final s = _source;
    final key = s == null ? 'none' : '${s.name}:${s == CoverSource.preset ? _preset : ''}:${_galleryPath ?? ''}:${_pinterestPath ?? ''}';
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 12))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AnimatedSwitcher(
          duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 560),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 1.04, end: 1.0).animate(a), child: c),
          ),
          child: SizedBox.expand(
            key: ValueKey(key),
            child: s == null ? _Skeleton(color: t.surfaceRaised) : _coverWidget(s),
          ),
        ),
      ),
    );
  }

  Widget _sources() {
    final t = context.theme;
    Widget tile({
      required String label,
      required bool selected,
      required Widget child,
      required VoidCallback? onTap,
      bool external = false,
      bool change = false,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            Semantics(
              button: true,
              selected: selected,
              label: label,
              child: GestureDetector(
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 80,
                  height: 80,
                  padding: EdgeInsets.all(selected ? 3 : 0),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: selected ? t.textPrimary : Colors.transparent, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(selected ? 9 : 12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: t.surfaceRaised),
                        child,
                        // Figma: a small white "변경" pill at the bottom right of a picked photo.
                        if (change)
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                              child: Text(tr('변경'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1B1C1F))),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w400, color: selected ? t.textPrimary : t.textSecondary),
                ),
                if (external) Icon(Icons.north_east_rounded, size: 11, color: t.textSecondary),
              ],
            ),
          ],
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The album tile disappears when there is no album cover (prototype "앨범 커버 없음").
            AnimatedSize(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              child: _album == _AlbumState.none
                  ? const SizedBox(width: 0, height: 0)
                  : tile(
                      label: tr('앨범 커버'),
                      selected: _source == CoverSource.album,
                      onTap: _album == _AlbumState.found ? () => _select(CoverSource.album) : null,
                      child: _album == _AlbumState.loading ? _Skeleton(color: t.surfaceRaised) : Image.file(File(_albumPath!), fit: BoxFit.cover),
                    ),
            ),
            tile(
              label: tr('갤러리'),
              selected: _source == CoverSource.gallery,
              onTap: _onGallery,
              change: _galleryPath != null,
              child: _galleryPath != null
                  ? Image.file(File(_galleryPath!), fit: BoxFit.cover)
                  : Icon(Icons.add_photo_alternate_outlined, color: t.textSecondary),
            ),
            tile(
              label: tr('핀터레스트'),
              selected: _source == CoverSource.pinterest,
              onTap: _onPinterest,
              change: _pinterestPath != null,
              child: _pinterestPath != null
                  ? Image.file(File(_pinterestPath!), fit: BoxFit.cover)
                  : Center(child: Image.asset('assets/brand/ic_pinterest.png', width: 24, height: 24, color: t.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(int i) {
    final t = context.theme;
    final style = DiscCoverStyle.presets[i];
    final selected = _source == CoverSource.preset && _preset == i;
    return Semantics(
      button: true,
      selected: selected,
      label: tr('기본 커버 {0}', [i + 1]),
      child: GestureDetector(
        onTap: () => _select(CoverSource.preset, preset: i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? t.textPrimary : Colors.transparent, width: 2),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(colors: [style.a, style.b, style.a]),
            ),
            child: Center(
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle, color: style.background),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pinterest has no public image search for apps, so the sheet opens Pinterest's search in the
/// browser and then lets the user pick the saved image from the gallery (no simulated results).
class _PinterestSheet extends StatefulWidget {
  final String query;
  final Future<String?> Function() pick;
  const _PinterestSheet({required this.query, required this.pick});
  @override
  State<_PinterestSheet> createState() => _PinterestSheetState();
}

class _PinterestSheetState extends State<_PinterestSheet> {
  late final _q = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    try {
      await Links.open(Uri.https('www.pinterest.com', '/search/pins/', {'q': q}));
    } catch (_) {
      if (mounted) showMessage(context, tr('브라우저를 열지 못했어요.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: t.stroke, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('핀터레스트에서 찾기'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close, color: t.textPrimary),
                tooltip: tr('닫기'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _open(),
            style: TextStyle(color: t.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search, color: t.textTertiary),
              filled: true,
              fillColor: t.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 10),
          Text(tr('핀터레스트에서 마음에 드는 이미지를 저장한 뒤, 아래 버튼으로 갤러리에서 골라 주세요.'), style: TextStyle(fontSize: 13, color: t.textSecondary)),
          const SizedBox(height: 16),
          PrimaryButton(tr('핀터레스트 열기'), icon: Icons.north_east_rounded, onPressed: _open),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () async {
                final p = await widget.pick();
                if (p != null && context.mounted) Navigator.pop(context, p);
              },
              icon: Icon(Icons.photo_library_outlined, color: t.textPrimary),
              label: Text(
                tr('저장한 이미지 고르기'),
                style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.stroke),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft pulsing placeholder while the album cover loads.
class _Skeleton extends StatefulWidget {
  final Color color;
  const _Skeleton({required this.color});
  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.55, end: 1.0).animate(_c),
    child: ColoredBox(color: widget.color),
  );
}
