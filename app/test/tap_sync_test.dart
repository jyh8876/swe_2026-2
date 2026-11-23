import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/core/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Tap to sync: lyrics on the phone's own clock for music the app can't follow, and line times
// written by tapping along.
void main() {
  final t0 = DateTime(2026, 11, 10, 12);

  group('TapSyncClock', () {
    test('runs from the tapped time, pauses and jumps on another tap', () {
      final c = TapSyncClock('s', 20, now: t0);
      expect(c.position(t0.add(const Duration(seconds: 3))), closeTo(23, 1e-6));
      c.setPlaying(false, now: t0.add(const Duration(seconds: 5)));
      expect(c.position(t0.add(const Duration(seconds: 60))), closeTo(25, 1e-6));
      c.seek(40, now: t0.add(const Duration(seconds: 61)));
      expect(c.isPlaying, isTrue);
      expect(c.position(t0.add(const Duration(seconds: 63))), closeTo(42, 1e-6));
    });
  });

  group('TapRecorder', () {
    test('marks lines in order, never earlier than the line before, and undoes', () {
      final r = TapRecorder(3);
      r.mark(1);
      r.mark(0.5); // a slip: kept at the previous line's time
      expect(r.starts, [1, 1]);
      r.undo();
      r.mark(4);
      expect(r.done, isFalse);
      r.mark(9);
      r.mark(12); // past the last line: ignored
      expect(r.done, isTrue);
      expect(r.starts, [1, 4, 9]);
    });
  });

  test('tapped times turn plain lyrics into synced ones and keep translations', () {
    final snap = CollectionSnapshot();
    final song = Song(id: 'p', title: 'Plain', artist: 'Team', lyricsType: LyricsType.plain, sourceProvider: 'manual', offset: 1);
    snap.addSong(song, LRCParser.parse('one\ntwo\nthree'));
    snap.translations.add(Translation(songID: 'p', index: 1, targetLanguage: 'en', text: 'zwei', engineID: 'x', promptVersion: 'v1', outcome: Outcome.translated));
    snap.touch();
    snap.setLineStarts('p', [2, 5, 9]);
    final lines = snap.linesFor('p');
    expect(lines.map((l) => l.start), [2, 5, 9]);
    expect(lines.map((l) => l.end), [5, 9, null]);
    expect(lines.map((l) => l.text), ['one', 'two', 'three']);
    expect(snap.song('p')!.lyricsType, LyricsType.synced);
    expect(snap.song('p')!.offset, 0);
    expect(snap.translationText('p', 1, 'en'), 'zwei');
  });

  group('model', () {
    late AppModel model;
    late Song song;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      song = Song(id: 'song-a', title: 'Morning', artist: 'Team', duration: 120, lyricsType: LyricsType.synced, sourceProvider: 'manual', status: SongStatus.done);
      final snap = CollectionSnapshot();
      snap.addSong(song, LRCParser.parse('[00:05.00]Morning light\n[00:10.00]Falls on the window\n[00:15.00]We walk along'));
      model = AppModel.test(collection: snap, settings: AppSettings()..hasOnboarded = true, prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
    });

    test('a tap on the heard line makes the lyrics follow; seek and pause move the clock only', () {
      expect(model.positionOf(song), isNull);
      model.startTapSync(song, 10);
      expect(model.tapSynced(song), isTrue);
      expect(model.isPlayingSong(song), isTrue);
      expect(model.positionOf(song), closeTo(10, 0.2));
      model.seekSong(song, 15); // another tap: no music app is asked to play
      expect(model.positionOf(song), closeTo(15, 0.2));
      expect(model.banner, isNull);
      model.togglePlaySong(song);
      expect(model.isPlayingSong(song), isFalse);
      model.stopTapSync();
      expect(model.positionOf(song), isNull);
    });

    test('without Spotify or a followed music app, play starts tap to sync and says so', () async {
      await model.playSong(song, at: 5);
      expect(model.tapSynced(song), isTrue);
      expect(model.positionOf(song), closeTo(5, 0.2));
      expect(model.banner?.message, isNotNull);
    });

    test('saved tap times sync the song and keep the lyrics running', () {
      final plain = Song(id: 'p', title: 'Plain', artist: 'Team', lyricsType: LyricsType.plain, sourceProvider: 'manual');
      model.collection.addSong(plain, LRCParser.parse('one\ntwo'));
      model.saveTapTimings('p', [0, 4], now: 4);
      expect(model.collection.song('p')!.lyricsType, LyricsType.synced);
      expect(model.tapSynced(plain), isTrue);
      expect(model.positionOf(plain), closeTo(4, 0.2));
    });
  });
}
