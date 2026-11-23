import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/app/spotify_library.dart';

// Responses shaped like the Spotify Web API reference (February 2026 Development Mode).
Map<String, dynamic> _track(String name, {String album = 'Album', List<int> widths = const [640, 300, 64]}) => {
      'type': 'track',
      'id': 'id-$name',
      'name': name,
      'duration_ms': 200500,
      'is_local': false,
      'artists': [
        {'name': 'Artist A'},
        {'name': 'Artist B'}
      ],
      'album': {
        'name': album,
        'images': [for (final w in widths) {'url': 'https://i.scdn.co/$w', 'width': w, 'height': w}],
      },
    };

void main() {
  late List<Uri> calls;

  SpotifyLibrary library(Map<String, Object> routes) {
    calls = [];
    final client = MockClient((req) async {
      calls.add(req.url);
      expect(req.headers['authorization'], 'Bearer tok');
      final body = routes[req.url.path];
      if (body == null) return http.Response('{}', 404);
      if (body is int) return http.Response('{}', body);
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final auth = SpotifyAuth(SecureStore(), client: client)..debugSetAccessToken('tok');
    return SpotifyLibrary(auth);
  }

  test('playlists: items.total, cover near 300 px, only own or collaborative playlists readable', () async {
    final lib = library({
      '/v1/me': {'id': 'me1'},
      '/v1/me/playlists': {
        'next': null,
        'items': [
          {
            'id': 'p1', 'name': 'Mine', 'collaborative': false, 'owner': {'id': 'me1', 'display_name': 'Me'},
            'images': [{'url': 'https://mosaic/640', 'width': 640}, {'url': 'https://mosaic/300', 'width': 300}],
            'items': {'total': 12},
          },
          {'id': 'p2', 'name': 'Theirs', 'collaborative': false, 'owner': {'id': 'other'}, 'images': [], 'items': {'total': 3}},
          {'id': 'p3', 'name': 'Shared', 'collaborative': true, 'owner': {'id': 'other'}, 'images': null, 'tracks': {'total': 5}},
        ],
      },
    });
    final ps = await lib.playlists();
    expect(ps.map((p) => p.readable), [true, false, true]);
    expect(ps.first.imageUrl, 'https://mosaic/300');
    expect(ps.first.total, 12);
    expect(ps.last.total, 5); // older "tracks" field still read
    expect(calls.firstWhere((u) => u.path == '/v1/me/playlists').queryParameters['limit'], '50');
  });

  test('playlist items: reads "item", skips null, local and episode entries, pages with next', () async {
    final lib = library({
      '/v1/playlists/p1/items': {
        'next': null,
        'items': [
          {'item': _track('One')},
          {'item': null},
          {'is_local': true, 'item': {..._track('Local'), 'is_local': true}},
          {'item': {'type': 'episode', 'name': 'Pod'}},
          {'track': _track('Legacy')},
        ],
      },
    });
    const list = SpotifyList(kind: SpotifyListKind.playlist, id: 'p1', name: 'Mine');
    final ts = await lib.tracks(list);
    expect(ts.map((t) => t.title), ['One', 'Legacy']);
    expect(ts.first.artist, 'Artist A, Artist B');
    expect(ts.first.duration, closeTo(200.5, 0.001));
    expect(ts.first.imageUrl, 'https://i.scdn.co/640');
    expect(calls.single.queryParameters['additional_types'], 'track');
  });

  test('saved albums carry their tracks with the album cover', () async {
    final lib = library({
      '/v1/me/albums': {
        'next': null,
        'items': [
          {
            'album': {
              'id': 'a1', 'name': 'Sky', 'total_tracks': 2,
              'artists': [{'name': 'Band'}],
              'images': [{'url': 'https://img/640', 'width': 640}, {'url': 'https://img/300', 'width': 300}],
              'tracks': {'items': [{'type': 'track', 'id': 't1', 'name': 'Blue', 'duration_ms': 1000, 'artists': [{'name': 'Band'}]}]},
            }
          }
        ],
      },
    });
    final albums = await lib.savedAlbums();
    expect(albums.single.imageUrl, 'https://img/300');
    final ts = await lib.tracks(albums.single);
    expect(ts.single.imageUrl, 'https://img/640');
    expect(ts.single.album, 'Sky');
    expect(calls.length, 1); // album tracks need no second request
  });

  test('liked songs use /me/tracks; 403 explains the cause', () async {
    final ok = library({'/v1/me/tracks': {'next': null, 'items': [{'track': _track('Liked')}]}});
    expect((await ok.tracks(SpotifyList.liked)).single.title, 'Liked');
    final denied = library({'/v1/me/tracks': 403});
    await expectLater(denied.tracks(SpotifyList.liked), throwsA(isA<SpotifyLibraryException>().having((e) => e.status, 'status', 403)));
  });

  test('cover search for collection songs asks for one result', () async {
    final lib = library({
      '/v1/search': {'tracks': {'items': [_track('Yellow')]}},
    });
    final hit = await lib.findTrack('Yellow', 'Coldplay');
    expect(hit?.imageUrl, 'https://i.scdn.co/640');
    expect(calls.single.queryParameters['limit'], '1');
    expect(calls.single.queryParameters['type'], 'track');
  });
}
