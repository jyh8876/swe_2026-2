import Foundation
import Observation
import SwiftUI
import LyricsCore

/// Navigation inside the Library tab (SSRD 4.1.2: the add flow is linear,
/// Search → Add → Translating → Saved; the player is reached from an LP card).
enum Route: Hashable {
    case search(prefill: String)
    case add(AddSongDraft)
    case translating(UUID)
    case saved(UUID)
    case player(UUID)
}

/// Pre-filled data for FG-03.
struct AddSongDraft: Hashable {
    var title = ""
    var artist = ""
    var album: String?
    var duration: TimeInterval?
    var lyrics = ""
    var sourceProvider = "manual"
    var curatedShelfID: String?

    init() {}

    init(candidate: LyricsCandidate, shelfID: String? = nil) {
        title = candidate.trackName
        artist = TrackNormalizer.primaryArtist(candidate.artistName)
        album = candidate.albumName
        duration = candidate.duration
        lyrics = candidate.bestLyricsText ?? ""
        sourceProvider = candidate.id < 0 ? "demo" : "lrclib"
        curatedShelfID = shelfID
    }
}

/// App-wide state. Views read from it; all business rules live in LyricsCore (PR-5).
@MainActor
@Observable
final class AppModel {
    // MARK: State
    private(set) var collection: CollectionSnapshot
    var settings: AppSettings {
        didSet { settings.save() }
    }
    var libraryPath: [Route] = []
    var selectedTab: Tab = .library
    var showSettings = false
    private(set) var progress: [UUID: TranslationProgress] = [:]
    private(set) var nowPlaying: PlaybackSnapshot?
    private(set) var activeSourceID: SourceID?
    var banner: Banner?
    let shelves: [CuratedShelf]

