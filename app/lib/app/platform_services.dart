import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/llm.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'i18n.dart';

// ─────────────────────────────── Secure store (LOS-10) ───────────────────────────────

enum SecretKey {
  claudeAPIKey('api.claude'),
  geminiAPIKey('api.gemini'),
  vyniloAPIKey('api.vynilo'),
  gatewayAPIKey('api.gateway'),
  spotifyRefreshToken('spotify.refresh'),
  spotifyScope('spotify.scope');

  final String raw;
  const SecretKey(this.raw);

  static SecretKey? apiKeyFor(EngineKind e) => switch (e) {
        EngineKind.onDevice => null,
        EngineKind.vynilo => SecretKey.vyniloAPIKey,
        EngineKind.gateway => SecretKey.gatewayAPIKey,
        EngineKind.claude => SecretKey.claudeAPIKey,
        EngineKind.gemini => SecretKey.geminiAPIKey,
      };
}

/// Keychain on iOS, Android Keystore-backed encrypted storage on Android.
/// Values are mirrored in memory so the UI can read them synchronously.
class SecureStore {
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final _cache = <SecretKey, String>{};

  Future<void> load() async {
    for (final k in SecretKey.values) {
      try {
        final v = await _storage.read(key: k.raw);
        if (v != null) _cache[k] = v;
      } catch (_) {}
    }
  }

  String? value(SecretKey k) => _cache[k];

  Future<void> set(String value, SecretKey k) async {
    await _storage.write(key: k.raw, value: value);
    _cache[k] = value;
  }

  Future<void> delete(SecretKey k) async {
    _cache.remove(k);
    try {
      await _storage.delete(key: k.raw);
    } catch (_) {}
  }

  /// "Delete all" removes every secret explicitly — Keychain items can survive an uninstall (PR-10).
  Future<void> deleteAll() async {
    for (final k in SecretKey.values) {
      await delete(k);
    }
  }
}

/// Masks a key for display after saving (RQ-14): "sk-ant-…a1b2".
String maskSecret(String s) => s.length <= 8 ? '•' * s.length : '${s.substring(0, 6)}…${s.substring(s.length - 4)}';

// ─────────────────────────────── Engines (Win-AGRE-4) ───────────────────────────────

/// Downloads, verifies, and deletes the GGUF model (PR-9): Gemma 4 E2B, QAT q4_0 (3.35 GB).
/// The download resumes from a `.part` file, and the size is checked before it counts as installed.
class ModelManager {
  static const modelName = 'gemma-4-e2b';
  static const fileName = 'gemma-4-E2B_q4_0-it.gguf';
  static const approximateBytes = 3349516256;
  static final url = Uri.parse('https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/$fileName');
  static late Directory baseDir;

  static File get modelFile => File('${baseDir.path}/Models/$fileName');
  static File get _partFile => File('${modelFile.path}.part');
  static bool get isInstalled => modelFile.existsSync() && modelFile.lengthSync() == approximateBytes;
  static int get modelBytes => isInstalled ? modelFile.lengthSync() : 0;

  /// llama.cpp is built into the Android app (arm64). iOS falls back to the demo engine for now.
  static bool get isSupported => Platform.isAndroid;

  static bool _cancel = false;
  static void cancelDownload() => _cancel = true;

  static Future<void> download(void Function(double) progress) async {
    _cancel = false;
    modelFile.parent.createSync(recursive: true);
    final client = http.Client();
    try {
      final have = _partFile.existsSync() ? _partFile.lengthSync() : 0;
      final req = http.Request('GET', url);
      if (have > 0) req.headers['range'] = 'bytes=$have-';
      final res = await client.send(req);
      if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('HTTP ${res.statusCode}');
      final resumed = res.statusCode == 206;
      final sink = _partFile.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var got = resumed ? have : 0;
      try {
        await for (final chunk in res.stream) {
          if (_cancel) throw const CancelledException();
          sink.add(chunk);
          got += chunk.length;
          progress(got / approximateBytes);
        }
      } finally {
        await sink.close();
      }
      if (_partFile.lengthSync() != approximateBytes) throw const FileSystemException('size mismatch');
      _partFile.renameSync(modelFile.path);
    } finally {
      client.close();
    }
  }

