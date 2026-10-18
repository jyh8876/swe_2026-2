import 'dart:async';

import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/playback.dart';
import 'components.dart';
import 'library.dart';

/// FG-02 Song search (RQ-5, ONRQ-1, ONRQ-11, RQ-17).
class SearchView extends StatefulWidget {
  final String initialQuery;
  const SearchView({super.key, required this.initialQuery});
  @override
  State<SearchView> createState() => _SearchViewState();
}

enum _SearchTab { search, spotify }

class _SearchViewState extends State<SearchView> {
  late final _query = TextEditingController(text: widget.initialQuery);
  List<LyricsCandidate> results = [];
  bool isLoading = false;
  LyricsError? error;
  _SearchTab tab = _SearchTab.search;
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    if (widget.initialQuery.isNotEmpty) _schedule();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  String _last = '';
  void _onQueryChanged() {
    if (_query.text == _last) return;
    _last = _query.text;
    setState(() {});
    _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    // Debounce typing.
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final gen = ++_generation;
    if (q.isEmpty) {
      setState(() => results = []);
      return;
    }
    setState(() => isLoading = true);
    try {
      final found = await context.readModel.lyricsProvider.search(q);
      if (!mounted || gen != _generation) return;
      setState(() {
        // Instrumental results with no lyrics go last.
        results = [
          ...found.where((c) => !c.instrumental || c.hasSynced || c.hasPlain),
          ...found.where((c) => c.instrumental && !c.hasSynced && !c.hasPlain),
        ];
        error = null;
      });
    } on LyricsError catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        results = [];
        error = e;
      });
    } finally {
      if (mounted && gen == _generation) setState(() => isLoading = false);
    }
  }

  void _setQuery(String q) {
    _query.text = q;
    _query.selection = TextSelection.collapsed(offset: q.length);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final spotifyLinked = model.settings.connectedSources.contains(SourceID.spotify);
    return Scaffold(
      appBar: AppBar(title: const Text('노래 검색')),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Container(
              decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10)),
              child: TextField(
                controller: _query,
                autocorrect: false,
                autofocus: widget.initialQuery.isEmpty,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: TextStyle(color: t.textPrimary),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.search, color: t.textSecondary),
                  hintText: '제목, 아티스트 검색',
                  hintStyle: TextStyle(color: t.textTertiary),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '지우기',
                          icon: Icon(Icons.cancel, color: t.textTertiary, size: 20),
                          onPressed: () => _setQuery('')),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          // Users without Spotify see no empty playlist tab (FG-02 note).
          if (spotifyLinked)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(children: [
                _tabButton('검색', _SearchTab.search),
                _tabButton('내 스포티파이 플레이리스트', _SearchTab.spotify),
              ]),
            ),
          Expanded(child: _content()),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SecondaryButton('직접 추가하기', icon: Icons.add, onPressed: () => model.push(AddRoute(AddSongDraft()))),
          ),
        ]),
      ),
    );
  }

  Widget _tabButton(String title, _SearchTab value) {
    final t = context.theme;
    final on = tab == value;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => tab = value),
        child: Column(children: [
          const SizedBox(height: 4),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: on ? t.textPrimary : t.textSecondary)),
          const SizedBox(height: 8),
          Container(height: on ? 2 : 1, color: on ? t.textPrimary : t.stroke),
        ]),
      ),
    );
  }

  Widget _content() {
    final model = context.model;
    final t = context.theme;
    if (tab == _SearchTab.spotify) return _spotifyPlaylists();
    if (_query.text.trim().isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: CuratedShelvesView(shelves: model.shelves, onSelect: (e, _) => _setQuery('${e.title} ${e.artist}')),
      );
    }
    if (isLoading && results.isEmpty) return Center(child: CircularProgressIndicator(color: t.textSecondary));
    if (results.isEmpty) return _noResults();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (_, i) => _resultRow(results[i]),
    );
  }

  /// Mock "my playlists" (built from the curated shelves) until the Spotify Web API is wired.
  Widget _spotifyPlaylists() {
    final model = context.model;
    final t = context.theme;
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      for (final shelf in model.shelves) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(shelf.title, style: TextStyle(fontSize: 13, color: t.textSecondary)),
        ),
        for (final e in shelf.songs)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            onTap: () {
              _setQuery('${e.title} ${e.artist}');
              setState(() => tab = _SearchTab.search);
            },
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(6)),
              child: Icon(Icons.music_note, color: t.textTertiary),
            ),
            title: Text(e.title, maxLines: 1, style: TextStyle(fontSize: 14, color: t.textPrimary)),
            subtitle: Text(e.artist, maxLines: 1, style: TextStyle(fontSize: 12, color: t.textSecondary)),
            trailing: model.collection.existingSong(e.trackKey) != null
                ? Icon(Icons.check_circle, color: t.accent, semanticLabel: '이미 추가됨')
                : null,
          ),
      ],
    ]);
  }

  Widget _noResults() {
    final t = context.theme;
    final offline = error?.kind == LyricsErrorKind.offline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.wifi_off : Icons.music_note, size: 40, color: t.textTertiary),
          const SizedBox(height: 12),
          Text(offline ? '오프라인' : '가사를 찾지 못했어요',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.textPrimary)),
          const SizedBox(height: 12),
          Text(
            offline
                ? '검색하려면 인터넷 연결이 필요해요. 가사를 붙여넣어 직접 추가할 수는 있어요.'
                : error == null
                    ? '영어 제목이나 원래 언어의 제목으로 다시 검색해 보세요.\n또는 가사를 붙여넣어 직접 추가할 수 있어요.'
                    : '가사 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: t.textSecondary),
          ),
        ]),
      ),
    );
  }

  Widget _resultRow(LyricsCandidate c) {
    final t = context.theme;
    return InkWell(
      onTap: () => _select(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(6))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.trackName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: t.textPrimary)),
              const SizedBox(height: 3),
              Text('${TrackNormalizer.primaryArtist(c.artistName)} · ${(c.duration ?? 0).mmss}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textSecondary)),
            ]),
          ),
          const SizedBox(width: 8),
          LyricsBadge(c.availability),
        ]),
      ),
    );
  }

  void _select(LyricsCandidate c) {
    final model = context.readModel;
    final existing = model.collection.existingSong(c.trackKey);
    if (existing != null) {
      // Duplicate add → open the existing LP (RQ-6).
      model.push(PlayerRoute(existing.id));
      return;
    }
    // "No lyrics" results cannot be added without pasting (ONRQ-1) → manual add pre-filled.
    final draft = AddSongDraft.fromCandidate(c);
    if (c.availability == Availability.none) draft.lyrics = '';
    model.push(AddRoute(draft));
  }
}
