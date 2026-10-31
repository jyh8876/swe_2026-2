import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/spotify_library.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import '../core/playback.dart';
import 'components.dart';
import 'covers.dart';

/// Spotify album art from the network, with a generated cover while loading or on failure.
class SpotifyArt extends StatelessWidget {
  final String? url;
  final String seed;
  final double radius;
  const SpotifyArt({super.key, required this.url, required this.seed, this.radius = 4});

  @override
  Widget build(BuildContext context) {
    final fallback = GeneratedCover(seed: seed, radius: radius);
    if (url == null) return fallback;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.network(
          url!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          loadingBuilder: (_, child, p) => p == null ? child : fallback,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// The "내 Spotify" panel: connect / reconnect prompts, then liked songs, playlists and saved albums
/// with their cover art. Used in the search screen's Spotify tab.
class SpotifyLibraryPanel extends StatefulWidget {
  const SpotifyLibraryPanel({super.key});
  @override
  State<SpotifyLibraryPanel> createState() => _SpotifyLibraryPanelState();
}

class _SpotifyLibraryPanelState extends State<SpotifyLibraryPanel> {
  bool _refresh = false;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final auth = model.spotifyAuth;
    if (!auth.isConfigured) return _prompt(t, tr('이 빌드에는 Spotify 앱 정보가 없어요.'), null, null);
    if (!auth.hasToken || !model.settings.connectedSources.contains(SourceID.spotify)) {
      return _prompt(t, tr('Spotify에 연결하면 내 플레이리스트와 저장한 앨범을 커버와 함께 불러와요.'), tr('Spotify 연결하기'), () => model.connect(SourceID.spotify));
    }
    if (!auth.hasLibraryScopes) {
      return _prompt(t, tr('플레이리스트와 앨범을 읽으려면 권한을 한 번 더 허용해야 해요.'), tr('Spotify 다시 연결하기'), auth.startLogin);
    }
    final future = model.spotifyLists(refresh: _refresh);
    _refresh = false;
    return FutureBuilder<(List<SpotifyList>, List<SpotifyList>)>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return Center(child: CircularProgressIndicator(color: t.textSecondary));
        if (snap.hasError) {
          return _prompt(t, '${snap.error}', tr('다시 시도'), () => setState(() => _refresh = true));
        }
        final (playlists, albums) = snap.data!;
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _refresh = true);
            await model.spotifyLists(refresh: false).catchError((_) => (const <SpotifyList>[], const <SpotifyList>[]));
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20), children: [
            _ListRow(list: SpotifyList.liked, icon: Icons.favorite_rounded),
            const SizedBox(height: 20),
            _header(t, tr('플레이리스트'), playlists.length),
            if (playlists.isEmpty) _empty(t, tr('플레이리스트가 없어요')),
            _grid(playlists),
            const SizedBox(height: 20),
            _header(t, tr('저장한 앨범'), albums.length),
            if (albums.isEmpty) _empty(t, tr('Spotify에서 앨범을 저장하면 여기에 보여요')),
            _grid(albums),
          ]),
        );
      },
    );
  }

  Widget _header(AppTheme t, String title, int n) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(width: 6),
          Text('$n', style: TextStyle(fontSize: 13, color: t.textTertiary)),
        ]),
      );

  Widget _empty(AppTheme t, String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text, style: TextStyle(fontSize: 13, color: t.textTertiary)));

  Widget _grid(List<SpotifyList> lists) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 16) / 2;
        return Wrap(spacing: 16, runSpacing: 16, children: [for (final l in lists) SizedBox(width: w, child: SpotifyListTile(list: l, size: w))]);
      });

  Widget _prompt(AppTheme t, String text, String? action, VoidCallback? onTap) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.library_music_outlined, size: 40, color: t.textTertiary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: t.textSecondary)),
            if (action != null) ...[
              const SizedBox(height: 20),
              PrimaryButton(action, onPressed: onTap),
            ],
          ]),
        ),
      );
}

/// A playlist or album cover with its name; opens the track list.
class SpotifyListTile extends StatelessWidget {
  final SpotifyList list;
  final double size;
  const SpotifyListTile({super.key, required this.list, required this.size});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    return Semantics(
      button: true,
      label: '${list.name}${list.subtitle == null ? '' : ', ${list.subtitle}'}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => model.push(SpotifyListRoute(list)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: size,
            height: size,
            child: list.kind == SpotifyListKind.liked
                ? _likedArt()
                : Stack(fit: StackFit.expand, children: [
                    SpotifyArt(url: list.imageUrl, seed: list.id),
                    if (list.kind == SpotifyListKind.playlist && !list.readable)
                      Positioned(right: 6, top: 6, child: Icon(Icons.lock_outline, size: 18, color: Colors.white.withValues(alpha: 0.85))),
                  ]),
          ),
          const SizedBox(height: 8),
          Text(tr(list.name), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary)),
          Text(
            [if (list.subtitle != null && list.subtitle!.isNotEmpty) list.subtitle!, if (list.total != null) tr('{0}곡', [list.total])].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: t.textTertiary),
          ),
        ]),
      ),
    );
  }

}

Widget _likedArt() => Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF4F3CC9), Color(0xFF9FD6C8)]),
      ),
      child: const Center(child: Icon(Icons.favorite_rounded, color: Colors.white, size: 28)),
    );

