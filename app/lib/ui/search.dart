import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/playback.dart';
import '../core/recommend.dart';
import 'components.dart';
import 'lyrics_browser.dart';
import 'covers.dart';
import 'library.dart';
import 'spotify_library.dart';

/// FG-02 Song search. The app fetches no lyrics: the main action opens a web search for the
/// song's LRC ("artist title .lrc") and the add screen, where the copied lyrics are pasted.
class SearchView extends StatefulWidget {
  final String initialQuery;
  final TrackKey? hint;
  const SearchView({super.key, required this.initialQuery, this.hint});
  @override
  State<SearchView> createState() => _SearchViewState();
}

enum _SearchTab { search, spotify }

class _SearchViewState extends State<SearchView> {
  late final _query = TextEditingController(text: widget.initialQuery);

  /// Local matches only (the demo song in demo mode); the shipped app has none.
  List<LyricsCandidate> results = [];
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
    _debounce = Timer(const Duration(milliseconds: 600), _search);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final gen = ++_generation;
    final found = q.isEmpty
        ? <LyricsCandidate>[]
        : await context.readModel.lyricsProvider.search(q);
    if (!mounted || gen != _generation) return;
    setState(() => results = SearchResults.dedupe(found));
  }

  /// The known track (recommendation, now playing) when the query is still the one it came with.
  TrackKey? get _hintForQuery {
    final hint = widget.hint;
    return hint != null && _query.text.trim() == widget.initialQuery.trim()
        ? hint
        : null;
  }

  /// Opens the in-app browser on the LRC search, then the add screen with what was taken there.
  Future<void> _searchWeb() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final hint = _hintForQuery;
    final draft = AddSongDraft()
      ..title = hint?.title ?? q
      ..artist = hint == null ? '' : TrackNormalizer.primaryArtist(hint.artist)
      ..album = hint?.album
      ..duration = hint?.duration;
    final model = context.readModel;
    draft.lyrics =
        (await openLyricsBrowser(
          context,
          title: draft.title,
          artist: draft.artist,
        ))?.trim() ??
        '';
    if (!mounted) return;
    model.push(AddRoute(draft));
  }

  void _setQuery(String q) {
    _query.text = q;
    _query.selection = TextSelection.collapsed(offset: q.length);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final spotifyLinked = model.settings.connectedSources.contains(
      SourceID.spotify,
    );
    return Scaffold(
      appBar: AppBar(title: Text(tr('노래 추가')), centerTitle: true),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Users without Spotify see no empty playlist tab (FG-02 note).
            // iOS: the Apple Music library (Spotify login is Android only, feedback 11/22 #4).
            if (Platform.isIOS
                ? MusicApp.supported
                : SpotifyAuth.available && (spotifyLinked || model.spotifyAuth.isConfigured))
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
                child: Row(
                  children: [
                    _tabButton(tr('검색'), _SearchTab.search),
                    _tabButton(tr('내 플레이리스트'), _SearchTab.spotify),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextField(
                  controller: _query,
                  autocorrect: false,
                  autofocus: widget.initialQuery.isEmpty,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchWeb(),
                  style: TextStyle(color: t.textPrimary),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.search, color: t.textSecondary),
                    hintText: tr('제목, 아티스트 검색'),
                    hintStyle: TextStyle(color: t.textTertiary),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr('지우기'),
                            icon: Icon(
                              Icons.cancel,
                              color: t.textTertiary,
                              size: 20,
                            ),
                            onPressed: () => _setQuery(''),
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
            Expanded(child: _content()),
            Divider(
              height: 1,
              thickness: 1,
              color: t.stroke.withValues(alpha: 0.6),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                children: [
                  Text(
                    tr('원하는 노래가 없다면, 직접 추가할 수 있어요.'),
                    style: TextStyle(fontSize: 13, color: t.textTertiary),
                  ),
                  const SizedBox(height: 10),
                  SecondaryButton(
                    tr('직접 추가하기'),
                    icon: Icons.add,
                    onPressed: () => model.push(AddRoute(AddSongDraft())),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String title, _SearchTab value) {
    final t = context.theme;
    final on = tab == value;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => tab = value),
        child: Column(
          children: [
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: on ? t.textPrimary : t.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Container(height: on ? 2 : 1, color: on ? t.textPrimary : t.stroke),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final model = context.model;
    if (tab == _SearchTab.spotify) return _spotifyPlaylists();
    if (_query.text.trim().isEmpty) {
      // Suggestions before searching: easy songs, popular songs and more.
      return SingleChildScrollView(
        padding: const EdgeInsets.only(top: 8, bottom: 20),
        child: CuratedShelvesView(
          shelves: model.shelves,
          onSelect: (e, _) => _setQuery('${e.title} ${e.artist}'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [_webSearchRow(), for (final c in results) _resultRow(c)],
    );
  }

  /// The user's Spotify playlists, saved albums and liked songs, with cover art.
  Widget _spotifyPlaylists() => const SpotifyLibraryPanel();

  /// The main action: "artist title .lrc" on the web.
  Widget _webSearchRow() {
    final t = context.theme;
    final hint = _hintForQuery;
    final q = LyricsWebSearch.query(
      title: hint?.title ?? _query.text,
      artist: hint?.artist ?? '',
    );
    return InkWell(
      onTap: _searchWeb,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.travel_explore, color: t.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('인터넷에서 가사 찾기'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    q,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: t.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(LyricsCandidate c) {
    final t = context.theme;
    return InkWell(
      onTap: () => _select(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: GeneratedCover(
                seed: '${c.artistName}—${c.trackName}',
                radius: 4,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.trackName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: t.textPrimary),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${TrackNormalizer.primaryArtist(c.artistName)} · ${(c.duration ?? 0).mmss}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            LyricsBadge(c.availability),
          ],
        ),
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
