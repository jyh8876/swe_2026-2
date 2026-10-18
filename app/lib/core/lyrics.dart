import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'models.dart';

// ─────────────────────────────── LRC parsing ───────────────────────────────

class DocLine {
  final double? start;
  final double? end;
  final String text;
  const DocLine({this.start, this.end, required this.text});
}

/// Parsed lyrics, independent of any song record.
class LyricsDocument {
  final List<DocLine> lines;
  final LyricsType type;
  const LyricsDocument(this.lines, this.type);

  List<LyricLine> lyricLines(String songID) => [
        for (var i = 0; i < lines.length; i++)
          LyricLine(songID: songID, index: i, start: lines[i].start, end: lines[i].end, text: lines[i].text),
      ];
}

/// LRC parsing (SSRD A.III `parseLRC`, RQ-6).
class LRCParser {
  /// Text in which at least this share of non-empty lines starts with a time tag is synced (RQ-6).
  static const syncedThreshold = 0.8;

  // Matches [mm:ss], [mm:ss.x], [mm:ss.xx], [mm:ss.xxx] and [mm:ss:xx].
  static final _tag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _meta = RegExp(r'^\[(ar|ti|al|by|offset|length|re|ve|au|#):.*\]$');

  /// Parses LRC or plain text. Metadata tags such as [ar:...] are dropped,
  /// multiple time tags on one line are expanded, and lines are sorted by time.
  static LyricsDocument parse(String text) {
    final raw = text.replaceAll('\r\n', '\n').split('\n').map((s) => s.trim());
    final nonEmpty = raw.where((s) => s.isNotEmpty && !isMetadataTag(s)).toList();
    if (nonEmpty.isEmpty) return const LyricsDocument([], LyricsType.plain);

    final tagged = nonEmpty.where((s) => timeTags(s).isNotEmpty).length;
    final isSynced = tagged / nonEmpty.length >= syncedThreshold;

    if (!isSynced) {
      final lines = nonEmpty.map((s) => DocLine(text: stripTags(s))).where((l) => l.text.isNotEmpty).toList();
      return LyricsDocument(lines, LyricsType.plain);
    }

    final timed = <(double, String)>[];
    for (final s in nonEmpty) {
      final tags = timeTags(s);
      if (tags.isEmpty) continue;
      final body = stripTags(s);
      for (final t in tags) {
        timed.add((t, body));
      }
    }
    // Stable sort by time.
    final indexed = timed.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.$1.compareTo(b.$2.$1);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final sorted = indexed.map((e) => e.$2).toList();

    // Empty-bodied timed lines mark instrumental gaps: they end the previous line
    // but are not shown as lyric lines themselves.
    final lines = <DocLine>[];
    for (var i = 0; i < sorted.length; i++) {
      final next = i + 1 < sorted.length ? sorted[i + 1].$1 : null;
      if (sorted[i].$2.isEmpty) continue;
      lines.add(DocLine(start: sorted[i].$1, end: next, text: sorted[i].$2));
    }
    return LyricsDocument(lines, LyricsType.synced);
  }

  /// Only leading tags count; inline tags are rare in LRCLIB.
  static List<double> timeTags(String line) {
    final result = <double>[];
    var cursor = 0;
    while (cursor < line.length) {
      final m = _tag.matchAsPrefix(line, cursor);
      if (m == null) break;
      final minutes = double.parse(m[1]!);
      final seconds = double.parse(m[2]!);
      var fraction = 0.0;
      if (m[3] != null) {
        fraction = double.parse(m[3]!) / pow(10, m[3]!.length);
      }
      result.add(minutes * 60 + seconds + fraction);
      cursor = m.end;
    }
    return result;
  }

  static String stripTags(String line) => line.replaceAll(_tag, '').trim();

  static bool isMetadataTag(String line) => _meta.hasMatch(line);

