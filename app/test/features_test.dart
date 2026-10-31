import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/app/theme.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/core/quiz.dart';
import 'package:lyrics_translator/core/recommend.dart';
import 'package:lyrics_translator/ui/library.dart' show carouselOffset;
import 'package:shared_preferences/shared_preferences.dart';

// Original sample lines written for these tests.
const _lines = [
  'Morning light is falling on the window',
  'I keep walking slowly down the river',
  'Morning light is falling on the window',
  'Every little dream becomes a story',
  'Hold the silver moon above the city',
  'Paper boats are sailing through the rain',
  'Oh oh oh',
];

List<LyricLine> _sample() => [for (var i = 0; i < _lines.length; i++) LyricLine(songID: 's', index: i, text: _lines[i])];

Song _song(String title, String artist, {String? shelf}) =>
    Song(title: title, artist: artist, lyricsType: LyricsType.plain, sourceProvider: 'manual', curatedShelfID: shelf);

const _shelves = [
  CuratedShelf('easy-first', 'Easy', 'Easy', [ShelfEntry('Yellow', 'Coldplay', 269), ShelfEntry('Perfect', 'Ed Sheeran', 263)]),
  CuratedShelf('popular', 'Popular', 'Popular', [ShelfEntry('Shape of You', 'Ed Sheeran', 234), ShelfEntry('Happy', 'Pharrell Williams', 233)]),
];

