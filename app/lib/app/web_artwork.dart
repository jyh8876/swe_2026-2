import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/lyrics.dart';

/// Album art from Apple's iTunes Search API (free, no key), for covers without a Spotify login.
class WebArtwork {
  final http.Client client;
  WebArtwork({http.Client? client}) : client = client ?? http.Client();

  /// The cover URL (600 px) of the best match for [title] by [artist], or null.
  Future<String?> find(String title, String artist) async {
    final term = '${TrackNormalizer.primaryArtist(artist)} ${TrackNormalizer.cleanTitle(title)}'.trim();
    final r = await client
        .get(Uri.https('itunes.apple.com', '/search', {'term': term, 'media': 'music', 'entity': 'song', 'limit': '5'}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw http.ClientException('iTunes search ${r.statusCode}');
    final results = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['results'] as List? ?? const []).whereType<Map>();
    final exact = TrackNormalizer.cleanTitle(title).toLowerCase();
    final loose = TrackNormalizer.normalize(title);
    String name(Map e) => '${e['trackName'] ?? ''}';
    // Prefer the exact title (not a live or remix version), then the same normalised title,
    // then iTunes' own ranking.
    final hit = results.where((e) => name(e).toLowerCase() == exact).firstOrNull ??
        results.where((e) => TrackNormalizer.normalize(name(e)) == loose).firstOrNull ??
        results.firstOrNull;
    final url = hit?['artworkUrl100'] as String?;
    return url?.replaceFirst(RegExp(r'/\d+x\d+bb\.'), '/600x600bb.');
  }
}
