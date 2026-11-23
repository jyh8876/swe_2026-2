import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'i18n.dart';
import 'platform_services.dart';

/// A Spotify track reduced to what the app needs. [imageUrl] is the album cover (widest first in
/// Spotify's list); Spotify image URLs expire within a day, so covers are downloaded when kept.
class SpotifyTrack {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final double? duration;
  final String? imageUrl;
  const SpotifyTrack({required this.id, required this.title, required this.artist, this.album, this.duration, this.imageUrl});

  TrackKey get trackKey => TrackKey(title: title, artist: artist, album: album, duration: duration);

  /// Reads a TrackObject. Returns null for episodes, local files and unavailable (null) items.
  static SpotifyTrack? fromJson(Object? j, {String? albumName, String? albumImage}) {
    if (j is! Map || j['type'] == 'episode' || j['is_local'] == true) return null;
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    final artists = ((j['artists'] as List?) ?? const []).map((a) => (a as Map)['name']).whereType<String>().join(', ');
    final album = j['album'] as Map?;
    return SpotifyTrack(
      id: '${j['id'] ?? name}',
      title: name,
      artist: artists,
      album: (album?['name'] as String?) ?? albumName,
      duration: (j['duration_ms'] as num?) == null ? null : (j['duration_ms'] as num) / 1000,
      imageUrl: SpotifyLibrary.pickImage(album?['images'], target: 640) ?? albumImage,
    );
  }
}

enum SpotifyListKind { playlist, album, liked }

/// A playlist, a saved album, or the "liked songs" list.
class SpotifyList {
  final SpotifyListKind kind;
  final String id;
  final String name;
  final String? subtitle;
  final String? imageUrl;
  final int? total;

  /// Spotify only returns the contents of playlists the user owns or collaborates on.
  final bool readable;

  /// Albums come with their tracks, so no second request is needed.
  final List<SpotifyTrack>? tracks;

  const SpotifyList({
    required this.kind,
    required this.id,
    required this.name,
    this.subtitle,
    this.imageUrl,
    this.total,
    this.readable = true,
    this.tracks,
  });

  static const liked = SpotifyList(kind: SpotifyListKind.liked, id: 'liked', name: '좋아요 표시한 곡');
}

class SpotifyLibraryException implements Exception {
  final String message;
  final int? status;
  const SpotifyLibraryException(this.message, [this.status]);
  @override
  String toString() => message;
}

/// Spotify Web API library reads, following the February 2026 Development Mode rules:
/// `GET /me/playlists`, `GET /playlists/{id}/items` (entries in `item`; `track` is deprecated),
/// `GET /me/albums`, `GET /me/tracks`, and `GET /search` with at most 10 results.
class SpotifyLibrary {
  final SpotifyAuth auth;
  SpotifyLibrary(this.auth);

  static const _maxPages = 6; // up to 300 entries per list

  static String? pickImage(Object? images, {int target = 300}) {
    if (images is! List) return null;
    final list = images.whereType<Map>().where((m) => m['url'] is String).toList();
    if (list.isEmpty) return null;
    int w(Map m) => (m['width'] as num?)?.toInt() ?? 0;
    // The smallest image at least [target] wide, else the largest one.
    final wide = list.where((m) => w(m) >= target).toList()..sort((a, b) => w(a).compareTo(w(b)));
    if (wide.isNotEmpty) return wide.first['url'] as String;
    list.sort((a, b) => w(b).compareTo(w(a)));
    return list.first['url'] as String;
  }