  static void deleteModel() {
    LocalLlama.unload();
    for (final f in [modelFile, _partFile]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
}

/// Platform channel to llama.cpp (android/app/src/main/cpp/vynilo_llm.cpp).
class LocalLlama {
  static const _channel = MethodChannel('vynilo/llama');

  static Future<String> complete(String prompt, int maxTokens) async {
    try {
      final out = await _channel.invokeMethod<String>(
          'complete', {'path': ModelManager.modelFile.path, 'prompt': prompt, 'maxTokens': maxTokens, 'nCtx': 4096});
      return out ?? '';
    } on PlatformException catch (e) {
      throw LLMError(LLMErrorKind.unavailable,
          detail: e.code == 'too_long' ? tr('가사가 길어 온디바이스 모델이 한 번에 처리하지 못했어요.') : tr('온디바이스 모델을 실행하지 못했어요: {0}', [e.message]));
    } on MissingPluginException {
      throw LLMError(LLMErrorKind.unavailable, detail: tr('이 기기에서는 온디바이스 모델을 아직 쓸 수 없어요.'));
    }
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  static Future<void> unload() async {
    try {
      await _channel.invokeMethod('unload');
    } catch (_) {}
  }
}

/// Non-secret engine settings handed to the factory (server URL, gateway URL, chosen models).
class EngineConfig {
  final String vyniloURL;
  final String vyniloModel;
  final String gatewayURL;
  final String gatewayModel;
  final String claudeModel;
  const EngineConfig({
    this.vyniloURL = VyniloServerEngine.defaultURL,
    this.vyniloModel = '',
    this.gatewayURL = '',
    this.gatewayModel = '',
    this.claudeModel = ClaudeEngine.defaultModel,
  });
}

class EngineFactory {
  static TranslationEngine make(EngineKind kind, String? apiKey, [EngineConfig config = const EngineConfig()]) => switch (kind) {
        EngineKind.claude => ClaudeEngine(apiKey ?? '', model: config.claudeModel),
        EngineKind.gemini => GeminiEngine(apiKey ?? ''),
        EngineKind.vynilo =>
          VyniloServerEngine(config.vyniloURL, apiKey ?? '', model: config.vyniloModel.isEmpty ? null : config.vyniloModel),
        EngineKind.gateway => GatewayEngine(config.gatewayURL, apiKey ?? '', config.gatewayModel),
        // Without the downloaded model there is no on-device engine; nothing is faked.
        EngineKind.onDevice => ModelManager.isSupported && ModelManager.isInstalled
            ? LocalLlamaEngine(LocalLlama.complete, modelName: ModelManager.modelName)
            : const UnavailableEngine(EngineKind.onDevice, '온디바이스 모델을 먼저 내려받아 주세요. 마이페이지 → 번역 엔진에서 받을 수 있어요.'),
      };

  /// The engine currently answering for a choice, for the badge (SIR-3).
  static String label(EngineKind kind) {
    if (kind != EngineKind.onDevice) return kind.badgeLabel;
    return ModelManager.isSupported && ModelManager.isInstalled ? 'On-device · Gemma 4' : 'On-device · 모델 필요';
  }
}

// ─────────────────────────────── Links (OAuth redirects) ───────────────────────────────

/// Opens URLs in the browser and receives `vynilo://…` redirects from the Android activity.
class Links {
  static const _channel = MethodChannel('vynilo/links');
  static final _controller = StreamController<Uri>.broadcast();
  static bool _ready = false;

  static Stream<Uri> get stream {
    if (!_ready) {
      _ready = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'link') _controller.add(Uri.parse(call.arguments as String));
      });
      _channel.invokeMethod<String>('initialLink').then((v) {
        if (v != null) _controller.add(Uri.parse(v));
      }, onError: (_) {});
    }
    return _controller.stream;
  }

  static Future<void> open(Uri url) => _channel.invokeMethod('open', {'url': url.toString()});
}

// ─────────────────────────────── Spotify (SIR-5) ───────────────────────────────

/// Spotify Web API with Authorization Code + PKCE: no client secret on the device.
/// The client ID is passed at build time: `--dart-define=SPOTIFY_CLIENT_ID=…`.
class SpotifyAuth {
  static const clientID = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const redirect = 'vynilo://spotify-callback';
  /// Playback plus library reads (playlists, saved albums, liked songs) for the Spotify browser.
  static const scopes = 'user-read-currently-playing user-read-playback-state user-modify-playback-state '
      'playlist-read-private playlist-read-collaborative user-library-read';

