import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/collection.dart';
import '../core/llm.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/playback.dart';
import '../core/quiz.dart';
import '../core/recommend.dart';
import 'google_auth.dart';
import 'i18n.dart';
import 'platform_services.dart';
import 'spotify_library.dart';
import 'web_artwork.dart';
import 'theme.dart';

/// Navigation inside the Library tab (SSRD 4.1.2: the add flow is linear,
/// Search → Add → Translating → Saved; the player is reached from an LP card).
sealed class Route {
  const Route();
}

class SearchRoute extends Route {
  final String prefill;

  /// The exact track when known (recommendations, now playing): fills in the title and artist
  /// for the web lyrics search and the add screen.
  final TrackKey? hint;
  const SearchRoute([this.prefill = '', this.hint]);
}

class AddRoute extends Route {
  final AddSongDraft draft;
  const AddRoute(this.draft);
}

/// Cover choice for a song being added (Figma 커버 이미지 선택, GitHub cover-select-prototype).
class CoverSelectRoute extends Route {
  final AddSongDraft draft;
  const CoverSelectRoute(this.draft);
}

class TranslatingRoute extends Route {
  final String songID;
  const TranslatingRoute(this.songID);
}

class SavedRoute extends Route {
  final String songID;
  const SavedRoute(this.songID);
}

class PlayerRoute extends Route {
  final String songID;
  const PlayerRoute(this.songID);
}

/// Tracks of a Spotify playlist, saved album or the liked songs.
class SpotifyListRoute extends Route {
  final SpotifyList list;
  const SpotifyListRoute(this.list);
}

/// Pre-filled data for FG-03.
class AddSongDraft {
  String title = '';
  String artist = '';
  String? album;
  double? duration;
  String lyrics = '';
  String sourceProvider = 'manual';
  String? curatedShelfID;

  /// Album art from Spotify, downloaded by the add screen as the cover.
  String? coverURL;

  /// The Spotify track this song came from, so playback links to it exactly.
  String? spotifyTrackID;

  /// Translation language chosen on the add screen; null follows the app setting.
  String? targetLanguage;

  AddSongDraft();

  AddSongDraft.fromCandidate(LyricsCandidate c, {String? shelfID}) {
    title = c.trackName;
    artist = TrackNormalizer.primaryArtist(c.artistName);
    album = c.albumName;
    duration = c.duration;
    lyrics = c.bestLyricsText ?? '';
    sourceProvider = c.id < 0 ? 'demo' : 'manual';
    curatedShelfID = shelfID;
  }
}

/// User preferences (FG-09). Stored in SharedPreferences; secrets live in the SecureStore.
class AppSettings {
  bool hasOnboarded = false;
  EngineKind engine = EngineKind.onDevice;
  String targetLanguage = Language.korean.code;

  /// App interface language: ko, en, zh or ja.
  String uiLanguage = Language.korean.code;
  bool showTranslation = true;

  /// 독음 above each original line, when the translation has one.
  bool showReading = true;

  /// One-time notice before the first cloud translation (SIR-3).
  bool cloudNoticeAccepted = false;
  Set<SourceID> connectedSources = {};

  /// Google account chosen on sign-in (profile only; null when signed out).
  GoogleAccountInfo? googleAccount;

  // Engine settings that are not secrets (keys live in the SecureStore).
  String vyniloURL = VyniloServerEngine.defaultURL;
  String vyniloModel = '';
  String gatewayURL = '';
  String gatewayModel = '';
  String claudeModel = ClaudeEngine.defaultModel;

  // Look (My page → 테마). Figma dark grey by default.
  ThemeBase themeBase = ThemeBase.light;
  AccentColor accent = AccentColor.mint;

  EngineConfig get engineConfig => EngineConfig(
      vyniloURL: vyniloURL, vyniloModel: vyniloModel, gatewayURL: gatewayURL, gatewayModel: gatewayModel, claudeModel: claudeModel);

  static const key = 'app.settings.v1';

  Language get target => Language.named(targetLanguage);

  Map<String, dynamic> toJson() => {
        'hasOnboarded': hasOnboarded,
        'engine': engine.name,
        'targetLanguage': targetLanguage,
        'uiLanguage': uiLanguage,
        'showTranslation': showTranslation,
        'showReading': showReading,
        'cloudNoticeAccepted': cloudNoticeAccepted,
        'connectedSources': connectedSources.map((s) => s.name).toList(),
        'googleAccount': googleAccount?.toJson(),
        'vyniloURL': vyniloURL,
        'vyniloModel': vyniloModel,
        'gatewayURL': gatewayURL,
        'gatewayModel': gatewayModel,
        'claudeModel': claudeModel,
        'themeBase': themeBase.name,
        'accent': accent.name,
      };

  static AppSettings fromJson(Map j) {
    final s = AppSettings();
    s.hasOnboarded = j['hasOnboarded'] == true;
    s.engine = EngineKind.values.firstWhere((e) => e.name == j['engine'], orElse: () => EngineKind.onDevice);
    s.targetLanguage = j['targetLanguage'] as String? ?? Language.korean.code;
    s.uiLanguage = j['uiLanguage'] as String? ?? Language.korean.code;
    s.showTranslation = j['showTranslation'] != false;
    s.showReading = j['showReading'] != false;
    s.cloudNoticeAccepted = j['cloudNoticeAccepted'] == true;
    s.connectedSources = ((j['connectedSources'] as List?) ?? const [])
        .map((n) => SourceID.values.where((s) => s.name == n).firstOrNull)
        .whereType<SourceID>()
        .toSet();
    s.googleAccount = GoogleAccountInfo.fromJson(j['googleAccount']);
    s.vyniloURL = j['vyniloURL'] as String? ?? VyniloServerEngine.defaultURL;
    s.vyniloModel = j['vyniloModel'] as String? ?? '';
    s.gatewayURL = j['gatewayURL'] as String? ?? '';
    s.gatewayModel = j['gatewayModel'] as String? ?? '';
    s.claudeModel = j['claudeModel'] as String? ?? ClaudeEngine.defaultModel;
    s.themeBase = ThemeBase.values.firstWhere((e) => e.name == j['themeBase'], orElse: () => ThemeBase.light);
    s.accent = AccentColor.values.firstWhere((e) => e.name == j['accent'], orElse: () => AccentColor.mint);
    return s;
  }
}

