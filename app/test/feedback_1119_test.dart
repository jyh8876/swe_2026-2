import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Feedback 11/19 (1차 테스트): add flow without the search step, per-song 독음.
void main() {
  Future<AppModel> model(CollectionSnapshot snap, {bool reading = true}) async {
    SharedPreferences.setMockInitialValues({});
    return AppModel.test(
        collection: snap,
        settings: AppSettings()
          ..hasOnboarded = true
          ..showReading = reading,
        prefs: await SharedPreferences.getInstance(),
        baseDir: Directory.systemTemp.createTempSync());
  }

  test('#3/#10 a recommended track opens the add screen with title and artist in their own fields', () async {
    final m = await model(CollectionSnapshot());
    m.openAdd(const TrackKey(title: 'Count on Me', artist: 'Bruno Mars, Someone', duration: 197));
    final route = m.libraryPath.last as AddRoute;
    expect(route.draft.title, 'Count on Me');
    expect(route.draft.artist, 'Bruno Mars');
    expect(route.draft.duration, 197);

    // "+ 노래 추가" goes straight to an empty add screen.
    m.setPath([]);
    m.openAdd();
    expect((m.libraryPath.single as AddRoute).draft.title, '');
  });

  test('#3 a track already in the collection opens its LP instead', () async {
    final snap = CollectionSnapshot();
    final song = Song(title: 'Count on Me', artist: 'Bruno Mars', lyricsType: LyricsType.plain, sourceProvider: 'manual', status: SongStatus.done);
    snap.addSong(song, LRCParser.parse('a'));
    final m = await model(snap);
    m.openAdd(const TrackKey(title: 'Count on Me', artist: 'Bruno Mars'), true);
    expect((m.libraryPath.single as PlayerRoute).songID, song.id);
  });

  test('#8 독음 is kept per song; the 마이페이지 switch is the default for new songs', () async {
    final m = await model(CollectionSnapshot(), reading: false);
    final a = m.addSong(AddSongDraft()
      ..title = 'A'
      ..artist = 'X'
      ..lyrics = 'line');
    expect(m.readingOn(a), isFalse);
    m.setReading(a, true);
    expect(m.readingOn(a), isTrue);
    // Changing the default later leaves existing songs alone.
    m.updateSettings((s) => s.showReading = false);
    expect(m.readingOn(a), isTrue);
    m.updateSettings((s) => s.showReading = true);
    final b = m.addSong(AddSongDraft()
      ..title = 'B'
      ..artist = 'Y'
      ..lyrics = 'line');
    expect(m.readingOn(b), isTrue);
    m.setReading(b, false);
    expect(m.readingOn(b), isFalse);
    expect(m.readingOn(a), isTrue);
  });

  test('#8 the per-song 독음 choice survives saving', () {
    final s = Song(title: 'A', artist: 'X', lyricsType: LyricsType.plain, sourceProvider: 'manual', showReading: false);
    final c = DateCodec.local;
    expect(Song.fromJson(s.toJson(c), c).showReading, isFalse);
    final legacy = s.toJson(c)..remove('showReading');
    expect(Song.fromJson(legacy, c).showReading, isNull);
  });
}