  final SecureStore store;
  final http.Client client;
  String? _verifier;
  String? _state;
  String? _access;
  DateTime _expiry = DateTime(0);

  SpotifyAuth(this.store, {http.Client? client}) : client = client ?? http.Client();

  bool get isConfigured => clientID.isNotEmpty;
  bool get hasToken => (store.value(SecretKey.spotifyRefreshToken) ?? '').isNotEmpty;

  /// False for logins made before the library scopes were added (0.3.1 and older); those must
  /// log in again before playlists and albums can be read.
  bool get hasLibraryScopes {
    final granted = (store.value(SecretKey.spotifyScope) ?? '').split(' ');
    return granted.contains('playlist-read-private') && granted.contains('user-library-read');
  }

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  Future<void> startLogin() async {
    final rnd = Random.secure();
    _verifier = _b64(List.generate(64, (_) => rnd.nextInt(256)));
    _state = _b64(List.generate(16, (_) => rnd.nextInt(256)));
    final challenge = _b64(sha256.convert(ascii.encode(_verifier!)).bytes);
    await Links.open(Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': clientID,
      'response_type': 'code',
      'redirect_uri': redirect,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'state': _state,
      'scope': scopes,
    }));
  }

  /// Handles `vynilo://spotify-callback?code=…&state=…`. Returns false if it is not a Spotify redirect.
  Future<bool> finishLogin(Uri uri) async {
    if (uri.scheme != 'vynilo' || uri.host != 'spotify-callback') return false;
    final err = uri.queryParameters['error'];
    if (err != null) throw SpotifyException(tr('Spotify 로그인이 취소됐어요 ({0}).', [err]));
    if (uri.queryParameters['state'] != _state || _verifier == null) throw SpotifyException(tr('Spotify 로그인을 다시 시도해 주세요.'));
    await _token({
      'grant_type': 'authorization_code',
      'code': uri.queryParameters['code'] ?? '',
      'redirect_uri': redirect,
      'client_id': clientID,
      'code_verifier': _verifier!,
    });
    return true;
  }

  Future<void> _token(Map<String, String> form) async {
    final r = await client.post(Uri.parse('https://accounts.spotify.com/api/token'), body: form).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw SpotifyException(tr('Spotify 인증에 실패했어요 ({0}).', [r.statusCode]));
    final j = jsonDecode(r.body) as Map;
    _access = j['access_token'] as String;
    _expiry = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 60));
    final refresh = j['refresh_token'] as String?;
    if (refresh != null) await store.set(refresh, SecretKey.spotifyRefreshToken);
    final scope = j['scope'] as String?;
    if (scope != null) await store.set(scope, SecretKey.spotifyScope);
  }

  Future<String> accessToken() async {
    if (_access == null || DateTime.now().isAfter(_expiry)) {
      final refresh = store.value(SecretKey.spotifyRefreshToken);
      if (refresh == null || refresh.isEmpty) throw SpotifyException(tr('Spotify가 연결되어 있지 않아요.'));
      await _token({'grant_type': 'refresh_token', 'refresh_token': refresh, 'client_id': clientID});
    }
    return _access!;
  }

  /// Lets tests skip the OAuth round-trip.
  void debugSetAccessToken(String token) {
    _access = token;
    _expiry = DateTime.now().add(const Duration(hours: 1));
  }

  Future<void> logout() async {
    _access = null;
    await store.delete(SecretKey.spotifyRefreshToken);
    await store.delete(SecretKey.spotifyScope);
  }
}

class SpotifyException implements Exception {
  final String message;
  SpotifyException(this.message);
  @override
  String toString() => message;
}

// ─────────────────────────────── Spotify App Remote (Android) ───────────────────────────────

/// Spotify App Remote SDK through the Android bridge (SpotifyRemoteBridge.kt). It plays through the
/// installed Spotify app in the background — the Spotify app is never brought to the front — and
/// pushes player state the moment it changes. Library reads and search still use the Web API.
class SpotifyRemote {
  static const _channel = MethodChannel('vynilo/spotify_remote');
  static const _events = EventChannel('vynilo/spotify_remote/state');