  Future<Map> _get(String path, [Map<String, String>? query]) async {
    final token = await auth.accessToken();
    final r = await auth.client
        .get(Uri.https('api.spotify.com', '/v1/$path', query), headers: {'authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) throw SpotifyLibraryException(tr('Spotify 로그인이 만료됐어요. 다시 연결해 주세요.'), 401);
    if (r.statusCode == 403) {
      throw SpotifyLibraryException(
          tr('이 목록을 읽을 권한이 없어요. Spotify를 다시 연결하거나, 대시보드 User Management에 계정이 있는지 확인해 주세요.'), 403);
    }
    if (r.statusCode == 429) throw SpotifyLibraryException(tr('Spotify 요청이 너무 많아요. 잠시 후 다시 시도해 주세요.'), 429);
    if (r.statusCode != 200) throw SpotifyLibraryException(tr('Spotify 오류 ({0})', [r.statusCode]), r.statusCode);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  }

  /// Follows `next` links of a paging object.
  Future<List<Object?>> _paged(String path, Map<String, String> query) async {
    final out = <Object?>[];
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      final j = await _get(path, {...query, 'limit': '50', 'offset': '$offset'});
      final items = (j['items'] as List?) ?? const [];
      out.addAll(items);
      if (j['next'] == null || items.isEmpty) break;
      offset += items.length;
    }
    return out;
  }

  Future<String?> myID() async => (await _get('me'))['id'] as String?;

  Future<List<SpotifyList>> playlists() async {
    final me = await myID();
    final raw = await _paged('me/playlists', const {});
    return [
      for (final p in raw.whereType<Map>())
        SpotifyList(
          kind: SpotifyListKind.playlist,
          id: '${p['id']}',
          name: '${p['name'] ?? ''}',
          subtitle: (p['owner'] as Map?)?['display_name'] as String?,
          imageUrl: pickImage(p['images']),
          total: ((p['items'] as Map?)?['total'] ?? (p['tracks'] as Map?)?['total']) as int?,
          readable: p['collaborative'] == true || (p['owner'] as Map?)?['id'] == me,
        ),
    ];
  }

  Future<List<SpotifyList>> savedAlbums() async {
    final raw = await _paged('me/albums', const {});
    final out = <SpotifyList>[];
    for (final e in raw.whereType<Map>()) {
      final a = e['album'] as Map?;
      if (a == null) continue;
      final image = pickImage(a['images']);
      final big = pickImage(a['images'], target: 640);
      final tracks = (((a['tracks'] as Map?)?['items'] as List?) ?? const [])
          .map((t) => SpotifyTrack.fromJson(t, albumName: a['name'] as String?, albumImage: big))
          .whereType<SpotifyTrack>()
          .toList();
      out.add(SpotifyList(
        kind: SpotifyListKind.album,
        id: '${a['id']}',
        name: '${a['name'] ?? ''}',
        subtitle: ((a['artists'] as List?) ?? const []).map((x) => (x as Map)['name']).join(', '),
        imageUrl: image,
        total: (a['total_tracks'] as num?)?.toInt() ?? tracks.length,
        tracks: tracks,
      ));
    }
    return out;
  }

  Future<List<SpotifyTrack>> tracks(SpotifyList list) async {
    switch (list.kind) {
      case SpotifyListKind.album:
        if (list.tracks != null) return list.tracks!;
        final a = await _get('albums/${list.id}');
        final big = pickImage(a['images'], target: 640);
        return (((a['tracks'] as Map?)?['items'] as List?) ?? const [])
            .map((t) => SpotifyTrack.fromJson(t, albumName: a['name'] as String?, albumImage: big))
            .whereType<SpotifyTrack>()
            .toList();
      case SpotifyListKind.liked:
        final raw = await _paged('me/tracks', const {});
        return raw.whereType<Map>().map((e) => SpotifyTrack.fromJson(e['track'])).whereType<SpotifyTrack>().toList();
      case SpotifyListKind.playlist:
        if (!list.readable) {
          throw SpotifyLibraryException(tr('Spotify는 내가 만들었거나 함께 편집하는 플레이리스트의 곡만 보여줘요.'), 403);
        }
        final raw = await _paged('playlists/${list.id}/items', const {'additional_types': 'track'});
        return raw.whereType<Map>().map((e) => SpotifyTrack.fromJson(e['item'] ?? e['track'])).whereType<SpotifyTrack>().toList();
    }
  }

  /// Best match for a song in the collection, used to fetch its album cover.
  Future<SpotifyTrack?> findTrack(String title, String artist) async {
    final j = await _get('search', {'q': 'track:$title artist:$artist', 'type': 'track', 'limit': '1'});
    final items = ((j['tracks'] as Map?)?['items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    final m = items.first as Map;
    return SpotifyTrack.fromJson(m)?.withImage(pickImage((m['album'] as Map?)?['images'], target: 640));
  }

  /// Downloads a cover image to a temporary file (for the add screen's cover preview).
  static Future<File?> downloadToTemp(String url, Directory dir) async {
    final bytes = await download(url);
    if (bytes == null) return null;
    dir.createSync(recursive: true);
    final f = File('${dir.path}/spotify-${url.hashCode.toUnsigned(32)}.jpg');
    await f.writeAsBytes(bytes);
    return f;
  }

  static Future<Uint8List?> download(String url) async {
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      return r.statusCode == 200 && r.bodyBytes.isNotEmpty ? r.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }
}

extension on SpotifyTrack {
  SpotifyTrack withImage(String? url) =>
      SpotifyTrack(id: id, title: title, artist: artist, album: album, duration: duration, imageUrl: url ?? imageUrl);
}