  /// Formats seconds as an LRC tag, e.g. 12.34 → "[00:12.34]".
  static String tag(double seconds) {
    final total = max(0.0, seconds);
    final m = total ~/ 60;
    final s = total - m * 60;
    return '[${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(2).padLeft(5, '0')}]';
  }
}

// ─────────────────────────────── Matching ───────────────────────────────

/// Title/artist normalisation for matching noisy now-playing metadata (RQ-3, ONRQ-4).
class TrackNormalizer {
  static const _noiseTags = [
    'official music video', 'official video', 'official audio', 'official mv', 'official',
    'lyric video', 'lyrics', 'lyric', 'mv', 'm/v', 'audio', 'remastered', 'remaster',
    'radio edit', 'explicit', 'hd', '4k',
  ];
  static final _alnum = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

  /// Lowercases, strips bracketed tags, "feat." clauses, noise words, and punctuation.
  static String normalize(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    t = t.replaceAll(RegExp(r'\b(feat\.?|ft\.?|featuring)\s.*$'), ' ');
    t = t.replaceAll(RegExp(r'\s-\s.*\b(remaster(ed)?|version|edit|live)\b.*$'), ' ');
    for (final tag in _noiseTags) {
      t = t.replaceAll(RegExp('\\b${RegExp.escape(tag)}\\b'), ' ');
    }
    final buf = StringBuffer();
    for (final ch in t.runes.map(String.fromCharCode)) {
      buf.write(_alnum.hasMatch(ch) ? ch : ' ');
    }
    return buf.toString().split(' ').where((w) => w.isNotEmpty).join(' ');
  }

  /// "Coldplay/Coldplay", "A, B & C" → first artist (SIR-7).
  static String primaryArtist(String artist) => artist.split(RegExp(r'[/,&;]')).first.trim();

  /// Splits a YouTube-style title "Artist - Song (Official MV)" into (artist, title).
  static (String artist, String title)? splitArtistTitle(String s) {
    final parts = s.split(' - ');
    if (parts.length < 2) return null;
    return (parts.first.trim(), parts.skip(1).join(' - ').trim());
  }
}

/// Matching rule: normalised title + primary artist, and duration within ±2 s when both known (RQ-3).
class TrackMatcher {
  static const durationTolerance = 2.0;

  static bool matches(TrackKey a, TrackKey b) {
    if (TrackNormalizer.normalize(a.title) != TrackNormalizer.normalize(b.title)) return false;
    final artistA = TrackNormalizer.normalize(TrackNormalizer.primaryArtist(a.artist));
    final artistB = TrackNormalizer.normalize(TrackNormalizer.primaryArtist(b.artist));
    if (!(artistA == artistB || artistA.contains(artistB) || artistB.contains(artistA))) return false;
    if (a.duration != null && b.duration != null) {
      return (a.duration! - b.duration!).abs() <= durationTolerance;
    }
    return true;
  }

  /// Finds the collection song for the playing track; retries with a split "Artist - Title" (ONRQ-4).
  static Song? match(TrackKey playing, List<Song> songs) {
    for (final s in songs) {
      if (matches(s.trackKey, playing)) return s;
    }
    final split = TrackNormalizer.splitArtistTitle(playing.title);
    if (split != null) {
      final retry = TrackKey(title: split.$2, artist: split.$1, duration: playing.duration);
      for (final s in songs) {
        if (matches(s.trackKey, retry)) return s;
      }
    }
    return null;
  }

  /// Ranks lyrics candidates: synced first, then closest duration; >2 s off is ranked last (ONRQ-2).
  static List<LyricsCandidate> rank(List<LyricsCandidate> candidates, TrackKey track) {
    (int, int, double) score(LyricsCandidate c) {
      final delta = (c.duration != null && track.duration != null) ? (c.duration! - track.duration!).abs() : 0.0;
      final off = delta > durationTolerance ? 1 : 0;
      final sync = c.hasSynced ? 0 : (c.hasPlain ? 1 : 2);
      return (off, sync, delta);
    }

    int cmp((int, int, double) a, (int, int, double) b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    }

    final list = [...candidates];
    list.sort((a, b) => cmp(score(a), score(b)));
    return list;
  }
}