class _ListRow extends StatelessWidget {
  final SpotifyList list;
  final IconData icon;
  const _ListRow({required this.list, required this.icon});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => model.push(SpotifyListRoute(list)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            SizedBox(width: 48, height: 48, child: _likedArt()),
            const SizedBox(width: 12),
            Expanded(child: Text(tr(list.name), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary))),
            Icon(Icons.chevron_right, color: t.textTertiary),
          ]),
        ),
      ),
    );
  }
}

/// "내 Spotify" row on the home screen: liked songs, playlists and albums with their covers.
class SpotifyShelf extends StatelessWidget {
  const SpotifyShelf({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    if (!model.spotifyLibraryReady) return const SizedBox();
    return FutureBuilder<(List<SpotifyList>, List<SpotifyList>)>(
      future: model.spotifyLists(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox();
        final (playlists, albums) = snap.data!;
        final lists = [SpotifyList.liked, ...playlists.take(10), ...albums.take(10)];
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Text(tr('내 Spotify'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.textPrimary)),
                const SizedBox(width: 8),
                Text(tr('플레이리스트 · 앨범'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
              ]),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 166,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: lists.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => SizedBox(width: 112, child: SpotifyListTile(list: lists[i], size: 112)),
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// Tracks of one Spotify list. Tapping a track finds its lyrics and opens the add screen with the
/// album art as the cover.
class SpotifyTracksView extends StatefulWidget {
  final SpotifyList list;
  const SpotifyTracksView({super.key, required this.list});
  @override
  State<SpotifyTracksView> createState() => _SpotifyTracksViewState();
}

class _SpotifyTracksViewState extends State<SpotifyTracksView> {
  late Future<List<SpotifyTrack>> _tracks = context.readModel.spotifyLibrary.tracks(widget.list);
  String? _busyID;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final l = widget.list;
    return Scaffold(
      appBar: AppBar(title: Text(l.kind == SpotifyListKind.album ? tr('앨범') : (l.kind == SpotifyListKind.liked ? 'Spotify' : tr('플레이리스트')))),
      body: FutureBuilder<List<SpotifyTrack>>(
        future: _tracks,
        builder: (context, snap) {
          final header = Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(children: [
              SizedBox(width: 96, height: 96, child: l.kind == SpotifyListKind.liked ? _likedArt() : SpotifyArt(url: l.imageUrl, seed: l.id)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr(l.name), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
                  if (l.subtitle != null) Text(l.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.textSecondary)),
                  const SizedBox(height: 4),
                  Text(snap.hasData ? tr('{0}곡 · 탭하면 가사와 함께 추가돼요', [snap.data!.length]) : tr('불러오는 중…'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
                ]),
              ),
            ]),
          );
          if (snap.connectionState != ConnectionState.done) {
            return Column(children: [header, Expanded(child: Center(child: CircularProgressIndicator(color: t.textSecondary)))]);
          }
          if (snap.hasError) {
            return Column(children: [
              header,
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Text('${snap.error}', textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() => _tracks = model.spotifyLibrary.tracks(l)),
                    child: Text(tr('다시 시도'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ]);
          }
          final tracks = snap.data!;
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: tracks.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) return header;
              final track = tracks[i - 1];
              final owned = model.collection.existingSong(track.trackKey) != null;
              return InkWell(
                onTap: _busyID != null ? null : () => _select(track),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(children: [
                    SizedBox(width: 48, height: 48, child: SpotifyArt(url: track.imageUrl, seed: track.id, radius: 3)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: t.textPrimary)),
                        const SizedBox(height: 2),
                        Text('${track.artist}${track.duration == null ? '' : ' · ${track.duration!.mmss}'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textTertiary)),
                      ]),
                    ),
                    if (_busyID == track.id)
                      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: t.textSecondary))
                    else if (owned)
                      Icon(Icons.check_circle, color: t.brand, semanticLabel: tr('이미 추가됨'))
                    else
                      Icon(Icons.add_circle_outline, color: t.textTertiary),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _select(SpotifyTrack track) async {
    final model = context.readModel;
    final existing = model.collection.existingSong(track.trackKey);
    if (existing != null) {
      model.push(PlayerRoute(existing.id));
      return;
    }
    setState(() => _busyID = track.id);
    LyricsCandidate? found;
    var failed = false;
    try {
      found = await model.lyricsProvider.lyrics(track.trackKey);
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() => _busyID = null);
    final AddSongDraft draft;
    if (found != null && found.availability != Availability.none) {
      draft = AddSongDraft.fromCandidate(found);
    } else {
      draft = AddSongDraft();
      showMessage(context, failed ? tr('가사 서버가 붐벼서 가사를 못 불러왔어요. 붙여넣거나 잠시 후 다시 시도해 주세요.') : tr('이 곡의 가사를 찾지 못했어요. 가사를 붙여넣어 추가할 수 있어요.'));
    }
    // Spotify's names and album art win over LRCLIB's.
    draft
      ..title = track.title
      ..artist = TrackNormalizer.primaryArtist(track.artist)
      ..album = track.album ?? draft.album
      ..duration = track.duration ?? draft.duration
      ..coverURL = track.imageUrl
      ..spotifyTrackID = track.id;
    model.push(AddRoute(draft));
  }
}
