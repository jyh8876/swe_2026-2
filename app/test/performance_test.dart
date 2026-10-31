import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Original sample lyrics written for these tests.
const _ko = ['오늘은 천천히 걸어가도 괜찮아', '창문 너머로 햇살이 내려와', '우리의 노래가 다시 시작돼', '조용한 거리에 너의 목소리', '내일도 여기서 만나자'];
const _en = ['I walk along the river in the morning light', 'You and I are dancing in the rain', 'All the stars are shining for the night', 'Hold my hand and never let me go', 'Love is the song that we sing'];
const _ja = ['あなたと歩いた道を思い出す', '夜空に光る星をみつめて', 'このうたが届くまで歌うよ', 'さよならは言わないでね'];
const _zh = ['我们一起走过的那条小路', '晴天的时候你在我身边', '故事里的小黄花开了', '这首歌送给远方的你'];
const _de = ['Ich gehe mit dir durch die Nacht', 'Du bist das Licht in meinem Leben', 'Wir tanzen und die Sterne sind mit uns', 'Ich liebe dich und das ist nicht genug'];
const _fr = ['Je marche avec toi dans la nuit', 'Tu es la lumière de ma vie', 'Nous dansons et les étoiles sont avec nous', 'Je ne veux pas que tu partes pour moi'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('collection indexes answer exactly like the old full scans', () {
    late CollectionSnapshot c;
    final rnd = Random(4);

    // Reference implementations: the linear scans the indexes replaced.
    Translation? slowTranslation(String s, int i, String t) {
      Translation? best;
      for (final x in c.translations) {
        if (x.songID == s && x.index == i && x.targetLanguage == t && (best == null || !x.createdAt.isBefore(best.createdAt))) best = x;
      }
      return best;
    }

    void check() {
      for (final song in c.songs) {
        final slowLines = c.lines.where((l) => l.songID == song.id).toList()..sort((a, b) => a.index.compareTo(b.index));
        expect(c.linesFor(song.id).map((l) => l.index), slowLines.map((l) => l.index));
        for (final l in slowLines) {
          for (final target in ['ko', 'en']) {
            expect(identical(c.translation(song.id, l.index, target), slowTranslation(song.id, l.index, target)), isTrue);
          }
          expect(c.isSaved(song.id, l.index), c.phrases.any((p) => p.songID == song.id && p.index == l.index));
          expect(identical(c.line(song.id, l.index), l), isTrue);
        }
        expect(c.translatedCount(song.id, 'ko'),
            c.translations.where((t) => t.songID == song.id && t.targetLanguage == 'ko' && t.outcome != Outcome.failed).map((t) => t.index).toSet().length);
        expect(identical(c.song(song.id), song), isTrue);
      }
    }

    setUp(() {
      c = CollectionSnapshot();
      for (var s = 0; s < 6; s++) {
        final song = Song(title: 'Song $s', artist: 'A', lyricsType: LyricsType.plain, sourceProvider: 'manual');
        c.addSong(song, LRCParser.parse(List.generate(8, (i) => 'line $s $i').join('\n')));
        for (var i = 0; i < 8; i++) {
          final r = rnd.nextInt(3);
          c.commit(r == 0 ? Translated(i, 't$i') : (r == 1 ? Copied(i) : Failed(i, 'x')), songID: song.id, target: 'ko', engineID: 'e');
          if (rnd.nextBool()) c.toggleSaved(song.id, i);
        }
      }
    });

    test('after building', check);

    test('after commits, toggles, deletes and direct list edits', () {
      final s0 = c.songs.first.id;
      c.commit(const Translated(2, 'newer'), songID: s0, target: 'ko', engineID: 'e2');
      expect(c.translationText(s0, 2, 'ko'), 'newer');
      c.toggleSaved(s0, 3);
      c.deleteSong(c.songs[1].id, keepPhrases: false);
      c.translations.removeWhere((t) => t.songID == s0 && t.index == 2); // direct edit, no touch()
      check();
    });
  });

  test('song language: scripts and common words', () {
    expect(LanguageGuess.songLanguage(_ko), 'ko');
    expect(LanguageGuess.songLanguage(_en), 'en');
    expect(LanguageGuess.songLanguage(_ja), 'ja');
    expect(LanguageGuess.songLanguage(_zh), 'zh');
    expect(LanguageGuess.songLanguage(_de), 'de');
    expect(LanguageGuess.songLanguage(_fr), 'fr');
    expect(LanguageGuess.songLanguage([..._ko.take(2), ..._en.take(3)]), isNull); // mixed: translate
    expect(LanguageGuess.songLanguage(['Oh']), isNull);
  });

  group('app model', () {
    late AppModel model;
    late Song song;
    late List<MethodCall> remoteCalls;
    late StreamController<Object?> spotifyState;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = MethodChannel('vynilo/spotify_remote');
    const events = EventChannel('vynilo/spotify_remote/state');

    setUp(() async {
      // The Spotify app (App Remote) is simulated through its platform channels.
      SpotifyRemote.debugSupported = true;
      AppModel.debugConnectRemote = () async {};
      remoteCalls = [];
      spotifyState = StreamController<Object?>.broadcast();
      messenger.setMockMethodCallHandler(methods, (call) async {
        remoteCalls.add(call);
        return null;
      });
      messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, sink) => spotifyState.stream.listen(sink.success)));
      song = Song(id: 'song-a', title: 'Morning', artist: 'Team', duration: 120, lyricsType: LyricsType.synced, sourceProvider: 'manual', status: SongStatus.done);
      // Track ids already known, so no Spotify search (Web API) is needed.
      SharedPreferences.setMockInitialValues({'spotify.trackIDs.v1': '{"song-a":"trackA","song-b":"trackB"}'});
      final snap = CollectionSnapshot();
      snap.addSong(song, LRCParser.parse('[00:05.00]오늘은 천천히 걸어가도 괜찮아\n[00:10.00]창문 너머로 햇살이 내려와\n[00:15.00]우리의 노래가 다시 시작돼\n[00:20.00]조용한 거리에 너의 목소리\n[00:25.00]내일도 여기서 만나자'));
      model = AppModel.test(collection: snap, settings: AppSettings()..hasOnboarded = true, prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
    });

    tearDown(() {
      model.source?.dispose();
      spotifyState.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockStreamHandler(events, null);
      SpotifyRemote.debugSupported = null;
      AppModel.debugConnectRemote = null;
    });

    test('a seek moves the position at once, before the music app reports back', () async {
      expect(model.positionOf(song), isNull);
      model.seekSong(song, 42);
      expect(model.positionOf(song), closeTo(42, 0.3));
      expect(model.isPlayingSong(song), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(remoteCalls.last.arguments, {'uri': 'spotify:track:trackA', 'positionMs': 42000});
      model.togglePlaySong(song); // pause
      expect(model.isPlayingSong(song), isFalse);
      final paused = model.positionOf(song)!;
      expect(model.positionOf(song), closeTo(paused, 0.01));
    });

    test('playing another song switches at once and plays it through the Spotify app', () async {
      final other = Song(id: 'song-b', title: 'Evening', artist: 'Team', duration: 90, lyricsType: LyricsType.plain, sourceProvider: 'manual', status: SongStatus.done);
      model.collection.addSong(other, LRCParser.parse('Evening light is falling down\nWe walk back home tonight'));
      model.togglePlaySong(song);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      spotifyState.add({'title': 'Morning', 'artist': 'Team', 'durationMs': 120000, 'uri': 'spotify:track:trackA', 'positionMs': 1000, 'paused': false});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(model.nowPlayingSong?.id, song.id);
      model.togglePlaySong(other); // a different song while the first one plays
      expect(model.nowPlayingSong?.id, other.id);
      expect(model.isPlayingSong(other), isTrue);
      expect(model.isPlayingSong(song), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(remoteCalls.where((c) => c.method == 'play').map((c) => c.arguments['uri']), ['spotify:track:trackA', 'spotify:track:trackB']);
    });

    test('without the Spotify app, play explains why instead of faking playback', () async {
      AppModel.debugConnectRemote = () async => throw const SpotifyRemoteException('CouldNotFindSpotifyApp');
      await model.playSong(song);
      expect(model.isPlayingSong(song), isFalse);
      expect(model.banner?.message, contains('Spotify'));
      expect(remoteCalls, isEmpty);
    });

    test('lyrics already in the target language are not translated', () {
      model.startTranslation(song.id); // target defaults to Korean
      expect(model.isTranslating(song.id), isFalse);
      expect(model.translationSkipped(song.id), isTrue);
      expect(model.collection.song(song.id)!.status, SongStatus.done);
      expect(model.collection.translatedCount(song.id, 'ko'), 5);
      model.retranslate(song.id); // an explicit retranslation still runs
      expect(model.translationSkipped(song.id), isFalse);
    });
  });
}