/// Bottom tabs (Notion "홈화면 하단 바"): library, quiz, saved phrases, my page.
enum AppTab { library, quiz, phrases, my }

class AppBanner {
  final String message;
  final String? actionTitle;

  /// What the action button does; without it the button opens settings.
  final VoidCallback? onAction;
  AppBanner(this.message, {this.actionTitle, this.onAction});
}

/// App-wide state. Views read from it; all business rules live in lib/core (PR-5).
class AppModel extends ChangeNotifier {
  // ── State ──
  CollectionSnapshot collection;
  AppSettings settings;
  List<Route> libraryPath = [];
  AppTab selectedTab = AppTab.library;
  final Map<String, TranslationProgress> progress = {};
  PlaybackSnapshot? nowPlaying;
  SourceID? activeSourceID;
  AppBanner? banner;
  final List<CuratedShelf> shelves;

  // ── Dependencies ──
  final CollectionRepository repository;
  final SecureStore secureStore;
  final LyricsProvider lyricsProvider;
  final SharedPreferences prefs;
  final Directory baseDir;
  final mastery = const MasteryRules();
  final Map<String, CancelToken> _jobs = {};
  StreamSubscription<PlaybackSnapshot>? _sourceSub;
  StreamSubscription<Uri>? _linkSub;
  /// The source the screens follow and control: whichever reported playing most recently.
  NowPlayingSource? source;

  /// Spotify's App Remote (or a test source), attached explicitly.
  NowPlayingSource? _primary;

  /// Any music app, through Android's media sessions (needs notification access).
  MusicAppSource? _musicApp;
  late final SpotifyAuth spotifyAuth = SpotifyAuth(secureStore);
  late final SpotifyLibrary spotifyLibrary = SpotifyLibrary(spotifyAuth);
  late final WebArtwork webArtwork = WebArtwork();

  AppModel._({
    required this.repository,
    required this.secureStore,
    required this.lyricsProvider,
    required this.prefs,
    required this.settings,
    required this.collection,
    required this.shelves,
    required this.baseDir,
  }) {
    _resumeUnfinishedJobs();
  }

  /// Starts listening for OAuth redirects (Spotify). Not called in widget tests.
  void listenForLinks() {
    _linkSub ??= Links.stream.listen((uri) async {
      try {
        if (openLink(uri)) return;
        if (await spotifyAuth.finishLogin(uri)) {
          updateSettings((st) => st
            ..connectedSources.add(SourceID.spotify)
            ..hasOnboarded = true);
          await attachSpotify(retryRemote: true);
          showBanner(AppBanner(tr('Spotify에 연결됐어요. 플레이리스트와 앨범을 불러올 수 있어요.')));
          fillCovers();
        }
      } catch (e) {
        showBanner(AppBanner('$e'));
      }
    });
  }

  /// In-memory model for widget tests and screenshots.
  @visibleForTesting
  factory AppModel.test({required CollectionSnapshot collection, required AppSettings settings, required SharedPreferences prefs, required Directory baseDir}) {
    ModelManager.baseDir = baseDir;
    CoverStore.dir = Directory('${baseDir.path}/Covers');
    return AppModel._(
      repository: InMemoryRepository(collection),
      secureStore: SecureStore(),
      lyricsProvider: StaticLyricsProvider(DemoContent.candidates),
      prefs: prefs,
      settings: settings,
      collection: collection,
      shelves: const [],
      baseDir: baseDir,
    );
  }

  static Future<AppModel> create() async {
    final support = await getApplicationSupportDirectory();
    final base = Directory('${support.path}/LyricsTranslator');
    ModelManager.baseDir = base;
    CoverStore.dir = Directory('${base.path}/Covers');
    final repo = JSONFileRepository(File('${base.path}/collection.json'));
    final prefs = await SharedPreferences.getInstance();
    AppSettings settings;
    try {
      settings = AppSettings.fromJson(jsonDecode(prefs.getString(AppSettings.key) ?? '{}') as Map);
    } catch (_) {
      settings = AppSettings();
    }
    final secure = SecureStore();
    await secure.load();
    CollectionSnapshot snap;
    try {
      snap = repo.load();
    } catch (_) {
      snap = CollectionSnapshot();
    }
    final shelves = CuratedShelf.parseFile(await rootBundle.loadString('assets/curated_shelves.json'));
    return AppModel._(
      repository: repo,
      secureStore: secure,
      // No lyrics server: users find lyrics with a web search (".lrc") and paste them.
      // The bundled demo song is left out of the shipped app.
      lyricsProvider: const StaticLyricsProvider([]),
      prefs: prefs,
      settings: settings,
      collection: snap,
      shelves: shelves,
      baseDir: base,
    )
      ..listenForLinks()
      ..refreshSourceConnection()
      ..fillCovers();
  }

  // ── Persistence ──

  Timer? _saveTimer;
  DateTime? _dirtySince;

  /// Applies a change, then saves shortly after. Translation commits arrive line by line, and
  /// re-encoding the whole collection for each one stalled the UI, so writes are batched: at most
  /// 0.4 s after the last change and never more than 1.5 s after the first unsaved one. Pending
  /// changes are flushed when the app goes to the background.
  void _mutate(void Function(CollectionSnapshot) change) {
    change(collection);
    collection.touch();
    _dirtySince ??= DateTime.now();
    _saveTimer?.cancel();
    final waited = DateTime.now().difference(_dirtySince!);
    _saveTimer = Timer(waited >= const Duration(milliseconds: 1500) ? Duration.zero : const Duration(milliseconds: 400), flushSave);
    notifyListeners();
  }