    enum Tab: Hashable { case library, phrases }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var actionTitle: String?
    }

    // MARK: Dependencies
    let repository: CollectionRepository
    let secureStore: SecureStore
    let lyricsProvider: LyricsProvider
    let network = NetworkMonitor()
    let device = DeviceCapability.current
    private let languageDetector = LanguageDetector()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var sourceTask: Task<Void, Never>?
    private(set) var source: (any NowPlayingSource)?
    let mastery = MasteryRules()

    init(
        repository: CollectionRepository = JSONFileRepository(url: AppModel.storeURL),
        secureStore: SecureStore = KeychainSecureStore(),
        lyricsProvider: LyricsProvider = DemoAwareLyricsProvider(),
        settings: AppSettings = .load()
    ) {
        self.repository = repository
        self.secureStore = secureStore
        self.lyricsProvider = lyricsProvider
        self.settings = settings
        self.collection = (try? repository.load()) ?? CollectionSnapshot()
        self.shelves = Curation.bundledShelves()
        resumeUnfinishedJobs()
    }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LyricsTranslator/collection.json")
    }

    static var coversURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LyricsTranslator/Covers", isDirectory: true)
    }

    // MARK: Persistence

    private func mutate(_ change: (inout CollectionSnapshot) -> Void) {
        change(&collection)
        do {
            try repository.save(collection)
        } catch {
            banner = Banner(message: "저장하지 못했어요: 저장 공간을 확인해 주세요.")
        }
    }

    // MARK: Engines

    var target: Language { settings.target }

    func apiKey(for kind: EngineKind) -> String? {
        guard let key = SecretKey.apiKey(for: kind) else { return nil }
        return try? secureStore.value(for: key)
    }

    /// Engine for new work, per Settings. On-device resolves to the engine chosen in spike S1.
    func currentEngine() -> any TranslationEngine {
        EngineFactory.make(settings.engine, apiKey: apiKey(for: settings.engine))
    }

    // MARK: Add flow (RQ-6, RQ-7)

    /// Saves the song and starts pre-translation. Returns the new song id.
    @discardableResult
    func addSong(_ draft: AddSongDraft, cover: Data?) -> UUID {
        let document = LRCParser.parse(draft.lyrics)
        var song = Song(
            title: draft.title.trimmingCharacters(in: .whitespaces),
            artist: draft.artist.trimmingCharacters(in: .whitespaces),
            album: draft.album,
            duration: draft.duration,
            lyricsType: document.type,
            sourceProvider: draft.sourceProvider,
            curatedShelfID: draft.curatedShelfID
        )
        if let cover {
            song.coverPath = CoverStore.save(cover, for: song.id)
        }
        mutate { $0.addSong(song, document: document) }
        detectLanguages(songID: song.id)
        startTranslation(songID: song.id)
        return song.id
    }

    private func detectLanguages(songID: UUID) {
        mutate { snap in
            for i in snap.lines.indices where snap.lines[i].songID == songID {
                snap.lines[i].detectedLanguage = languageDetector.detect(snap.lines[i].text)
            }
        }
    }

    func startTranslation(songID: UUID, forceEngine: (any TranslationEngine)? = nil) {
        guard jobs[songID] == nil else { return }
        let engine = forceEngine ?? currentEngine()
        let lines = collection.lines(for: songID)
        let target = self.target
        let done = Set(collection.translations
            .filter { $0.songID == songID && $0.targetLanguage == target.code && $0.outcome != .failed }
            .map(\.index))
        mutate { $0.updateSong(songID) { $0.status = .translating } }

        let job = TranslationJob(songID: songID, lines: lines, target: target, engine: engine)
        jobs[songID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await job.run(
                    alreadyDone: done,
                    commit: { result in
                        await self.commit(result, songID: songID, target: target.code, engineID: engine.id)
                    },
                    progress: { p in
                        await self.setProgress(p, for: songID)
                    }
                )
                self.finishTranslation(songID: songID, error: nil)
            } catch {
                self.finishTranslation(songID: songID, error: error)
            }
        }
    }

    private func commit(_ result: LineResult, songID: UUID, target: String, engineID: String) {
        mutate { $0.commit(result, songID: songID, target: target, engineID: engineID) }
    }

    private func setProgress(_ p: TranslationProgress, for songID: UUID) {
        progress[songID] = p
    }

    private func finishTranslation(songID: UUID, error: Error?) {
        jobs[songID] = nil
        // Paused (backgrounded) or deleted: keep "translating" so the job resumes on return.
        if error is CancellationError { return }
        let lines = collection.lines(for: songID).count
        let ok = collection.translatedCount(songID: songID, target: target.code)
        mutate { $0.updateSong(songID) { $0.status = (error == nil && ok == lines) ? .done : .failed } }
        if let error = error as? LLMError {
            banner = Banner(message: error.userMessage, actionTitle: error == .invalidKey ? "설정" : nil)
        }
    }

    func isTranslating(_ songID: UUID) -> Bool { jobs[songID] != nil }

    /// On relaunch only untranslated lines are processed (RQ-7).
    private func resumeUnfinishedJobs() {
        for song in collection.songs where song.status == .translating {
            startTranslation(songID: song.id)
        }
    }

    /// ONRQ-9: on-device inference pauses when the app leaves the foreground.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background where settings.engine == .onDevice:
            for (id, task) in jobs {
                task.cancel()
                jobs[id] = nil
            }
        case .active:
            resumeUnfinishedJobs()
            Task { await refreshSourceConnection() }
        default:
            break
        }
    }

    // MARK: Library actions

    func toggleSaved(songID: UUID, index: Int) -> Bool {
        var saved = false
        mutate { saved = $0.toggleSaved(songID: songID, index: index) }
        Haptics.light()
        return saved
    }

    func setConquered(_ songID: UUID, _ conquered: Bool) {
        mutate { $0.updateSong(songID) { $0.conqueredAt = conquered ? Date() : nil } }
    }

    func setOffset(_ songID: UUID, _ offset: TimeInterval) {
        mutate { $0.updateSong(songID) { $0.offset = offset } }
    }

    func deleteSong(_ songID: UUID, keepPhrases: Bool) {
        jobs[songID]?.cancel()
        jobs[songID] = nil
        if let path = collection.song(songID)?.coverPath { CoverStore.delete(path) }
        mutate { $0.deleteSong(songID, keepPhrases: keepPhrases) }
    }

    func retranslate(_ songID: UUID) {
        mutate { snap in
            snap.translations.removeAll { $0.songID == songID && $0.targetLanguage == self.target.code }
        }
        startTranslation(songID: songID)
    }

    // MARK: Explanations (RQ-11)

    func cachedExplanation(songID: UUID, index: Int) -> Explanation? {
        collection.explanation(songID: songID, index: index, target: target.code)?.explanation
    }

    func explain(songID: UUID, index: Int, engine override: (any TranslationEngine)? = nil) async throws -> Explanation {
        if override == nil, let cached = cachedExplanation(songID: songID, index: index) { return cached }
        let lines = collection.lines(for: songID)
        guard let line = lines.first(where: { $0.index == index }) else { throw LLMError.unavailable("줄을 찾을 수 없어요.") }
        let engine = override ?? currentEngine()
        let explanation = try await engine.explain(line, context: Prompts.context(for: line, in: lines), in: target)
        mutate {
            $0.cacheExplanation(ExplanationRecord(songID: songID, index: index, targetLanguage: target.code,
                                                  engineID: engine.id, promptVersion: Prompts.version, explanation: explanation))
        }
        return explanation
    }

    // MARK: Listen sessions (RQ-13)

    func recordSession(_ session: ListenSession) {
        guard !session.linesReached.isEmpty || !session.explanationsOpened.isEmpty else { return }
        mutate { $0.sessions.append(session) }
    }

    func shouldSuggestConquered(_ songID: UUID) -> Bool {
        mastery.shouldSuggest(songID: songID, in: collection)
    }

    func canMarkConquered(_ songID: UUID) -> Bool {
        mastery.canMarkConquered(songID: songID, in: collection)
    }

    // MARK: Now playing (RQ-2, RQ-3, RQ-4)

    /// The collection song matching what the source is playing, if any.
    var nowPlayingSong: Song? {
        guard let track = nowPlaying?.track else { return nil }
        return TrackMatcher.match(track, in: collection.songs)
    }

    func connect(_ id: SourceID) async {
        do {
            let newSource: any NowPlayingSource
            switch id {
            case .appleMusic:
                newSource = try await AppleMusicSource.connect(mockTrack: mockTrack)
            case .spotify:
                newSource = try await SpotifySource.connect(mockTrack: mockTrack)
            case .simulator:
                newSource = SimulatedSource(track: DemoContent.candidate.trackKey)
            }
            attach(newSource)
            settings.connectedSources.insert(id)
        } catch let error as SourceError {
            banner = Banner(message: error.userMessage)
        } catch {
            banner = Banner(message: "연결하지 못했어요.")
        }
    }

    func disconnect(_ id: SourceID) {
        settings.connectedSources.remove(id)
        if activeSourceID == id {
            sourceTask?.cancel()
            source = nil
            activeSourceID = nil
            nowPlaying = nil
        }
    }

    /// What a mock link "plays" on connect: the newest synced song in the collection,
    /// else the bundled demo song.
    private var mockTrack: TrackKey {
        collection.songs.filter { $0.lyricsType == .synced }.max { $0.addedAt < $1.addedAt }?.trackKey
            ?? DemoContent.candidate.trackKey
    }

    /// Plays the song on the simulated (or mock-linked) source so sync can be tried anywhere.
    func playDemo(for song: Song) {
        let sim: SimulatedSource
        if let existing = source as? SimulatedSource {
            sim = existing
        } else {
            sim = SimulatedSource(track: song.trackKey)
            attach(sim)
        }
        sim.load(song.trackKey)
    }

    private func attach(_ newSource: any NowPlayingSource) {
        sourceTask?.cancel()
        source = newSource
        activeSourceID = newSource.id
        sourceTask = Task { [weak self] in
            for await snapshot in newSource.snapshots {
                guard let self, !Task.isCancelled else { return }
                self.nowPlaying = snapshot
            }
        }
    }

    /// Revoked access is detected the next time the app becomes active (RQ-2).
    func refreshSourceConnection() async {
        guard activeSourceID == nil else { return }
        for id in [SourceID.spotify, .appleMusic] where settings.connectedSources.contains(id) {
            await connect(id)
            return
        }
    }

    // MARK: Data (RQ-18, PR-10)

    func exportData() throws -> Data {
        try CollectionMerger.export(collection)
    }

    func importData(_ data: Data) throws -> ImportReport {
        let doc = try CollectionMerger.decode(data)
        var report = ImportReport(songsAdded: 0, songsUpdated: 0, phrasesAdded: 0)
        mutate { report = CollectionMerger.merge(doc.collection, into: &$0) }
        return report
    }

    var storageUsedBytes: Int64 {
        StorageMeter.bytes(at: AppModel.storeURL.deletingLastPathComponent())
    }

    /// Removes the database, covers, model file and stored keys (PR-10).
    func deleteAll() {
        for task in jobs.values { task.cancel() }
        jobs.removeAll()
        progress.removeAll()
        try? repository.deleteAll()
        try? FileManager.default.removeItem(at: AppModel.coversURL)
        ModelManager.deleteModel()
        try? secureStore.deleteAll()
        AppSettings.reset()
        collection = CollectionSnapshot()
        settings = AppSettings()
        libraryPath = []
        selectedTab = .library
    }
}

extension SourceError {
    var userMessage: String {
        switch self {
        case .unsupported: return "음악 앱이 이 기능을 지원하지 않아요."
        case .notConnected: return "음악 앱과 연결이 끊겼어요. 다시 연결해 주세요."
        case .notInstalled: return "Spotify 앱이 설치되어 있지 않아요."
        case .premiumRequired: return "Spotify 재생 제어는 Premium 계정이 필요해요."
        case .permissionDenied: return "음악 접근 권한이 없어요. 설정에서 허용해 주세요."
        }
    }
}