void main() {
  group('Recommender', () {
    test('interleaves shelves and skips songs already in the collection', () {
      final c = CollectionSnapshot()..songs.add(_song('Yellow', 'Coldplay'));
      final picks = Recommender.pick(_shelves, c).map((e) => e.title).toList();
      expect(picks, ['Shape of You', 'Perfect', 'Happy']);
    });

    test('after a song: same artist first, never the song itself', () {
      final added = _song('Perfect', 'Ed Sheeran', shelf: 'easy-first');
      final c = CollectionSnapshot()..songs.add(added);
      final picks = Recommender.pick(_shelves, c, after: added).map((e) => e.title).toList();
      expect(picks.first, 'Shape of You');
      expect(picks, isNot(contains('Perfect')));
    });
  });

  test('search results: one row per song, synced lyrics preferred, capped', () {
    final found = [
      const LyricsCandidate(id: 1, trackName: 'Yellow', artistName: 'Coldplay', plainLyrics: 'a'),
      const LyricsCandidate(id: 2, trackName: 'Yellow (Remastered)', artistName: 'Coldplay', syncedLyrics: '[00:01.00]a'),
      const LyricsCandidate(id: 3, trackName: 'Yellow', artistName: 'Coldplay feat. X', plainLyrics: 'a'),
      const LyricsCandidate(id: 4, trackName: 'Trouble', artistName: 'Coldplay', plainLyrics: 'b'),
      for (var i = 0; i < 30; i++) LyricsCandidate(id: 100 + i, trackName: 'Song $i', artistName: 'Band', plainLyrics: 'x'),
    ];
    final r = SearchResults.dedupe(found);
    expect(r.length, SearchResults.maxResults);
    expect(r.first.id, 2);
    expect(r[1].id, 4);
  });

  group('QuizBuilder', () {
    test('repeated lines count once and filler lines are skipped', () {
      final eligible = QuizBuilder.eligibleLines(_sample(), 1).map((l) => l.index).toList();
      expect(eligible, isNot(contains(2)));
      expect(eligible, isNot(contains(6)));
      expect(QuizBuilder.canQuiz(_sample()), isTrue);
    });

    test('levels 1–2 have four distinct choices with the answer; the blank rebuilds the line', () {
      for (final level in [1, 2]) {
        final qs = QuizBuilder.build(lines: _sample(), translations: {0: '아침 햇살이 창문에 내려요'}, level: level, rng: Random(1));
        expect(qs.length, 5);
        for (final q in qs) {
          expect(q.choices.length, 4);
          expect(q.choices.toSet().length, 4);
          expect(q.choices, contains(q.answer));
          expect('${q.before}${q.answer}${q.after}', _lines[q.lineIndex]);
          if (level == 2) expect(QuizBuilder.clean(q.answer).length, greaterThanOrEqualTo(5));
        }
      }
    });

    test('level 3 is typed and forgiving about case and punctuation', () {
      final q = QuizBuilder.build(lines: _sample(), translations: const {}, level: 3, rng: Random(2)).first;
      expect(q.typed, isTrue);
      expect(q.isCorrect(' ${q.answer.toUpperCase()}! '), isTrue);
      expect(q.isCorrect('zzz'), isFalse);
    });
  });

  group('QuizProgress', () {
    test('keeps the highest level, counts a streak, forgets deleted songs', () async {
      SharedPreferences.setMockInitialValues({});
      final p = QuizProgress(await SharedPreferences.getInstance());
      p.pass('a', 2);
      p.pass('a', 1);
      expect(p.level('a'), 2);
      p.markToday();
      expect(p.streak, 1);
      p.forget('a');
      expect(p.level('a'), 0);
    });
  });

  test('theme settings round-trip and default to the Figma dark theme', () {
    expect(AppSettings().themeBase, ThemeBase.dark);
    final s = AppSettings()
      ..themeBase = ThemeBase.light
      ..accent = AccentColor.blue;
    final back = AppSettings.fromJson(s.toJson());
    expect(back.themeBase, ThemeBase.light);
    expect(back.accent, AccentColor.blue);
    final t = AppTheme.of(back.themeBase, back.accent);
    expect(identical(t, AppTheme.of(ThemeBase.light, AccentColor.blue)), isTrue);
    expect(t.brand, AccentColor.blue.color);
    expect(t.isDark, isFalse);
  });

  group('LRCLIB busy handling', () {
    test('retries 503 with Retry-After, then succeeds', () async {
      var calls = 0;
      final waits = <Duration>[];
      final c = LRCLIBClient(
        client: MockClient((_) async => ++calls < 3
            ? http.Response('{"name":"ServerOverloaded"}', 503, headers: {'retry-after': '1'})
            : http.Response('[{"id":1,"trackName":"Yellow","artistName":"Coldplay","plainLyrics":"a"}]', 200)),
        sleep: (d) async => waits.add(d),
      );
      final r = await c.search('yellow');
      expect(r.single.trackName, 'Yellow');
      expect(calls, 3);
      expect(waits, [const Duration(seconds: 1), const Duration(milliseconds: 1500)]);
    });

    test('gives up after the last attempt with a busy error', () async {
      final c = LRCLIBClient(client: MockClient((_) async => http.Response('', 503)), sleep: (_) async {});
      await expectLater(c.search('x'), throwsA(isA<LyricsError>().having((e) => e.kind, 'kind', LyricsErrorKind.busy)));
    });
  });

  test('album slide loops: neighbours on both sides of the first and last album', () {
    expect(carouselOffset(0, 0, 5), 0);
    expect(carouselOffset(4, 0, 5), -1); // left of the first album is the last one
    expect(carouselOffset(1, 0, 5), 1);
    expect(carouselOffset(0, 4, 5), 1); // right of the last album is the first one
    expect(carouselOffset(2, -1, 5), -2); // after swiping right past the start
    expect(carouselOffset(0, 0.4, 1), -0.4);
  });

  test('LRCLIB exact lookup retries without album, then with a clean title', () async {
    final asked = <Map<String, String>>[];
    final c = LRCLIBClient(
      client: MockClient((req) async {
        asked.add(req.url.queryParameters);
        return req.url.queryParameters['track_name'] == 'The Ocean' && !req.url.queryParameters.containsKey('album_name')
            ? http.Response('{"id":7,"trackName":"The Ocean","artistName":"Mike Perry","syncedLyrics":"[00:01.00]x"}', 200)
            : http.Response('{"message":"not found"}', 404);
      }),
      sleep: (_) async {},
    );
    final r = await c.lyrics(const TrackKey(title: 'The Ocean (feat. Shy Martin)', artist: 'Mike Perry, Shy Martin', album: 'The Ocean', duration: 183.4));
    expect(r?.id, 7);
    expect(asked.length, 3);
    expect(asked.first['album_name'], 'The Ocean');
    expect(asked.last['duration'], '183');
    expect(TrackNormalizer.cleanTitle('Yesterday - Remastered 2009'), 'Yesterday');
  });
}
