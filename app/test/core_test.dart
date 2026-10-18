import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/core/playback.dart';

// Ports of the LyricsCore XCTest suite, so both platforms are held to the same rules.

void main() {
  group('LRCParser', () {
    test('parses synced lyrics, drops metadata and blank gap lines', () {
      final doc = LRCParser.parse('[ar:Team 9]\n[00:01.00]one\n[00:02.50]two\n[00:04.00]\n[00:05.00]three');
      expect(doc.type, LyricsType.synced);
      expect(doc.lines.map((l) => l.text), ['one', 'two', 'three']);
      expect(doc.lines[1].start, 2.5);
      expect(doc.lines[1].end, 4.0);
    });

    test('expands repeated time tags and sorts', () {
      final doc = LRCParser.parse('[00:10.00][00:01.00]chorus\n[00:05.00]verse');
      expect(doc.lines.map((l) => l.start), [1.0, 5.0, 10.0]);
      expect(doc.lines.first.text, 'chorus');
    });

    test('three-digit fractions and colon fractions', () {
      expect(LRCParser.timeTags('[01:02.345]x').single, closeTo(62.345, 1e-9));
      expect(LRCParser.timeTags('[00:03:50]x').single, closeTo(3.5, 1e-9));
    });

    test('mostly untagged text is plain', () {
      final doc = LRCParser.parse('line a\nline b\n[00:01.00]line c');
      expect(doc.type, LyricsType.plain);
      expect(doc.lines.length, 3);
      expect(doc.lines.every((l) => l.start == null), isTrue);
    });

    test('tag formatting', () => expect(LRCParser.tag(72.5), '[01:12.50]'));

    test('demo song parses to 10 synced lines', () {
      final doc = LRCParser.parse(DemoContent.lrc);
      expect(doc.type, LyricsType.synced);
      expect(doc.lines.length, 10);
    });
  });

  group('TrackMatcher', () {
    test('normalises noise, brackets and feat.', () {
      expect(TrackNormalizer.normalize('Song Title (Official Music Video) [HD]'), 'song title');
      expect(TrackNormalizer.normalize('Song feat. Someone'), 'song');
      expect(TrackNormalizer.normalize('Song - 2011 Remaster'), 'song');
    });

    test('primary artist', () => expect(TrackNormalizer.primaryArtist('A, B & C'), 'A'));

    test('duration tolerance ±2 s', () {
      const a = TrackKey(title: 'Day-Off', artist: 'Team 9', duration: 52);
      expect(TrackMatcher.matches(a, const TrackKey(title: 'day off', artist: 'Team 9', duration: 53.9)), isTrue);
      expect(TrackMatcher.matches(a, const TrackKey(title: 'Day-Off', artist: 'Team 9', duration: 55)), isFalse);
    });

    test('retries a YouTube-style "Artist - Title"', () {
      final song = Song(title: 'Day-Off', artist: 'Team 9', lyricsType: LyricsType.synced, sourceProvider: 'demo');
      final hit = TrackMatcher.match(const TrackKey(title: 'Team 9 - Day-Off (Official MV)', artist: 'Some Channel'), [song]);
      expect(hit?.id, song.id);
    });

    test('rank puts synced and close durations first', () {
      const track = TrackKey(title: 't', artist: 'a', duration: 100);
      final ranked = TrackMatcher.rank(const [
        LyricsCandidate(id: 1, trackName: 't', artistName: 'a', duration: 130, syncedLyrics: '[00:01.00]x'),
        LyricsCandidate(id: 2, trackName: 't', artistName: 'a', duration: 100, plainLyrics: 'x'),
        LyricsCandidate(id: 3, trackName: 't', artistName: 'a', duration: 101, syncedLyrics: '[00:01.00]x'),
      ], track);
      expect(ranked.map((c) => c.id), [3, 2, 1]);
    });
  });

  group('SyncEngine', () {
    final lines = [
      for (final (i, s) in [1.0, 3.0, 6.0].indexed) LyricLine(songID: 'S', index: i, start: s, text: 'l$i'),
    ];

    test('binary search over line starts', () {
      expect(SyncEngine.lineIndex(0.5, lines), isNull);
      expect(SyncEngine.lineIndex(1.0, lines), 0);
      expect(SyncEngine.lineIndex(5.9, lines), 1);
      expect(SyncEngine.lineIndex(100, lines), 2);
    });

    test('extrapolates the playhead and applies the offset', () {
      final t0 = DateTime(2026);
      final e = SyncEngine(offset: 1)
        ..update(PlaybackSnapshot(track: const TrackKey(title: 't', artist: 'a'), position: 2, reportedAt: t0, isPlaying: true));
      expect(e.position(t0.add(const Duration(seconds: 2))), closeTo(4, 1e-6));
      expect(e.currentLineIndex(lines, t0.add(const Duration(seconds: 2))), 1); // 4 − 1 = 3 → line 1
      expect(e.seekTarget(lines[2]), 7);
    });

    test('paused snapshot does not advance', () {
      final t0 = DateTime(2026);
      final e = SyncEngine()
        ..update(PlaybackSnapshot(track: const TrackKey(title: 't', artist: 'a'), position: 2, reportedAt: t0, isPlaying: false));
      expect(e.position(t0.add(const Duration(seconds: 10))), 2);
    });
  });

  group('OutputValidator', () {
    final lines = [for (var i = 0; i < 3; i++) LyricLine(songID: 'S', index: i, text: 'line $i')];

    test('maps every index; missing and degenerate lines fail', () {
      const text = 'Sure! ```json {"lines":[{"i":0,"t":"하나"},{"i":1,"t":"la la la la la la la la"}]} ```';
      final r = OutputValidator.translationResults(text, lines);
      expect(r[0], isA<Translated>());
      expect((r[1] as Failed).reason, 'repetition');
      expect((r[2] as Failed).reason, 'missing');
    });

    test('copy flag', () {
      final r = OutputValidator.translationResults('{"lines":[{"i":0,"copy":true}]}', lines.sublist(0, 1));
      expect(r.single, isA<Copied>());
    });

    test('explanation schema and max 3 expressions', () {
      final e = OutputValidator.explanation(
          '{"expressions":[{"phrase":"a","meaning":"1"},{"phrase":"b","meaning":"2"},{"phrase":"c","meaning":"3"},{"phrase":"d","meaning":"4"}],"structure":"s","usage":"u","example":"x"}');
      expect(e.expressions.length, 3);
      expect(() => OutputValidator.explanation('no json'), throwsA(isA<LLMError>()));
    });
  });

  group('TranslationJob', () {
    test('demo engine translates every line and skips already-done lines', () async {
      final doc = LRCParser.parse(DemoContent.lrc);
      final lines = doc.lyricLines('S');
      final committed = <LineResult>[];
      TranslationProgress? last;
      await TranslationJob(songID: 'S', lines: lines, target: Language.korean, engine: const DemoEngine(lineDelay: Duration.zero))
          .run(alreadyDone: {0, 1}, commit: committed.add, progress: (p) => last = p, token: CancelToken());
      expect(committed.length, lines.length - 2);
      expect(last?.stage, Stage.save);
      expect(last?.done, lines.length);
    });

    test('a cancelled job throws and commits nothing more', () async {
      final lines = LRCParser.parse(DemoContent.lrc).lyricLines('S');
      final token = CancelToken()..cancel();
      final committed = <LineResult>[];
      await expectLater(
        TranslationJob(songID: 'S', lines: lines, target: Language.korean, engine: const DemoEngine(lineDelay: Duration.zero))
            .run(alreadyDone: {}, commit: committed.add, progress: (_) {}, token: token),
        throwsA(isA<CancelledException>()),
      );
      expect(committed, isEmpty);
    });
  });

  group('Collection', () {
    CollectionSnapshot seeded() {
      final snap = CollectionSnapshot();
      final song = Song(id: 'S1', title: 'Day-Off', artist: 'Team 9', duration: 52, lyricsType: LyricsType.synced, sourceProvider: 'demo');
      snap.addSong(song, LRCParser.parse(DemoContent.lrc));
      snap.commit(const Translated(0, '일어나'), songID: 'S1', target: 'ko', engineID: 'demo');
      snap.toggleSaved('S1', 0);
      return snap;
    }

    test('duplicate check and translation text', () {
      final snap = seeded();
      expect(snap.existingSong(const TrackKey(title: 'day off', artist: 'team 9', duration: 53)), isNotNull);
      expect(snap.translationText('S1', 0, 'ko'), '일어나');
      expect(snap.translatedCount('S1', 'ko'), 1);
    });

    test('delete keeps saved phrases by default', () {
      final snap = seeded()..deleteSong('S1');
      expect(snap.songs, isEmpty);
      expect(snap.phrases.length, 1);
      expect(snap.lines.single.index, 0);
    });

    test('export → import round-trip merges without duplicates', () {
      final a = seeded();
      final exported = CollectionMerger.export(a);
      final b = CollectionSnapshot();
      final r1 = CollectionMerger.merge(CollectionMerger.decode(exported), b);
      expect(r1.songsAdded, 1);
      expect(r1.phrasesAdded, 1);
      final r2 = CollectionMerger.merge(CollectionMerger.decode(exported), b);
      expect(r2.songsAdded, 0);
      expect(b.lines.length, a.lines.length);
      expect(b.translations.length, a.translations.length);
    });

    test('import rejects newer schema and garbage', () {
      expect(() => CollectionMerger.decode('{"schemaVersion":99}'), throwsA(isA<ImportError>()));
      expect(() => CollectionMerger.decode('nope'), throwsA(isA<ImportError>()));
    });

    test('reads an iOS export (ISO-8601 dates, uppercase UUIDs, omitted nils)', () {
      const ios = '''{"app":"LyricsTranslator","collection":{"explanations":[],"lines":[{"index":0,"songID":"7D3F0C9E-1111-4A2B-9C3D-000000000001","start":5,"text":"Wake up"}],
        "phrases":[],"sessions":[{"explanationsOpened":[],"linesReached":[0],"songID":"7D3F0C9E-1111-4A2B-9C3D-000000000001","startedAt":"2026-10-10T10:00:00.000Z"}],
        "songs":[{"addedAt":"2026-10-10T09:59:00.123Z","artist":"Team 9","id":"7D3F0C9E-1111-4A2B-9C3D-000000000001","lyricsType":"synced","offset":0,"sourceProvider":"demo","status":"done","title":"Day-Off"}],
        "translations":[]},"exportedAt":"2026-10-10T10:01:00Z","schemaVersion":1}''';
      final snap = CollectionMerger.decode(ios);
      expect(snap.songs.single.status, SongStatus.done);
      expect(snap.songs.single.addedAt.toUtc().millisecond, 123);
      expect(snap.sessions.single.linesReached, {0});
    });

    test('mastery suggestion after 3 play-throughs with 30 % explanations', () {
      final snap = seeded();
      final all = {for (var i = 0; i < 10; i++) i};
      const rules = MasteryRules();
      expect(rules.canMarkConquered('S1', snap), isFalse);
      for (var i = 0; i < 3; i++) {
        snap.sessions.add(ListenSession(songID: 'S1', linesReached: all, explanationsOpened: {i}));
      }
      expect(rules.canMarkConquered('S1', snap), isTrue);
      expect(rules.shouldSuggest('S1', snap), isTrue);
    });
  });

  test('language guess', () {
    expect(LanguageGuess.detect('안녕하세요 반가워요'), 'ko');
    expect(LanguageGuess.detect('Hello there friend'), 'en');
    expect(LanguageGuess.isLikely('일어나 도시가', 'ko'), isTrue);
  });
}