  /// Tests set this to run the Android path on the desktop.
  static bool? debugSupported;
  static bool get supported => debugSupported ?? Platform.isAndroid;

  static Future<bool> installed() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('installed') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Connects to the Spotify app. The first time, Spotify asks the user to approve the app.
  /// Throws [SpotifyRemoteException] with Spotify's reason when it cannot connect.
  static Future<void> connect() async {
    try {
      await _channel.invokeMethod('connect', {'clientId': SpotifyAuth.clientID, 'redirectUri': SpotifyAuth.redirect});
    } on PlatformException catch (e) {
      throw SpotifyRemoteException(e.code, e.message);
    }
  }

  static Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (_) {}
  }

  static Future<void> call(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      throw SpotifyRemoteException(e.code, e.message);
    }
  }

  static Stream<Object?> get events => _events.receiveBroadcastStream();
}

class SpotifyRemoteException implements Exception {
  final String code;
  final String? detail;
  const SpotifyRemoteException(this.code, [this.detail]);

  /// What to tell the user, by the SDK's exception name.
  String get userMessage => switch (code) {
        'CouldNotFindSpotifyApp' => tr('Spotify 앱이 설치되어 있지 않아요.'),
        'NotLoggedInException' => tr('Spotify 앱에 로그인해 주세요.'),
        'UserNotAuthorizedException' || 'AuthenticationFailedException' =>
          tr('Spotify가 이 앱을 아직 허용하지 않았어요. 대시보드에 패키지 이름과 SHA-1을 등록했는지 확인해 주세요.'),
        'UnsupportedFeatureVersionException' => tr('Spotify 앱을 최신 버전으로 업데이트해 주세요.'),
        'OfflineModeException' => tr('Spotify가 오프라인 모드예요.'),
        _ => tr('Spotify 앱과 연결하지 못했어요 ({0}).', [code]),
      };

  @override
  String toString() => userMessage;
}

/// Now-playing and playback through the Spotify app (App Remote). No polling: Spotify pushes a state
/// on every play, pause, seek and track change, and the sync engine extrapolates in between.
class SpotifyRemoteSource implements NowPlayingSource {
  final void Function(String message) onError;

  /// Called when the Spotify app drops the connection (closed, logged out); the model falls back.
  final void Function()? onDisconnected;
  final _controller = StreamController<PlaybackSnapshot>.broadcast();
  StreamSubscription<Object?>? _sub;
  PlaybackSnapshot? _last;

  SpotifyRemoteSource({required this.onError, this.onDisconnected}) {
    _sub = SpotifyRemote.events.listen((e) {
      if (e is! Map) return;
      if (e['disconnected'] == true) {
        onDisconnected?.call();
        return;
      }
      if (e['isEpisode'] == true) return;
      final uri = '${e['uri'] ?? ''}';
      final snap = PlaybackSnapshot(
        track: TrackKey(
          title: '${e['title'] ?? ''}',
          artist: '${e['artist'] ?? ''}',
          album: e['album'] as String?,
          duration: ((e['durationMs'] as num?) ?? 0) / 1000,
        ),
        position: ((e['positionMs'] as num?) ?? 0) / 1000,
        isPlaying: e['paused'] != true,
        rate: (e['speed'] as num?)?.toDouble() == 0 ? 1 : ((e['speed'] as num?)?.toDouble() ?? 1),
        trackID: uri.startsWith('spotify:track:') ? uri.split(':').last : null,
      );
      _last = snap;
      if (!_controller.isClosed) _controller.add(snap);
    }, onError: (_) {});
  }

  @override
  SourceID get id => SourceID.spotify;
  @override
  Set<SourceCapability> get capabilities => SourceCapability.values.toSet();

  @override
  Stream<PlaybackSnapshot> get snapshots async* {
    if (_last != null) yield _last!;
    yield* _controller.stream;
  }

  Future<void> _do(String method, [Map<String, Object?>? args]) async {
    try {
      await SpotifyRemote.call(method, args);
    } on SpotifyRemoteException catch (e) {
      onError(e.code.contains('Restriction') || (e.detail ?? '').contains('PREMIUM') ? SourceError.premiumRequired.userMessage : e.userMessage);
    }
  }

