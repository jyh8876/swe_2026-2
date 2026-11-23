import 'dart:math';


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
  /// Writes lines back as text: "[mm:ss.xx]text" for timed lines, the text alone otherwise.
  static String format(List<LyricLine> lines) => lines.map((l) {
        final s = l.start;
        if (s == null) return l.text;
        final m = s ~/ 60, sec = s - m * 60;
        return '[${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(2).padLeft(5, '0')}]${l.text}';
      }).join('\n');

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

  /// Only leading tags count; inline tags are rare in LRC files.
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
  static final _normalized = <String, String>{};

  /// Memoised: the matcher runs on every rebuild with the same few titles and artists.
  static String normalize(String s) {
    final hit = _normalized[s];
    if (hit != null) return hit;
    if (_normalized.length > 4000) _normalized.clear();
    return _normalized[s] = _normalize(s);
  }

  static String _normalize(String s) {
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

  /// The title as lyrics sites usually store it: without "(feat. …)", "[Live]" or " - Remastered 2011".
  static String cleanTitle(String title) => title
      .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
      .replaceAll(RegExp(r'\s+-\s+.*$'), '')
      .replaceAll(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false), '')
      .trim();

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

/// A web search for a song's lyrics as an LRC file. The app fetches no lyrics itself: the user
/// opens this search, copies the lyrics (timed LRC when found) and pastes them on the add screen.
class LyricsWebSearch {
  /// Appended to every search so that time-tagged LRC lyrics come up first.
  static const suffix = '.lrc';

  /// "Jay Chou 晴天 .lrc": primary artist, title, then [suffix]; blanks dropped.
  static String query({required String title, String artist = ''}) =>
      [TrackNormalizer.primaryArtist(artist.trim()), title.trim(), suffix].where((s) => s.isNotEmpty).join(' ');

  static Uri url({required String title, String artist = ''}) =>
      Uri.https('www.google.com', '/search', {'q': query(title: title, artist: artist)});

  /// Typing in the in-app browser's bar: a web address opens as is, anything else is searched.
  static Uri urlFor(String input) {
    final t = input.trim();
    final asUrl = RegExp(r'^(https?://)?[\w-]+(\.[\w-]+)+(/\S*)?$', caseSensitive: false);
    if (asUrl.hasMatch(t) && !t.contains(' ')) return Uri.parse(t.startsWith('http') ? t : 'https://$t');
    return Uri.https('www.google.com', '/search', {'q': t});
  }
}

/// Finds lyrics in the text of a web page (in-app browser, "가져오기"). The user chose the page;
/// what is found goes into the add screen on the phone and nowhere else.
class PageLyrics {
  static final _timed = RegExp(r'^\s*(\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+.*$');
  static final _tag = RegExp(r'^\s*\[(ti|ar|al|by|offset|length|re|ve|au):.*\]\s*$', caseSensitive: false);

  /// Minimum number of time-tagged lines for a page to count as an LRC.
  static const minTimedLines = 5;

  /// The LRC lines of [pageText] (tags such as [ti:] kept when they lead the block), or null when
  /// the page has fewer than [minTimedLines] time-tagged lines. Pages that show several LRCs
  /// (versions, translations) give the longest run of consecutive timed lines.
  static String? lrc(String pageText) {
    final lines = pageText.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var best = <String>[], run = <String>[];
    var gap = 0;
    void close() {
      if (run.where(_timed.hasMatch).length > best.where(_timed.hasMatch).length) best = run;
      run = [];
      gap = 0;
    }

    for (final raw in lines) {
      final l = raw.trimRight();
      if (_timed.hasMatch(l) || (run.isEmpty && _tag.hasMatch(l)) || (run.isNotEmpty && _tag.hasMatch(l) && run.every(_tag.hasMatch))) {
        run.add(l.trimLeft());
        gap = 0;
      } else if (run.isNotEmpty && l.trim().isEmpty && gap < 1) {
        // One blank line inside an LRC is kept out but does not end it.
        gap++;
      } else if (run.isNotEmpty) {
        close();
      }
    }
    close();
    final timed = best.where(_timed.hasMatch).length;
    return timed >= minTimedLines ? best.join('\n') : null;
  }
}

/// Local provider backed by fixtures: the demo song in demo mode and tests, nothing in the
/// shipped app (lyrics are pasted, not fetched).
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