  /// Writes pending changes now.
  void flushSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_dirtySince == null) return;
    _dirtySince = null;
    try {
      repository.save(collection);
    } catch (_) {
      banner = AppBanner(tr('저장하지 못했어요: 저장 공간을 확인해 주세요.'));
      notifyListeners();
    }
  }

  void updateSettings(void Function(AppSettings) change) {
    change(settings);
    prefs.setString(AppSettings.key, jsonEncode(settings.toJson()));
    notifyListeners();
  }

  // ── Navigation ──

  void push(Route r) {
    libraryPath = [...libraryPath, r];
    notifyListeners();
  }

  void setPath(List<Route> path) {
    libraryPath = path;
    notifyListeners();
  }

  void pop() {
    if (libraryPath.isEmpty) return;
    libraryPath = libraryPath.sublist(0, libraryPath.length - 1);
    notifyListeners();
  }

  void selectTab(AppTab t) {
    selectedTab = t;
    notifyListeners();
  }

  void showBanner(AppBanner? b) {
    banner = b;
    notifyListeners();
  }

  /// Screen links `vynilo://open/<screen>`: `library`, `search` (optional `?q=`), `add`, `quiz`,
  /// `saved` and `my`. Used by Play's pre-launch report and for sharing. Returns false for other
  /// links (such as the Spotify login redirect).
  bool openLink(Uri uri) {
    if (uri.scheme != 'vynilo' || uri.host != 'open') return false;
    banner = null;
    final screen = uri.pathSegments.isEmpty ? 'library' : uri.pathSegments.first;
    switch (screen) {
      case 'search':
        selectedTab = AppTab.library;
        libraryPath = [SearchRoute(uri.queryParameters['q'] ?? '')];
      case 'add':
        selectedTab = AppTab.library;
        libraryPath = [AddRoute(AddSongDraft())];
      case 'quiz':
        selectedTab = AppTab.quiz;
      case 'saved':
        selectedTab = AppTab.phrases;
      case 'my':
        selectedTab = AppTab.my;
      default:
        selectedTab = AppTab.library;
        libraryPath = [];
    }
    notifyListeners();
    return true;
  }

  /// Settings live in the "My page" tab.
  void openSettings() {
    banner = null;
    selectedTab = AppTab.my;
    notifyListeners();
  }

  // ── Engines ──

  Language get target => settings.target;

  /// The language a song is translated into: its own choice from the add screen, else the app's.
  Language targetFor(String songID) {
    final code = collection.song(songID)?.targetLanguage;
    return code == null ? target : Language.named(code);
  }

  AppTheme get theme => AppTheme.of(settings.themeBase, settings.accent);

  String? apiKey(EngineKind kind) {
    final k = SecretKey.apiKeyFor(kind);
    return k == null ? null : secureStore.value(k);
  }

  TranslationEngine currentEngine() => EngineFactory.make(settings.engine, apiKey(settings.engine), settings.engineConfig);

  // ── Add flow (RQ-6, RQ-7) ──

  /// Saves the song and starts pre-translation. Returns the new song id.
  String addSong(AddSongDraft draft, {String? coverSourcePath}) {
    final doc = LRCParser.parse(draft.lyrics);
    final song = Song(
      title: draft.title.trim(),
      artist: draft.artist.trim(),
      album: draft.album,
      duration: draft.duration,
      lyricsType: doc.type,
      sourceProvider: draft.sourceProvider,
      curatedShelfID: draft.curatedShelfID,
      targetLanguage: draft.targetLanguage,
    );
    if (coverSourcePath != null) song.coverPath = CoverStore.save(coverSourcePath, song.id);
    _mutate((s) {
      s.addSong(song, doc);
      // Language identification on the device (RQ-15).
      for (final l in s.lines.where((l) => l.songID == song.id)) {
        l.detectedLanguage = LanguageGuess.detect(l.text);
      }
    });
    startTranslation(song.id);
    if (draft.spotifyTrackID != null) _rememberSpotifyID(song.id, draft.spotifyTrackID!);
    if (song.coverPath == null) fillCovers();
    return song.id;
  }

  /// Engine id recorded for songs left untranslated because they are already in the target language.
  static const sameLanguageEngine = 'same-language';

  /// True when the song was not translated because its lyrics are already in the target language.
  bool translationSkipped(String songID) {
    final first = collection.linesFor(songID).firstOrNull;
    return first != null && collection.translation(songID, first.index, targetFor(songID).code)?.engineID == sameLanguageEngine;
  }

  void startTranslation(String songID, {TranslationEngine? forceEngine, bool skipSameLanguage = true}) {
    if (_jobs.containsKey(songID)) return;
    final engine = forceEngine ?? currentEngine();
    final lines = collection.linesFor(songID);
    final target = targetFor(songID);
    // Lyrics already in the target language are not sent to any engine (no cost, no waiting).
    final untouched = collection.translatedCount(songID, targetFor(songID).code) == 0;
    if (skipSameLanguage && forceEngine == null && untouched && LanguageGuess.songLanguage(lines.map((l) => l.text)) == targetFor(songID).code) {
      _mutate((s) {
        for (final l in lines) {
          s.commit(Copied(l.index), songID: songID, target: targetFor(songID).code, engineID: sameLanguageEngine);
        }
        s.updateSong(songID, (song) => song.status = SongStatus.done);
      });
      showBanner(AppBanner(tr('가사가 이미 {0}(이)라서 해석을 생략했어요.', [target.nativeName])));
      return;
    }
    final done = collection.translations
        .where((t) => t.songID == songID && t.targetLanguage == targetFor(songID).code && t.outcome != Outcome.failed)
        .map((t) => t.index)
        .toSet();
    _mutate((s) => s.updateSong(songID, (song) => song.status = SongStatus.translating));

    final token = CancelToken();
    _jobs[songID] = token;
    final job = TranslationJob(songID: songID, lines: lines, target: target, engine: engine);
    job
        .run(
          alreadyDone: done,
          token: token,
          commit: (r) {
            if (!token.isCancelled) {
              _mutate((s) => s.commit(r, songID: songID, target: targetFor(songID).code, engineID: engine.id));
            }
          },
          progress: (p) {
            if (!token.isCancelled) {
              progress[songID] = p;
              notifyListeners();
            }
          },
        )
        .then((_) => _finishTranslation(songID, token, null), onError: (Object e) => _finishTranslation(songID, token, e));
  }

  void _finishTranslation(String songID, CancelToken token, Object? error) {
    if (_jobs[songID] == token) _jobs.remove(songID);
    // Paused (backgrounded) or deleted: keep "translating" so the job resumes on return.
    if (error is CancelledException || token.isCancelled) {
      notifyListeners();
      return;
    }
    final lines = collection.linesFor(songID).length;
    final ok = collection.translatedCount(songID, targetFor(songID).code);
    _mutate((s) => s.updateSong(
        songID, (song) => song.status = (error == null && ok == lines) ? SongStatus.done : SongStatus.failed));
    if (error is LLMError) {
      final fixable = error.kind == LLMErrorKind.invalidKey || error.kind == LLMErrorKind.missingAPIKey || error.kind == LLMErrorKind.unavailable;
      banner = AppBanner(tr(error.userMessage), actionTitle: fixable ? tr('설정') : null);
      notifyListeners();
    }
  }

  bool isTranslating(String songID) => _jobs.containsKey(songID);

  /// On relaunch only untranslated lines are processed (RQ-7).
  void _resumeUnfinishedJobs() {
    for (final song in [...collection.songs]) {
      if (song.status == SongStatus.translating) startTranslation(song.id);
    }
  }

  /// ONRQ-9: on-device inference pauses when the app leaves the foreground.
  void handleLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) flushSave();
    if (state == AppLifecycleState.paused && settings.engine == EngineKind.onDevice) {
      for (final t in _jobs.values) {
        t.cancel();
      }
      LocalLlama.cancel();
      _jobs.clear();
      notifyListeners();
    } else if (state == AppLifecycleState.resumed) {
      _resumeUnfinishedJobs();
      refreshSourceConnection();
    }
  }

  // ── Library actions ──

  bool toggleSaved(String songID, int index) {
    var saved = false;
    _mutate((s) => saved = s.toggleSaved(songID, index));
    Haptics.light();
    return saved;
  }

  void setConquered(String songID, bool conquered) =>
      _mutate((s) => s.updateSong(songID, (song) => song.conqueredAt = conquered ? DateTime.now() : null));

  void setOffset(String songID, double offset) => _mutate((s) => s.updateSong(songID, (song) => song.offset = offset));

  void deleteSong(String songID, {required bool keepPhrases}) {
    _jobs.remove(songID)?.cancel();
    final cover = collection.song(songID)?.coverPath;
    if (cover != null) CoverStore.delete(cover);
    _mutate((s) => s.deleteSong(songID, keepPhrases: keepPhrases));
    quiz.forget(songID);
  }

  void retranslate(String songID) {
    _jobs.remove(songID)?.cancel();
    _mutate((s) => s.translations.removeWhere((t) => t.songID == songID && t.targetLanguage == targetFor(songID).code));
    startTranslation(songID, skipSameLanguage: false);
  }

  // ── Explanations (RQ-11) ──

  Explanation? cachedExplanation(String songID, int index) =>
      collection.explanation(songID, index, targetFor(songID).code)?.explanation;

  Future<Explanation> explain(String songID, int index, {TranslationEngine? engine}) async {
    if (engine == null) {
      final cached = cachedExplanation(songID, index);
      if (cached != null) return cached;
    }
    final lines = collection.linesFor(songID);
    final line = lines.where((l) => l.index == index).firstOrNull;
    if (line == null) throw LLMError(LLMErrorKind.unavailable, detail: tr('줄을 찾을 수 없어요.'));
    final e = engine ?? currentEngine();
    final explanation = await e.explain(line, Prompts.context(line, lines), targetFor(songID));
    _mutate((s) => s.cacheExplanation(ExplanationRecord(
          songID: songID,
          index: index,
          targetLanguage: targetFor(songID).code,
          engineID: e.id,
          promptVersion: Prompts.version,
          explanation: explanation,
        )));
    return explanation;
  }

  // ── Listen sessions (RQ-13) ──

  void recordSession(ListenSession session) {
    if (session.linesReached.isEmpty && session.explanationsOpened.isEmpty) return;
    _mutate((s) => s.sessions.add(session));
  }

  bool shouldSuggestConquered(String songID) => mastery.shouldSuggest(songID, collection);
  bool canMarkConquered(String songID) => mastery.canMarkConquered(songID, collection);

  // ── Now playing (RQ-2, RQ-3, RQ-4) ──

  /// The collection song matching what the source is playing, if any.
  Song? get nowPlayingSong {
    // A song just started from the app shows at once, before the music app reports it.
    final pending = _seek == null ? null : collection.song(_seek!.songID);
    if (pending != null && _seekValid(pending)) return pending;
    final snap = nowPlaying;
    if (snap == null) return null;
    final byID = collection.songs.where((s) => isNowPlaying(s)).firstOrNull;
    return byID ?? TrackMatcher.match(snap.track, collection.songs);
  }

  /// Whether the music app is playing [song]: the Spotify track the app started for it, or the
  /// same title, artist and length.
  bool isNowPlaying(Song song) {
    final snap = nowPlaying;
    if (snap == null) return false;
    final id = _spotifyIDs[song.id];
    if (id != null && snap.trackID == id) return true;
    return TrackMatcher.matches(song.trackKey, snap.track);
  }

  /// The user connected Spotify (optional since 0.11.0): songs then start in the Spotify app.
  bool get spotifyConnected => settings.connectedSources.contains(SourceID.spotify);

  /// The Google row is offered only in builds that have the client IDs.
  bool get googleAvailable => GoogleAuth.isConfigured;
  GoogleAccountInfo? get googleAccount => settings.googleAccount;

  /// Throws [GoogleSignInException] on failure; a cancelled sign-in changes nothing.
  Future<void> signInGoogle() async {
    final account = await GoogleAuth.signIn();
    if (account != null) updateSettings((s) => s.googleAccount = account);
  }

  Future<void> signOutGoogle() async {
    await GoogleAuth.signOut();
    updateSettings((s) => s.googleAccount = null);
  }

  /// Opens the Spotify login (PKCE) or, when already logged in, connects to the Spotify app.
  Future<void> connect(SourceID id) async {
    if (id != SourceID.spotify || !spotifyAuth.isConfigured) return;
    if (!spotifyAuth.hasToken) {
      try {
        await spotifyAuth.startLogin();
      } catch (_) {
        showBanner(AppBanner(tr('브라우저를 열지 못했어요.')));
      }
      return;
    }
    updateSettings((st) => st.connectedSources.add(id));
    await attachSpotify();
    fillCovers();
  }

  /// Logs out of Spotify; any other music app is still followed.
  Future<void> disconnect(SourceID id) async {
    if (id != SourceID.spotify) return;
    await spotifyAuth.logout();
    await SpotifyRemote.disconnect();
    _spotifyLists = null;
    _detachPrimary();
    updateSettings((s) => s.connectedSources.remove(id));
  }

  // ── Playback position shared by the player, its controls and the line popup ──

  _SeekOverride? _seek;

  bool _seekValid(Song song) {
    final o = _seek;
    if (o == null || o.songID != song.id) return false;
    final snap = nowPlaying;
    // The music app has reported back after the seek, or the seek is stale.
    final caughtUp = snap != null && isNowPlaying(song) && snap.reportedAt.isAfter(o.at.add(const Duration(milliseconds: 800)));
    // Spotify can take a few seconds (search, play, its own status lag) to report a new song.
    if (caughtUp || DateTime.now().difference(o.at) > const Duration(seconds: 10)) {
      _seek = null;
      return false;
    }
    return true;
  }

  /// Position of [song] in seconds while the music app plays it, or null. Right after a seek or a
  /// play/pause the requested state is used until the music app reports back (Spotify is polled
  /// every 3 s), so lyrics and the seek bar move at once.
  /// True while another song has just been started and the music app has not caught up yet.
  bool _supersededBy(Song song) {
    final o = _seek;
    if (o == null || o.songID == song.id) return false;
    final pending = collection.song(o.songID);
    return pending != null && _seekValid(pending);
  }

  double? positionOf(Song song) {
    if (_supersededBy(song)) return null;
    if (_seekValid(song)) {
      final o = _seek!;
      return o.position + (o.playing ? DateTime.now().difference(o.at).inMicroseconds / 1e6 : 0);
    }
    if (isNowPlaying(song)) return (SyncEngine()..update(nowPlaying!)).position();
    return tapSynced(song) ? _tapSync!.position() : null;
  }

  bool isPlayingSong(Song song) {
    if (_supersededBy(song)) return false;
    if (_seekValid(song)) return _seek!.playing;
    if (isNowPlaying(song)) return nowPlaying?.isPlaying ?? false;
    return tapSynced(song) && _tapSync!.isPlaying;
  }

  // ── Tap to sync: lyrics on the phone's clock, for music the app can't follow ──

  TapSyncClock? _tapSync;

  /// [song] runs on the tap-to-sync clock. A music app that reports the song takes over.
  bool tapSynced(Song song) => _tapSync?.songID == song.id && !isNowPlaying(song);

  /// The user tapped the line being sung: the lyrics run from [position] (seconds).
  void startTapSync(Song song, double position) {
    _seek = null;
    _tapSync = TapSyncClock(song.id, position);
    notifyListeners();
  }

  void stopTapSync() {
    if (_tapSync == null) return;
    _tapSync = null;
    notifyListeners();
  }

  /// Saves the times tapped for each line; the song then has synced lyrics. Unless a music app
  /// follows the song, the lyrics keep running from [now] (the last tap's time plus the delay).
  void saveTapTimings(String songID, List<double> starts, {double? now}) {
    _mutate((c) => c.setLineStarts(songID, starts));
    final song = collection.song(songID);
    if (song != null && now != null && !isNowPlaying(song)) _tapSync = TapSyncClock(songID, now);
    notifyListeners();
  }

  /// Moves [song] to [position] seconds; starts it (Spotify or practice mode) when it is not playing.
  void seekSong(Song song, double position) {
    final linked = isNowPlaying(song);
    final at = max(0.0, position);
    if (!linked && tapSynced(song)) {
      _tapSync!.seek(at);
      notifyListeners();
      return;
    }
    if (linked && !(source?.capabilities.contains(SourceCapability.seek) ?? true)) {
      showBanner(AppBanner(tr('이 음악 앱은 구간 이동을 지원하지 않아요.')));
      return;
    }
    _seek = _SeekOverride(song.id, at, DateTime.now(), linked ? isPlayingSong(song) : true);
    notifyListeners();
    if (linked) {
      source?.seek(at);
    } else {
      playSong(song, at: at);
    }
  }

  void togglePlaySong(Song song) {
    if (!isNowPlaying(song) && !_seekValid(song) && tapSynced(song)) {
      _tapSync!.setPlaying(!_tapSync!.isPlaying);
      notifyListeners();
      return;
    }
    if (!isNowPlaying(song) && !_seekValid(song)) {
      playSong(song);
      return;
    }
    final playing = isPlayingSong(song);
    _seek = _SeekOverride(song.id, positionOf(song) ?? 0, DateTime.now(), !playing);
    notifyListeners();
    playing ? source?.pause() : source?.play();
  }

  late final Map<String, String> _spotifyIDs = () {
    try {
      return Map<String, String>.from(jsonDecode(prefs.getString(_spotifyIDsKey) ?? '{}') as Map);
    } catch (_) {
      return <String, String>{};
    }
  }();
  static const _spotifyIDsKey = 'spotify.trackIDs.v1';

  void _rememberSpotifyID(String songID, String trackID) {
    _spotifyIDs[songID] = trackID;
    prefs.setString(_spotifyIDsKey, jsonEncode(_spotifyIDs));
  }
  /// Spotify track id for a song: remembered, or looked up once with Spotify search.
  Future<String?> _trackIDFor(Song song) async {
    final known = _spotifyIDs[song.id];
    if (known != null || !spotifyAuth.hasToken) return known;
    final hit = await spotifyLibrary.findTrack(song.title, song.artist);
    if (hit == null) return null;
    _rememberSpotifyID(song.id, hit.id);
    // Use Spotify's length so the playing track links to this song's lyrics.
    final d = hit.duration;
    if (d != null && (song.duration == null || (song.duration! - d).abs() > TrackMatcher.durationTolerance)) {
      _mutate((c) => c.updateSong(song.id, (x) => x.duration = d));
    }
    return hit.id;
  }

  /// Plays a song. With Spotify connected it starts in the Spotify app (App Remote SDK); otherwise
  /// the music app being followed is asked to find and play it. The screens switch at once and the
  /// music app confirms a moment later.
  Future<void> playSong(Song song, {double at = 0}) async {
    _seek = _SeekOverride(song.id, at, DateTime.now(), true);
    notifyListeners();
    void fail(String message, {String? action, VoidCallback? onAction}) {
      if (_seek?.songID == song.id) _seek = null;
      _pendingStart = null;
      showBanner(AppBanner(message, actionTitle: action, onAction: onAction));
    }

    try {
      if (spotifyConnected) {
        final player = await attachSpotify();
        if (player != null) {
          final id = await _trackIDFor(song);
          if (id == null) {
            fail(tr('Spotify에서 이 곡을 찾지 못했어요.'));
            return;
          }
          final err = await player.playTrack('spotify:track:$id', position: at);
          if (err != null) fail(err);
          return;
        }
      }
      final app = await attachMusicApp() ? _musicApp : null;
      if (app == null) {
        if (spotifyConnected && !MusicApp.supported) {
          fail(spotifyRemoteIssue ?? tr('Spotify 앱과 연결하지 못했어요 ({0}).', ['—']), action: tr('다시 연결'), onAction: () {
            showBanner(null);
            attachSpotify(retryRemote: true);
          });
        } else if (!MusicApp.supported) {
          // Nothing to follow: the user plays the song in their music app and the lyrics run on
          // tap to sync from [at].
          if (song.lyricsType != LyricsType.synced) {
            fail(tr('음악 앱에서 이 곡을 틀어 주세요. 싱크가 없는 가사는 메뉴에서 탭으로 싱크를 만들 수 있어요.'));
            return;
          }
          startTapSync(song, at);
          showBanner(AppBanner(tr('음악 앱에서 이 곡을 틀어 주세요. 어긋나면 듣고 있는 줄을 탭하세요.')));
        } else {
          fail(tr('음악 앱과 연결되지 않았어요. 연결하면 듣는 곡의 가사가 따라와요.'), action: tr('연결하기'), onAction: () {
            showBanner(null);
            requestMusicAppAccess();
          });
        }
        return;
      }
      // Already the track in the music app: just resume there.
      if (app.last != null && TrackMatcher.matches(song.trackKey, app.last!.track)) {
        source = app;
        activeSourceID = app.id;
        if (at > 0) await app.seek(at);
        await app.play();
        return;
      }
      _pendingStart = _PendingStart(song.id, at, DateTime.now());
      final err = await app.playFromSearch('${TrackNormalizer.primaryArtist(song.artist)} ${song.title}'.trim(), package: _lastMusicPackage);
      if (err != null) fail(err);
    } catch (e) {
      fail('$e');
    }
  }

  /// A song asked to start in another music app; seeks to [at] once the app reports it.
  _PendingStart? _pendingStart;

  String? get _lastMusicPackage => prefs.getString(_musicPackageKey);
  static const _musicPackageKey = 'musicApp.lastPackage.v1';

  /// Tests drive playback with a simulated source.
  @visibleForTesting
  void debugAttach(NowPlayingSource s) => _attach(s);

  void _attach(NowPlayingSource s) {
    _sourceSub?.cancel();
    if (_primary != s) _primary?.dispose();
    _primary = s;
    source = s;
    activeSourceID = s.id;
    _sourceSub = s.snapshots.listen((snap) => _onSnapshot(s, snap));
    notifyListeners();
  }

  void _detachPrimary() {
    _sourceSub?.cancel();
    _primary?.dispose();
    if (source == _primary) {
      source = _musicApp;
      activeSourceID = _musicApp?.id;
      nowPlaying = _musicApp?.last;
    }
    _primary = null;
    notifyListeners();
  }

  /// A report from either source. The screens follow whichever app is playing; a paused report
  /// from another source doesn't take over from one that is playing.
  void _onSnapshot(NowPlayingSource from, PlaybackSnapshot snap) {
    // With the App Remote connected, Spotify's own media session would only duplicate it.
    if (from == _musicApp && _primary is SpotifyRemoteSource && snap.appPackage == 'com.spotify.music') return;
    if (from != source && source != null && (nowPlaying?.isPlaying ?? false) && !snap.isPlaying) return;
    source = from;
    activeSourceID = from.id;
    nowPlaying = snap;
    if (from == _musicApp && snap.appPackage != null && snap.isPlaying && prefs.getString(_musicPackageKey) != snap.appPackage) {
      prefs.setString(_musicPackageKey, snap.appPackage!);
    }
    final p = _pendingStart;
    if (p != null) {
      final song = collection.song(p.songID);
      if (song == null || DateTime.now().difference(p.at) > const Duration(seconds: 20)) {
        _pendingStart = null;
      } else if (TrackMatcher.matches(song.trackKey, snap.track)) {
        _pendingStart = null;
        if (p.position > 1) from.seek(p.position);
      }
    }
    if (from == _musicApp) _artFromMusicApp(snap);
    notifyListeners();
  }

  // ── Any music app (Android media sessions) ──

  /// Notification access is granted, so other music apps can be followed.
  bool musicAppAccess = false;

  /// Starts following other music apps when notification access is granted. Returns whether it is.
  Future<bool> attachMusicApp() async {
    if (_musicApp != null) return true;
    if (!MusicApp.supported) return false;
    musicAppAccess = await MusicApp.hasAccess();
    if (!musicAppAccess) {
      notifyListeners();
      return false;
    }
    final app = MusicAppSource(onIdle: _onMusicAppIdle);
    try {
      await app.start();
    } catch (_) {
      app.dispose();
      musicAppAccess = false;
      notifyListeners();
      return false;
    }
    _musicApp = app;
    // Lives as long as the app: the music-app source is never replaced.
    app.snapshots.listen((snap) => _onSnapshot(app, snap));
    notifyListeners();
    return true;
  }

  void _onMusicAppIdle() {
    if (source != _musicApp) return;
    source = _primary;
    activeSourceID = _primary?.id;
    nowPlaying = null;
    notifyListeners();
  }

  /// The library suggests connecting a music app until access is granted or the card is closed.
  bool get showMusicAppPrompt => MusicApp.supported && !musicAppAccess && !(prefs.getBool(_musicPromptKey) ?? false);
  static const _musicPromptKey = 'musicApp.promptDismissed.v1';

  void dismissMusicAppPrompt() {
    prefs.setBool(_musicPromptKey, true);
    notifyListeners();
  }

  /// Explains notification access, then opens the Android settings screen for it. The app
  /// connects when the user comes back (see [refreshSourceConnection]).
  Future<void> requestMusicAppAccess() async {
    if (!MusicApp.supported) return;
    try {
      await MusicApp.openAccessSettings();
    } catch (_) {
      showBanner(AppBanner(tr('설정을 열지 못했어요.')));
    }
  }

  /// Follows other music apps (when allowed) and reconnects to the Spotify app, at launch and
  /// when the app becomes active again (RQ-2).
  Future<void> refreshSourceConnection() async {
    if (_musicApp == null) await attachMusicApp();
    if (_primary is SpotifyRemoteSource || !spotifyConnected || !spotifyAuth.isConfigured || !spotifyAuth.hasToken) return;
    await attachSpotify();
  }

  final Set<String> _artTried = {};

  /// Saves the music app's album art for a collection song that has no cover yet.
  Future<void> _artFromMusicApp(PlaybackSnapshot snap) async {
    final song = TrackMatcher.match(snap.track, collection.songs);
    if (song == null || song.coverPath != null || !_artTried.add(song.id)) return;
    final bytes = await MusicApp.artwork();
    if (bytes == null || collection.song(song.id)?.coverPath != null) return;
    final name = CoverStore.saveBytes(bytes, song.id, ext: 'jpg');
    if (name != null) _mutate((s) => s.updateSong(song.id, (x) => x.coverPath = name));
  }

  // ── Covers chosen while translating (Notion "LLM이 번역하는 동안") ──

  void setCoverFromFile(String songID, String path) => _replaceCover(songID, CoverStore.save(path, songID));

  /// A generated "CD colour" cover rendered to PNG by the UI.
  void setCoverBytes(String songID, Uint8List png) => _replaceCover(songID, CoverStore.saveBytes(png, songID));

  void _replaceCover(String songID, String? name) {
    if (name == null) {
      showBanner(AppBanner(tr('커버를 저장하지 못했어요.')));
      return;
    }
    final old = collection.song(songID)?.coverPath;
    if (old != null && old != name) CoverStore.delete(old);
    _mutate((s) => s.updateSong(songID, (song) => song.coverPath = name));
  }

  // ── Spotify library (playlists, saved albums, liked songs) ──

  /// Logged in with the scopes needed to read the library.
  bool get spotifyLibraryReady =>
      spotifyAuth.isConfigured && spotifyAuth.hasToken && spotifyAuth.hasLibraryScopes && settings.connectedSources.contains(SourceID.spotify);

  Future<(List<SpotifyList>, List<SpotifyList>)>? _spotifyLists;

  /// Playlists and saved albums, fetched once per session unless [refresh] is set.
  Future<(List<SpotifyList>, List<SpotifyList>)> spotifyLists({bool refresh = false}) {
    if (refresh || _spotifyLists == null) {
      final f = Future.wait([spotifyLibrary.playlists(), spotifyLibrary.savedAlbums()]).then((r) => (r[0], r[1]));
      _spotifyLists = f;
      // A failed load is retried next time.
      f.catchError((Object _) {
        if (_spotifyLists == f) _spotifyLists = null;
        return (const <SpotifyList>[], const <SpotifyList>[]);
      });
    }
    return _spotifyLists!;
  }

  final Set<String> _coverTried = {};
  bool _fillingCovers = false;

  /// Gives songs without a cover their album art (one search per song per session): from Spotify
  /// when it is connected, otherwise from the iTunes Search API.
  Future<void> fillCovers() async {
    if (_fillingCovers) return;
    final useSpotify = spotifyAuth.isConfigured && spotifyAuth.hasToken;
    _fillingCovers = true;
    try {
      for (final song in [...collection.songs]) {
        if (song.coverPath != null || song.sourceProvider == 'demo' || !_coverTried.add(song.id)) continue;
        try {
          final url = useSpotify
              ? (await spotifyLibrary.findTrack(song.title, song.artist))?.imageUrl
              : await webArtwork.find(song.title, song.artist);
          if (url == null) continue;
          final bytes = await SpotifyLibrary.download(url);
          if (bytes == null || collection.song(song.id)?.coverPath != null) continue;
          final name = CoverStore.saveBytes(bytes, song.id, ext: 'jpg');
          if (name != null) _mutate((s) => s.updateSong(song.id, (x) => x.coverPath = name));
        } on SpotifyLibraryException catch (e) {
          if (e.status == 401 || e.status == 403 || e.status == 429) break;
        } catch (_) {
          // Offline: try again next session.
          _coverTried.remove(song.id);
          break;
        }
      }
    } finally {
      _fillingCovers = false;
    }
  }

  // ── Spotify playback: only through the Spotify app (App Remote SDK) ──

  /// Why the Spotify app cannot be used right now, or null (shown in settings and banners).
  String? spotifyRemoteIssue;
  bool _remoteFailed = false;

  bool get usingSpotifyApp => _primary is SpotifyRemoteSource;

  /// Hook for tests: replaces the platform connection.
  @visibleForTesting
  static Future<void> Function()? debugConnectRemote;

  /// The Spotify app connection, connecting first if needed. Returns null (with
  /// [spotifyRemoteIssue] set) when the Spotify app is missing or refuses. A failed connection is
  /// not retried on every play, only when [retryRemote] is set or the app becomes active again.
  Future<SpotifyRemoteSource?> attachSpotify({bool retryRemote = false}) async {
    final current = _primary;
    if (current is SpotifyRemoteSource) return current;
    if (_remoteFailed && !retryRemote) return null;
    if (!SpotifyRemote.supported) {
      spotifyRemoteIssue = tr('이 기기에서는 Spotify 재생을 지원하지 않아요.');
      _remoteFailed = true;
      notifyListeners();
      return null;
    }
    try {
      if (debugConnectRemote != null) {
        await debugConnectRemote!();
      } else {
        if (!await SpotifyRemote.installed()) throw const SpotifyRemoteException('CouldNotFindSpotifyApp');
        await SpotifyRemote.connect();
      }
      spotifyRemoteIssue = null;
      _remoteFailed = false;
      final s = SpotifyRemoteSource(onError: (m) => showBanner(AppBanner(m)), onDisconnected: _onSpotifyAppLost);
      _attach(s);
      return s;
    } on SpotifyRemoteException catch (e) {
      spotifyRemoteIssue = e.userMessage;
    } catch (e) {
      spotifyRemoteIssue = '$e';
    }
    _remoteFailed = true;
    notifyListeners();
    return null;
  }

  /// The Spotify app closed the connection; the next play reconnects.
  void _onSpotifyAppLost() {
    if (_primary is! SpotifyRemoteSource) return;
    _remoteFailed = false;
    if (source == _primary) nowPlaying = null;
    _detachPrimary();
  }

  // ── Recommendations ──

  final Map<String, List<ShelfEntry>> _recommendCache = {};
  int _recommendVersion = -1;

  /// Cached per collection version: the library rebuilds on every playback tick.
  List<ShelfEntry> recommendations({Song? after, int limit = 10}) {
    if (_recommendVersion != collection.version) {
      _recommendCache.clear();
      _recommendVersion = collection.version;
    }
    return _recommendCache['${after?.id}:$limit'] ??= Recommender.pick(shelves, collection, after: after, limit: limit);
  }

  final Map<String, bool> _quizable = {};
  int _quizVersion = -1;

  /// Whether a song has enough lyric lines for a quiz, cached per collection version.
  bool canQuiz(String songID) {
    if (_quizVersion != collection.version) {
      _quizable.clear();
      _quizVersion = collection.version;
    }
    return _quizable[songID] ??= QuizBuilder.canQuiz(collection.linesFor(songID));
  }

  /// A line to show under an album: a saved phrase first, else an early translated line.
  (String, String?)? featuredLine(String songID) {
    final lines = collection.linesFor(songID);
    if (lines.isEmpty) return null;
    String? tr(int i) => collection.translations
        .where((t) => t.songID == songID && t.index == i && t.targetLanguage == targetFor(songID).code)
        .firstOrNull
        ?.text;
    final saved = collection.phrases.where((p) => p.songID == songID).map((p) => p.index).toList()..sort();
    for (final i in saved) {
      final l = lines.where((l) => l.index == i).firstOrNull;
      if (l != null) return (l.text, tr(i));
    }
    final pick = lines.where((l) => l.text.trim().split(RegExp(r'\s+')).length >= 4).firstOrNull ?? lines.first;
    return (pick.text, tr(pick.index));
  }

  // ── Quiz (Notion "가사 빈칸 문제", levels; clearing all marks the song conquered) ──

  late final QuizProgress quiz = QuizProgress(prefs);

  /// Lines with their translations for the quiz builder.
  Map<int, String> translationsFor(String songID) => {
        for (final t in collection.translations)
          if (t.songID == songID && t.targetLanguage == targetFor(songID).code && t.text != null) t.index: t.text!,
      };

  /// Records a passed level. Returns true when this pass conquered the song.
  bool passQuizLevel(String songID, int level) {
    quiz.pass(songID, level);
    notifyListeners();
    if (quiz.level(songID) >= QuizBuilder.levels && collection.song(songID)?.isConquered == false) {
      setConquered(songID, true);
      return true;
    }
    return false;
  }

  void recordQuizActivity() {
    quiz.markToday();
    notifyListeners();
  }

  // ── Data (RQ-18, PR-10) ──

  String exportData() => CollectionMerger.export(collection);

  ImportReport importData(String data) {
    final incoming = CollectionMerger.decode(data);
    late ImportReport report;
    _mutate((s) => report = CollectionMerger.merge(incoming, s));
    return report;
  }

  int get storageUsedBytes => StorageMeter.bytes(baseDir);

  /// Removes the database, covers, model file and stored keys (PR-10).
  Future<void> deleteAll() async {
    _saveTimer?.cancel();
    _dirtySince = null;
    for (final t in _jobs.values) {
      t.cancel();
    }
    _jobs.clear();
    progress.clear();
    try {
      repository.deleteAll();
    } catch (_) {}
    try {
      if (CoverStore.dir.existsSync()) CoverStore.dir.deleteSync(recursive: true);
    } catch (_) {}
    ModelManager.deleteModel();
    await secureStore.deleteAll();
    await prefs.remove(AppSettings.key);
    quiz.clear();
    await disconnect(SourceID.spotify);
    collection = CollectionSnapshot();
    settings = AppSettings();
    libraryPath = [];
    selectedTab = AppTab.library;
    notifyListeners();
  }
}

/// Makes the AppModel available to the widget tree and rebuilds dependents on change.
class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({super.key, required AppModel model, required super.child}) : super(notifier: model);

  static AppModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppModel read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

extension ModelContext on BuildContext {
  AppModel get model => AppScope.of(this);
  AppModel get readModel => AppScope.read(this);
}

/// Exposes kDebugMode-free platform name for copy that differs between Android and iOS.
bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

/// A seek or play/pause the music app has not confirmed yet.
class _SeekOverride {
  final String songID;
  final double position;
  final DateTime at;
  final bool playing;
  const _SeekOverride(this.songID, this.position, this.at, this.playing);
}

class _PendingStart {
  final String songID;
  final double position;
  final DateTime at;
  const _PendingStart(this.songID, this.position, this.at);
}
