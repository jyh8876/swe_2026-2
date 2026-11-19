import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/core/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Any music app, followed through Android's media sessions; the platform channels are simulated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vinylo/media_session');
  const events = EventChannel('vinylo/media_session/state');

  late AppModel model;
  late Song song;
  late List<MethodCall> calls;
  late StreamController<Object?> sessions;

  Map<String, Object?> report({String title = 'Morning', bool playing = true, int positionMs = 10000, int ageMs = 0, bool canSeek = true}) => {
        'package': 'com.google.android.apps.youtube.music',
        'app': 'YouTube Music',
        'title': title,
        'artist': 'Team',
        'durationMs': 120000,
        'positionMs': positionMs,
        'ageMs': ageMs,
        'speed': playing ? 1.0 : 0.0,
        'playing': playing,
        'canSeek': canSeek,
        'canSkip': true,
        'hasArt': false,
      };

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    MusicApp.debugSupported = true;
    calls = [];
    sessions = StreamController<Object?>.broadcast();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) { 'hasAccess' => true, _ => null };
    });
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, sink) => sessions.stream.listen(sink.success)));
    song = Song(id: 'song-a', title: 'Morning', artist: 'Team', duration: 120, lyricsType: LyricsType.synced, sourceProvider: 'manual', status: SongStatus.done);
    SharedPreferences.setMockInitialValues({});
    final snap = CollectionSnapshot();
    snap.addSong(song, LRCParser.parse('[00:05.00]Morning light\n[00:10.00]Falls on the window\n[00:15.00]We walk along'));
    // No Spotify: the user never logged in.
    model = AppModel.test(collection: snap, settings: AppSettings()..hasOnboarded = true, prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
  });

  tearDown(() {
    sessions.close();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    MusicApp.debugSupported = null;
  });

  test('a song playing in another app links to its lyrics, measured from when the app reported', () async {
    expect(await model.attachMusicApp(), isTrue);
    sessions.add(report(positionMs: 10000, ageMs: 2000));
    await settle();
    expect(model.activeSourceID, SourceID.musicApp);
    expect(model.nowPlaying?.appName, 'YouTube Music');
    expect(model.nowPlayingSong?.id, song.id);
    expect(model.positionOf(song), closeTo(12, 0.3)); // reported 2 s ago at 10 s
    sessions.add({'none': true});
    await settle();
    expect(model.nowPlaying, isNull);
  });

  test('without Spotify, play asks the music app to find the song, then seeks once it plays', () async {
    await model.playSong(song, at: 30);
    final search = calls.where((c) => c.method == 'playFromSearch').single;
    expect(search.arguments['query'], 'Team Morning');
    expect(model.isPlayingSong(song), isTrue); // the screens switch at once
    sessions.add(report(positionMs: 0));
    await settle();
    expect(calls.where((c) => c.method == 'seek').single.arguments, {'positionMs': 30000});
    // The music app's album art becomes the cover of a song that has none.
    expect(calls.any((c) => c.method == 'artwork'), isTrue);
  });

  test('seeking is refused politely when the music app cannot seek', () async {
    await model.attachMusicApp();
    sessions.add(report(canSeek: false));
    await settle();
    model.seekSong(song, 40);
    expect(calls.where((c) => c.method == 'seek'), isEmpty);
    expect(model.banner?.message, isNotNull);
  });

  test('without notification access, play offers to connect instead of faking playback', () async {
    messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'hasAccess' ? false : null);
    await model.playSong(song);
    expect(model.isPlayingSong(song), isFalse);
    expect(model.banner?.actionTitle, isNotNull);
  });
}