// ─────────────────────────────── Providers ───────────────────────────────

enum Availability { synced, plain, none }

/// A lyrics search result. `hasSynced` / `hasPlain` drive the badges in search (RQ-5).
class LyricsCandidate {
  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final double? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  const LyricsCandidate({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory LyricsCandidate.fromJson(Map<String, dynamic> j) => LyricsCandidate(
        id: (j['id'] as num).toInt(),
        trackName: '${j['trackName'] ?? j['name'] ?? ''}',
        artistName: '${j['artistName'] ?? ''}',
        albumName: j['albumName'] as String?,
        duration: (j['duration'] as num?)?.toDouble(),
        instrumental: j['instrumental'] == true,
        plainLyrics: j['plainLyrics'] as String?,
        syncedLyrics: j['syncedLyrics'] as String?,
      );

  bool get hasSynced => (syncedLyrics ?? '').isNotEmpty;
  bool get hasPlain => (plainLyrics ?? '').isNotEmpty;

  /// Badge state; exactly reflects syncedLyrics / plainLyrics presence (RQ-5).
  Availability get availability => hasSynced ? Availability.synced : (hasPlain ? Availability.plain : Availability.none);

  /// Best lyrics text for parsing: synced if present, else plain.
  String? get bestLyricsText => hasSynced ? syncedLyrics : (hasPlain ? plainLyrics : null);

  TrackKey get trackKey => TrackKey(title: trackName, artist: artistName, album: albumName, duration: duration);
}

/// SSRD A.III `LyricsProvider`.
abstract class LyricsProvider {
  Future<List<LyricsCandidate>> search(String query);
  Future<LyricsCandidate?> lyrics(TrackKey track);
}

enum LyricsErrorKind { offline, http, decoding }

class LyricsError implements Exception {
  final LyricsErrorKind kind;
  final int? status;
  const LyricsError(this.kind, [this.status]);
  @override
  String toString() => 'LyricsError($kind, $status)';
}

/// LRCLIB adapter (SIR-7). Plain HTTPS GET, no key; polite User-Agent; results cached in memory.
class LRCLIBClient implements LyricsProvider {
  final http.Client _client;
  final Uri baseURL;
  final String userAgent;
  final _cache = <String, List<LyricsCandidate>>{};

  LRCLIBClient({http.Client? client, Uri? baseURL, this.userAgent = 'LyricsTranslator/0.1 (https://github.com/team9/lyricstranslator)'})
      : _client = client ?? http.Client(),
        baseURL = baseURL ?? Uri.parse('https://lrclib.net/api');

  @override
  Future<List<LyricsCandidate>> search(String query) async {
    final key = 'search:${query.toLowerCase()}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final body = await _get(baseURL.replace(path: '${baseURL.path}/search', queryParameters: {'q': query}));
    if (body is! List) throw const LyricsError(LyricsErrorKind.decoding);
    final results = body.map((e) => LyricsCandidate.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    _cache[key] = results;
    return results;
  }

  @override
  Future<LyricsCandidate?> lyrics(TrackKey track) async {
    final q = <String, String>{
      'track_name': track.title,
      'artist_name': TrackNormalizer.primaryArtist(track.artist),
      if (track.album != null) 'album_name': track.album!,
      if (track.duration != null) 'duration': '${track.duration!.round()}',
    };
    try {
      final body = await _get(baseURL.replace(path: '${baseURL.path}/get', queryParameters: q));
      return LyricsCandidate.fromJson(Map<String, dynamic>.from(body as Map));
    } on LyricsError catch (e) {
      if (e.kind == LyricsErrorKind.http && e.status == 404) return null;
      rethrow;
    }
  }

  Future<Object?> _get(Uri url) async {
    http.Response r;
    try {
      r = await _client.get(url, headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const LyricsError(LyricsErrorKind.offline);
    }
    if (r.statusCode < 200 || r.statusCode >= 300) throw LyricsError(LyricsErrorKind.http, r.statusCode);
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw const LyricsError(LyricsErrorKind.decoding);
    }
  }
}

/// Offline provider backed by fixtures; used by tests and the demo mode.
class StaticLyricsProvider implements LyricsProvider {
  final List<LyricsCandidate> candidates;
  const StaticLyricsProvider(this.candidates);

  @override
  Future<List<LyricsCandidate>> search(String query) async {
    final q = TrackNormalizer.normalize(query);
    if (q.isEmpty) return [];
    return candidates.where((c) {
      final hay = TrackNormalizer.normalize('${c.trackName} ${c.artistName}');
      return q.split(' ').every(hay.contains);
    }).toList();
  }

  @override
  Future<LyricsCandidate?> lyrics(TrackKey track) async {
    for (final c in candidates) {
      if (TrackMatcher.matches(c.trackKey, track)) return c;
    }
    return null;
  }
}

/// LRCLIB, plus the bundled demo song so the app is usable offline and in review.
class DemoAwareLyricsProvider implements LyricsProvider {
  final LyricsProvider remote;
  final LyricsProvider demo;
  DemoAwareLyricsProvider({LyricsProvider? remote})
      : remote = remote ?? LRCLIBClient(),
        demo = StaticLyricsProvider(DemoContent.candidates);

  @override
  Future<List<LyricsCandidate>> search(String query) async {
    final local = await demo.search(query);
    try {
      return [...local, ...await remote.search(query)];
    } catch (_) {
      if (local.isNotEmpty) return local;
      rethrow;
    }
  }

  @override
  Future<LyricsCandidate?> lyrics(TrackKey track) async {
    final hit = await demo.lyrics(track);
    if (hit != null) return hit;
    final exact = await remote.lyrics(track);
    if (exact != null) return exact;
    final ranked = TrackMatcher.rank(await remote.search('${track.title} ${track.artist}'), track);
    return ranked.isEmpty ? null : ranked.first;
  }
}

/// Offline demo content so the app runs end-to-end with no network.
/// Lyrics are original text written for this prototype.
class DemoContent {
  static const songTitle = 'Day-Off';
  static const songArtist = 'Team 9';

  static const lrc = '''[00:05.00]Wake up, the city's humming low
[00:09.20]I've been running on empty since the summer show
[00:13.80]But you said take it easy, let it go
[00:18.10]So I'm calling it a day-off, nowhere to go
[00:22.60]
[00:24.00]No alarms, no deadlines on my mind
[00:28.30]Leave the rush hour traffic far behind
[00:32.70]We could talk until the sun goes down
[00:37.00]Just you and me against this sleepy town
[00:41.50]Hit pause on everything, it's fine
[00:45.80]Today the whole world can wait in line''';

  static final candidate = LyricsCandidate(
    id: -1,
    trackName: songTitle,
    artistName: songArtist,
    albumName: 'Prototype',
    duration: 52,
    plainLyrics: LRCParser.parse(lrc).lines.map((l) => l.text).join('\n'),
    syncedLyrics: lrc,
  );

  static const plainOnly = LyricsCandidate(
    id: -2,
    trackName: 'Quiet Room',
    artistName: 'Team 9',
    albumName: 'Prototype',
    duration: 120,
    plainLyrics: 'Lights are low in the quiet room\nEvery word you say is a little too soon',
  );

  static const noLyrics = LyricsCandidate(
    id: -3,
    trackName: 'Instrumental Interlude',
    artistName: 'Team 9',
    albumName: 'Prototype',
    duration: 90,
    instrumental: true,
  );

  static List<LyricsCandidate> get candidates => [candidate, plainOnly, noLyrics];
}
