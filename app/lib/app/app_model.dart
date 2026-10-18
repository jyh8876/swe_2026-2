import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'platform_services.dart';

/// Navigation inside the Library tab (SSRD 4.1.2: the add flow is linear,
/// Search → Add → Translating → Saved; the player is reached from an LP card).
sealed class Route {
  const Route();
}

class SearchRoute extends Route {
  final String prefill;
  const SearchRoute([this.prefill = '']);
}

class AddRoute extends Route {
  final AddSongDraft draft;
  const AddRoute(this.draft);
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

/// Pre-filled data for FG-03.
class AddSongDraft {
  String title = '';
  String artist = '';
  String? album;
  double? duration;
  String lyrics = '';
  String sourceProvider = 'manual';
  String? curatedShelfID;

  AddSongDraft();

  AddSongDraft.fromCandidate(LyricsCandidate c, {String? shelfID}) {
    title = c.trackName;
    artist = TrackNormalizer.primaryArtist(c.artistName);
    album = c.albumName;
    duration = c.duration;
    lyrics = c.bestLyricsText ?? '';
    sourceProvider = c.id < 0 ? 'demo' : 'lrclib';
    curatedShelfID = shelfID;
  }
}

/// User preferences (FG-09). Stored in SharedPreferences; secrets live in the SecureStore.
class AppSettings {
  bool hasOnboarded = false;
  EngineKind engine = EngineKind.onDevice;
  String targetLanguage = Language.korean.code;
  bool showTranslation = true;

  /// One-time notice before the first cloud translation (SIR-3).
  bool cloudNoticeAccepted = false;
  Set<SourceID> connectedSources = {};

  static const key = 'app.settings.v1';

  Language get target => Language.named(targetLanguage);

  Map<String, dynamic> toJson() => {
        'hasOnboarded': hasOnboarded,
        'engine': engine.name,
        'targetLanguage': targetLanguage,
        'showTranslation': showTranslation,
        'cloudNoticeAccepted': cloudNoticeAccepted,
        'connectedSources': connectedSources.map((s) => s.name).toList(),
      };

