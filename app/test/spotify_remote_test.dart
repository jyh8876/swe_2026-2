import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/platform_services.dart';
import 'package:lyrics_translator/core/playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vynilo/spotify_remote');
  const events = EventChannel('vynilo/spotify_remote/state');

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('player states pushed by the Spotify app become snapshots', () async {
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, sink) {
      sink.success({'title': 'Shallow', 'artist': 'Lady Gaga, Bradley Cooper', 'album': 'A Star Is Born', 'durationMs': 215733, 'uri': 'spotify:track:2Vxe', 'positionMs': 20500, 'paused': false, 'speed': 1.0, 'isEpisode': false});
      sink.success({'title': 'Podcast', 'artist': 'x', 'durationMs': 1000, 'uri': 'spotify:episode:1', 'positionMs': 0, 'paused': false, 'isEpisode': true});
      sink.success({'title': 'Shallow', 'artist': 'Lady Gaga, Bradley Cooper', 'durationMs': 215733, 'uri': 'spotify:track:2Vxe', 'positionMs': 30000, 'paused': true, 'speed': 0.0, 'isEpisode': false});
    }));
    final source = SpotifyRemoteSource(onError: (_) {});
    final snaps = await source.snapshots.take(2).toList();
    expect(snaps.first.track.title, 'Shallow');
    expect(snaps.first.track.duration, closeTo(215.733, 0.001));
    expect(snaps.first.position, 20.5);
    expect(snaps.first.isPlaying, isTrue);
    expect(snaps.first.trackID, '2Vxe');
    expect(snaps.last.isPlaying, isFalse); // the episode was skipped
    expect(snaps.last.rate, 1); // a paused speed of 0 does not freeze the sync engine
    source.dispose();
  });

  test('play sends the track and start position; refusals become messages', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'play' && call.arguments['uri'] == 'spotify:track:bad') {
        throw PlatformException(code: 'SpotifyRemoteServiceException', message: 'PREMIUM_REQUIRED');
      }
      return null;
    });
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, _) {}));
    final source = SpotifyRemoteSource(onError: (_) {});
    expect(await source.playTrack('spotify:track:ok', position: 12.5), isNull);
    expect(calls.single.arguments, {'uri': 'spotify:track:ok', 'positionMs': 12500});
    expect(await source.playTrack('spotify:track:bad'), SourceError.premiumRequired.userMessage);
    await source.seek(3);
    expect(calls.last.method, 'seek');
    expect(calls.last.arguments, {'positionMs': 3000});
    source.dispose();
  });

  test('connection failures explain the cause', () {
    expect(const SpotifyRemoteException('UserNotAuthorizedException').userMessage, contains('SHA-1'));
    expect(const SpotifyRemoteException('CouldNotFindSpotifyApp').userMessage, contains('설치'));
  });
}
