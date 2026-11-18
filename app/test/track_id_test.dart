import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/core/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('media session ids: Spotify gives the bare track id, other apps package|id', () {
    expect(mediaTrackID('com.spotify.music', 'spotify:track:4uLU6hMCjMI75M1A2tKUQC'), '4uLU6hMCjMI75M1A2tKUQC');
    expect(mediaTrackID('com.google.android.apps.youtube.music', 'abc123'), 'com.google.android.apps.youtube.music|abc123');
    expect(mediaTrackID('x', null), isNull);
    expect(mediaTrackID('x', ' '), isNull);
  });

  test('a song stays recognised when the music app shows its title in another language', () async {
    SharedPreferences.setMockInitialValues({});
    final snap = CollectionSnapshot();
    final song = Song(title: 'Lemon', artist: 'Kenshi Yonezu', duration: 255, lyricsType: LyricsType.plain, sourceProvider: 'manual', status: SongStatus.done);
    snap.addSong(song, LRCParser.parse('a'));
    final m = AppModel.test(collection: snap, settings: AppSettings()..hasOnboarded = true, prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
    PlaybackSnapshot playing(String title, String artist) =>
        PlaybackSnapshot(track: TrackKey(title: title, artist: artist, duration: 255), position: 1, isPlaying: true, trackID: '04TshWXkhV1qkqHzf31Hn6');
    m.debugReport(playing('Lemon', 'Kenshi Yonezu'));
    expect(m.nowPlayingSong?.id, song.id);
    // Same track after the display language changed: different title and artist text.
    m.debugReport(playing('レモン', '米津玄師'));
    expect(m.nowPlayingSong?.id, song.id);
    expect(m.isNowPlaying(song), isTrue);
    // A different track id is a different song.
    m.debugReport(PlaybackSnapshot(track: const TrackKey(title: 'レモン', artist: '米津玄師', duration: 255), position: 1, isPlaying: true, trackID: 'other'));
    expect(m.nowPlayingSong, isNull);
  });
}