  static AppSettings fromJson(Map j) {
    final s = AppSettings();
    s.hasOnboarded = j['hasOnboarded'] == true;
    s.engine = EngineKind.values.firstWhere((e) => e.name == j['engine'], orElse: () => EngineKind.onDevice);
    s.targetLanguage = j['targetLanguage'] as String? ?? Language.korean.code;
    s.showTranslation = j['showTranslation'] != false;
    s.cloudNoticeAccepted = j['cloudNoticeAccepted'] == true;
    s.connectedSources = ((j['connectedSources'] as List?) ?? const [])
        .map((n) => SourceID.values.where((s) => s.name == n).firstOrNull)
        .whereType<SourceID>()
        .toSet();
    return s;
  }
}

enum AppTab { library, phrases, my }

class AppBanner {
  final String message;
  final String? actionTitle;
  AppBanner(this.message, {this.actionTitle});
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
  NowPlayingSource? source;

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
      lyricsProvider: DemoAwareLyricsProvider(),
      prefs: prefs,
      settings: settings,
      collection: snap,
      shelves: shelves,
      baseDir: base,
    );
  }

  // ── Persistence ──

  void _mutate(void Function(CollectionSnapshot) change) {
    change(collection);
    try {
      repository.save(collection);
    } catch (_) {
      banner = AppBanner('저장하지 못했어요: 저장 공간을 확인해 주세요.');
    }
    notifyListeners();
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

  /// Settings live in the "My page" tab.
  void openSettings() {
    banner = null;
    selectedTab = AppTab.my;
    notifyListeners();
  }

  // ── Engines ──

  Language get target => settings.target;

  String? apiKey(EngineKind kind) {
    final k = SecretKey.apiKeyFor(kind);
    return k == null ? null : secureStore.value(k);
  }

  TranslationEngine currentEngine() => EngineFactory.make(settings.engine, apiKey(settings.engine));

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
    return song.id;
  }

  void startTranslation(String songID, {TranslationEngine? forceEngine}) {
    if (_jobs.containsKey(songID)) return;
    final engine = forceEngine ?? currentEngine();
    final lines = collection.linesFor(songID);
    final target = this.target;
    final done = collection.translations
        .where((t) => t.songID == songID && t.targetLanguage == target.code && t.outcome != Outcome.failed)
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
              _mutate((s) => s.commit(r, songID: songID, target: target.code, engineID: engine.id));
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
    final ok = collection.translatedCount(songID, target.code);
    _mutate((s) => s.updateSong(
        songID, (song) => song.status = (error == null && ok == lines) ? SongStatus.done : SongStatus.failed));
    if (error is LLMError) {
      banner = AppBanner(error.userMessage, actionTitle: error.kind == LLMErrorKind.invalidKey ? '설정' : null);
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
    if (state == AppLifecycleState.paused && settings.engine == EngineKind.onDevice) {
      for (final t in _jobs.values) {
        t.cancel();
      }
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
  }

  void retranslate(String songID) {
    _jobs.remove(songID)?.cancel();
    _mutate((s) => s.translations.removeWhere((t) => t.songID == songID && t.targetLanguage == target.code));
    startTranslation(songID);
  }

  // ── Explanations (RQ-11) ──

  Explanation? cachedExplanation(String songID, int index) =>
      collection.explanation(songID, index, target.code)?.explanation;

  Future<Explanation> explain(String songID, int index, {TranslationEngine? engine}) async {
    if (engine == null) {
      final cached = cachedExplanation(songID, index);
      if (cached != null) return cached;
    }
    final lines = collection.linesFor(songID);
    final line = lines.where((l) => l.index == index).firstOrNull;
    if (line == null) throw const LLMError(LLMErrorKind.unavailable, detail: '줄을 찾을 수 없어요.');
    final e = engine ?? currentEngine();
    final explanation = await e.explain(line, Prompts.context(line, lines), target);
    _mutate((s) => s.cacheExplanation(ExplanationRecord(
          songID: songID,
          index: index,
          targetLanguage: target.code,
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
    final t = nowPlaying?.track;
    return t == null ? null : TrackMatcher.match(t, collection.songs);
  }

  Future<void> connect(SourceID id) async {
    final NowPlayingSource s = switch (id) {
      SourceID.simulator => SimulatedSource(DemoContent.candidate.trackKey),
      _ => MockMusicLink.make(id, _mockTrack),
    };
    _attach(s);
    updateSettings((st) => st.connectedSources.add(id));
  }

  void disconnect(SourceID id) {
    updateSettings((s) => s.connectedSources.remove(id));
    if (activeSourceID == id) {
      _sourceSub?.cancel();
      source?.dispose();
      source = null;
      activeSourceID = null;
      nowPlaying = null;
      notifyListeners();
    }
  }

  /// What a mock link "plays" on connect: the newest synced song in the collection,
  /// else the bundled demo song.
  TrackKey get _mockTrack {
    final synced = collection.songs.where((s) => s.lyricsType == LyricsType.synced).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return synced.isNotEmpty ? synced.first.trackKey : DemoContent.candidate.trackKey;
  }

  /// Plays the song on the simulated (or mock-linked) source so sync can be tried anywhere.
  void playDemo(Song song) {
    final current = source;
    SimulatedSource sim;
    if (current is SimulatedSource) {
      sim = current;
    } else {
      sim = SimulatedSource(song.trackKey);
      _attach(sim);
    }
    sim.load(song.trackKey);
  }

  void _attach(NowPlayingSource s) {
    _sourceSub?.cancel();
    if (source != s) source?.dispose();
    source = s;
    activeSourceID = s.id;
    _sourceSub = s.snapshots.listen((snap) {
      nowPlaying = snap;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Revoked access is detected the next time the app becomes active (RQ-2).
  Future<void> refreshSourceConnection() async {
    if (activeSourceID != null) return;
    for (final id in [SourceID.spotify, SourceID.appleMusic]) {
      if (settings.connectedSources.contains(id)) {
        await connect(id);
        return;
      }
    }
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
    disconnect(activeSourceID ?? SourceID.simulator);
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