  /// Starts a track at [position] seconds. Returns a message when Spotify refuses.
  Future<String?> playTrack(String uri, {double position = 0}) async {
    try {
      await SpotifyRemote.call('play', {'uri': uri, 'positionMs': (position * 1000).round()});
      return null;
    } on SpotifyRemoteException catch (e) {
      return (e.detail ?? '').toUpperCase().contains('PREMIUM') ? SourceError.premiumRequired.userMessage : e.userMessage;
    }
  }

  @override
  Future<void> play() => _do('resume');
  @override
  Future<void> pause() => _do('pause');
  @override
  Future<void> next() => _do('next');
  @override
  Future<void> previous() => _do('previous');
  @override
  Future<void> seek(double position) => _do('seek', {'positionMs': (position * 1000).round()});

  @override
  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}

// ─────────────────────────────── Covers (RQ-6) ───────────────────────────────

class CoverStore {
  static late Directory dir;

  /// Copies the picked (already downscaled to ≤1024 px) image into app storage.
  static String? save(String sourcePath, String songID) {
    try {
      dir.createSync(recursive: true);
      final name = '$songID.jpg';
      File(sourcePath).copySync('${dir.path}/$name');
      return name;
    } catch (_) {
      return null;
    }
  }

  /// Writes a generated cover. The name changes each time so cached images are not reused.
  static String? saveBytes(Uint8List bytes, String songID, {String ext = 'png'}) {
    try {
      dir.createSync(recursive: true);
      final name = '$songID-${DateTime.now().millisecondsSinceEpoch}.$ext';
      File('${dir.path}/$name').writeAsBytesSync(bytes);
      return name;
    } catch (_) {
      return null;
    }
  }

  static File file(String path) => File('${dir.path}/$path');

  static void delete(String path) {
    try {
      file(path).deleteSync();
    } catch (_) {}
  }
}

// ─────────────────────────────── Storage meter / haptics ───────────────────────────────

class StorageMeter {
  static int bytes(Directory d) {
    var total = 0;
    if (!d.existsSync()) return 0;
    for (final f in d.listSync(recursive: true)) {
      if (f is File) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }

  static String format(int bytes) {
    if (bytes < 1000) return '$bytes bytes';
    const units = ['KB', 'MB', 'GB'];
    var v = bytes / 1000;
    var u = 0;
    while (v >= 1000 && u < units.length - 1) {
      v /= 1000;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
  }
}

// ─────────────────────────────── Quiz progress ───────────────────────────────

/// Quiz levels passed per song and the days a quiz was played. Kept in SharedPreferences, outside
/// the collection file, so the export format shared with iOS does not change.
class QuizProgress {
  final SharedPreferences prefs;
  static const _levelsKey = 'quiz.levels.v1', _daysKey = 'quiz.days.v1';
  QuizProgress(this.prefs);

  Map<String, int> get _levels {
    try {
      return Map<String, int>.from(jsonDecode(prefs.getString(_levelsKey) ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  int level(String songID) => _levels[songID] ?? 0;

  void pass(String songID, int level) {
    final m = _levels;
    if ((m[songID] ?? 0) >= level) return;
    m[songID] = level;
    prefs.setString(_levelsKey, jsonEncode(m));
  }

  void forget(String songID) {
    final m = _levels..remove(songID);
    prefs.setString(_levelsKey, jsonEncode(m));
  }

  /// Days with at least one finished quiz, as yyyy-mm-dd.
  Set<String> get days => (prefs.getStringList(_daysKey) ?? const []).toSet();

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void markToday() => prefs.setStringList(_daysKey, (days..add(dayKey(DateTime.now()))).toList()..sort());

  /// Consecutive days up to today (or yesterday, so the streak survives until the day ends).
  int get streak {
    final d = days;
    var day = DateTime.now();
    if (!d.contains(dayKey(day))) day = day.subtract(const Duration(days: 1));
    var n = 0;
    while (d.contains(dayKey(day))) {
      n++;
      day = day.subtract(const Duration(days: 1));
    }
    return n;
  }

  void clear() {
    prefs.remove(_levelsKey);
    prefs.remove(_daysKey);
  }
}

class Haptics {
  static void light() => HapticFeedback.lightImpact();
  static void success() => HapticFeedback.mediumImpact();
}
