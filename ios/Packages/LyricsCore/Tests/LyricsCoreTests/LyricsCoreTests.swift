import XCTest
@testable import LyricsCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LRCParserTests: XCTestCase {
    func testParsesSyncedLyricsAndDropsMetadata() {
        let doc = LRCParser.parse("""
        [ar:Someone]
        [ti:Song]
        [00:12.34]First line
        [00:16.80]Second line
        [01:02.5]Third line
        """)
        XCTAssertEqual(doc.type, .synced)
        XCTAssertEqual(doc.lines.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(doc.lines[0].start!, 12.34, accuracy: 0.001)
        XCTAssertEqual(doc.lines[2].start!, 62.5, accuracy: 0.001)
        XCTAssertEqual(doc.lines[0].end!, 16.80, accuracy: 0.001)
    }

    func testRepeatedTagsAreExpandedAndSorted() {
        let doc = LRCParser.parse("[00:10.00][00:30.00]Chorus\n[00:20.00]Verse")
        XCTAssertEqual(doc.lines.map(\.text), ["Chorus", "Verse", "Chorus"])
    }

    func testEmptyTimedLineEndsPreviousLineButIsNotShown() {
        let doc = LRCParser.parse("[00:01.00]A\n[00:05.00]\n[00:09.00]B")
        XCTAssertEqual(doc.lines.map(\.text), ["A", "B"])
        XCTAssertEqual(doc.lines[0].end!, 5, accuracy: 0.001)
    }

    func testEightyPercentRuleForSyncedDetection() {
        // 4 of 5 lines tagged = 80% → synced (RQ-6).
        let synced = LRCParser.parse("[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n[00:04.00]d\nplain")
        XCTAssertEqual(synced.type, .synced)
        // 3 of 5 tagged → plain.
        let plain = LRCParser.parse("[00:01.00]a\n[00:02.00]b\n[00:03.00]c\nx\ny")
        XCTAssertEqual(plain.type, .plain)
        XCTAssertEqual(plain.lines.map(\.text), ["a", "b", "c", "x", "y"])
    }

    func testTagFormatting() {
        XCTAssertEqual(LRCParser.tag(for: 12.34), "[00:12.34]")
        XCTAssertEqual(LRCParser.tag(for: 75), "[01:15.00]")
    }
}

final class TrackMatcherTests: XCTestCase {
    func testNormalizationStripsNoise() {
        XCTAssertEqual(TrackNormalizer.normalize("Viva La Vida (Remastered 2021)"), "viva la vida")
        XCTAssertEqual(TrackNormalizer.normalize("Song feat. Somebody"), "song")
        XCTAssertEqual(TrackNormalizer.normalize("Song [Official MV]"), "song")
        XCTAssertEqual(TrackNormalizer.normalize("Yesterday - 2009 Remaster"), "yesterday")
        XCTAssertEqual(TrackNormalizer.normalize("밤양갱"), "밤양갱")
    }

    func testPrimaryArtist() {
        XCTAssertEqual(TrackNormalizer.primaryArtist("Coldplay/Coldplay"), "Coldplay")
        XCTAssertEqual(TrackNormalizer.primaryArtist("ROSÉ, Bruno Mars"), "ROSÉ")
    }

    func testMatchingUsesDurationTolerance() {
        let a = TrackKey(title: "Viva La Vida", artist: "Coldplay", duration: 242)
        XCTAssertTrue(TrackMatcher.matches(a, TrackKey(title: "Viva la Vida - Remastered", artist: "Coldplay", duration: 243.5)))
        XCTAssertFalse(TrackMatcher.matches(a, TrackKey(title: "Viva La Vida", artist: "Coldplay", duration: 260)))
    }

    func testYouTubeStyleTitleIsSplit() {
        let song = Song(title: "Supernova", artist: "aespa", duration: 179, lyricsType: .synced, sourceProvider: "lrclib")
        let playing = TrackKey(title: "aespa - Supernova (Official MV)", artist: "SMTOWN", duration: 180)
        XCTAssertEqual(TrackMatcher.match(playing, in: [song])?.id, song.id)
    }

    func testRankingPrefersSyncedAndCloseDuration() {
        let track = TrackKey(title: "x", artist: "y", duration: 200)
        let far = LyricsCandidate(id: 1, trackName: "x", artistName: "y", duration: 230, syncedLyrics: "[00:01.00]a")
        let plain = LyricsCandidate(id: 2, trackName: "x", artistName: "y", duration: 200, plainLyrics: "a")
        let synced = LyricsCandidate(id: 3, trackName: "x", artistName: "y", duration: 201, syncedLyrics: "[00:01.00]a")
        XCTAssertEqual(TrackMatcher.rank([far, plain, synced], for: track).map(\.id), [3, 2, 1])
    }
}

final class SyncEngineTests: XCTestCase {
    private func lines() -> [LyricLine] {
        let id = UUID()
        return [5.0, 10.0, 15.0].enumerated().map { LyricLine(songID: id, index: $0.offset, start: $0.element, text: "l\($0.offset)") }
    }

    func testExtrapolatesBetweenReports() {
        var engine = SyncEngine()
        let t0 = Date(timeIntervalSince1970: 1000)
        engine.update(PlaybackSnapshot(track: TrackKey(title: "a", artist: "b"), position: 4, reportedAt: t0, isPlaying: true))
        XCTAssertEqual(engine.position(at: t0.addingTimeInterval(2))!, 6, accuracy: 0.001)
        XCTAssertEqual(engine.currentLineIndex(in: lines(), at: t0.addingTimeInterval(0.5)), nil)
        XCTAssertEqual(engine.currentLineIndex(in: lines(), at: t0.addingTimeInterval(2)), 0)
        XCTAssertEqual(engine.currentLineIndex(in: lines(), at: t0.addingTimeInterval(7)), 1)
        XCTAssertEqual(engine.currentLineIndex(in: lines(), at: t0.addingTimeInterval(60)), 2)
    }

    func testPausedPositionDoesNotAdvance() {
        var engine = SyncEngine()
        let t0 = Date()
        engine.update(PlaybackSnapshot(track: TrackKey(title: "a", artist: "b"), position: 11, reportedAt: t0, isPlaying: false))
        XCTAssertEqual(engine.position(at: t0.addingTimeInterval(30))!, 11, accuracy: 0.001)
    }

    func testOffsetShiftsHighlightAndSeek() {
        var engine = SyncEngine(offset: 1.0)
        let t0 = Date()
        engine.update(PlaybackSnapshot(track: TrackKey(title: "a", artist: "b"), position: 10.5, reportedAt: t0, isPlaying: false))
        // 10.5 − 1.0 = 9.5 → still line 0.
        XCTAssertEqual(engine.currentLineIndex(in: lines(), at: t0), 0)
        XCTAssertEqual(engine.seekTarget(for: lines()[1])!, 11, accuracy: 0.001)
    }
}

final class OutputValidatorTests: XCTestCase {
    private let id = UUID()

    private func lines(_ n: Int) -> [LyricLine] {
        (0..<n).map { LyricLine(songID: id, index: $0, start: nil, text: "line \($0)") }
    }

    func testEveryInputLineIsAccountedFor() {
        let text = """
        Sure! ```json
        {"lines":[{"i":0,"t":"하나"},{"i":1,"copy":true},{"i":3,"t":""}]}
        ```
        """
        let results = OutputValidator.translationResults(from: text, lines: lines(4))
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[0], .translated(index: 0, text: "하나"))
        XCTAssertEqual(results[1], .copied(index: 1))
        XCTAssertEqual(results[2], .failed(index: 2, reason: "missing"))
        XCTAssertEqual(results[3], .failed(index: 3, reason: "empty"))
    }

    func testRepetitionIsRejected() {
        let text = #"{"lines":[{"i":0,"t":"la la la la la la la la la la"}]}"#
        XCTAssertEqual(OutputValidator.translationResults(from: text, lines: lines(1)), [.failed(index: 0, reason: "repetition")])
    }

    func testExplanationCapsExpressionsAtThree() throws {
        let text = #"{"expressions":[{"phrase":"a","meaning":"1"},{"phrase":"b","meaning":"2"},{"phrase":"c","meaning":"3"},{"phrase":"d","meaning":"4"}],"structure":"s","usage":"u","example":"e"}"#
        let e = try OutputValidator.explanation(from: text)
        XCTAssertEqual(e.expressions.map(\.phrase), ["a", "b", "c"])
    }

    func testInvalidExplanationThrows() {
        XCTAssertThrowsError(try OutputValidator.explanation(from: "no json here"))
    }
}

final class CollectionTests: XCTestCase {
    private func makeSnapshot() -> (CollectionSnapshot, Song) {
        var snap = CollectionSnapshot()
        let song = Song(title: DemoContent.songTitle, artist: DemoContent.songArtist, duration: 52, lyricsType: .synced, sourceProvider: "demo")
        snap.addSong(song, document: LRCParser.parse(DemoContent.lrc))
        return (snap, song)
    }

    func testCommitAndQueries() {
        var (snap, song) = makeSnapshot()
        snap.commit(.translated(index: 0, text: "안녕"), songID: song.id, target: "ko", engineID: "demo")
        snap.commit(.copied(index: 1), songID: song.id, target: "ko", engineID: "demo")
        snap.commit(.failed(index: 2, reason: "x"), songID: song.id, target: "ko", engineID: "demo")
        XCTAssertEqual(snap.translationText(songID: song.id, index: 0, target: "ko"), "안녕")
        XCTAssertEqual(snap.translationText(songID: song.id, index: 1, target: "ko"), "—")
        XCTAssertNil(snap.translationText(songID: song.id, index: 2, target: "ko"))
        XCTAssertEqual(snap.translatedCount(songID: song.id, target: "ko"), 2)
    }

    func testToggleSavedAndStats() {
        var (snap, song) = makeSnapshot()
        XCTAssertTrue(snap.toggleSaved(songID: song.id, index: 3))
        XCTAssertEqual(snap.stats, .init(songs: 1, conquered: 0, phrases: 1))
        XCTAssertFalse(snap.toggleSaved(songID: song.id, index: 3))
        XCTAssertEqual(snap.stats.phrases, 0)
    }

    func testDeleteSongKeepsPhrasesByDefault() {
        var (snap, song) = makeSnapshot()
        snap.toggleSaved(songID: song.id, index: 2)
        snap.deleteSong(song.id)
        XCTAssertTrue(snap.songs.isEmpty)
        XCTAssertEqual(snap.phrases.count, 1)
        XCTAssertEqual(snap.lines.map(\.index), [2])
    }

    func testExportImportRoundTrip() throws {
        var (snap, song) = makeSnapshot()
        snap.commit(.translated(index: 0, text: "안녕"), songID: song.id, target: "ko", engineID: "demo")
        snap.toggleSaved(songID: song.id, index: 0)
        let data = try CollectionMerger.export(snap)
        let doc = try CollectionMerger.decode(data)
        var other = CollectionSnapshot()
        let report = CollectionMerger.merge(doc.collection, into: &other)
        XCTAssertEqual(report.songsAdded, 1)
        XCTAssertEqual(report.phrasesAdded, 1)
        XCTAssertEqual(other.songs.map(\.id), [song.id])
        XCTAssertEqual(other.lines.count, snap.lines.count)
        XCTAssertEqual(other.translationText(songID: song.id, index: 0, target: "ko"), "안녕")
        // Merging again changes nothing.
        let again = CollectionMerger.merge(doc.collection, into: &other)
        XCTAssertEqual(again, ImportReport(songsAdded: 0, songsUpdated: 0, phrasesAdded: 0))
        XCTAssertEqual(other.translations.count, 1)
        // Re-importing into the original device (full-precision dates) also adds nothing.
        snap.sessions.append(ListenSession(songID: song.id))
        let withSession = try CollectionMerger.decode(try CollectionMerger.export(snap))
        let back = CollectionMerger.merge(withSession.collection, into: &snap)
        XCTAssertEqual(back, ImportReport(songsAdded: 0, songsUpdated: 0, phrasesAdded: 0))
        XCTAssertEqual(snap.translations.count, 1)
        XCTAssertEqual(snap.sessions.count, 1)
    }

    func testNewerSchemaIsRejected() {
        let data = #"{"schemaVersion":99}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CollectionMerger.decode(data)) { error in
            XCTAssertEqual(error as? ImportError, .newerSchema(99))
        }
        XCTAssertThrowsError(try CollectionMerger.decode(Data("garbage".utf8)))
    }

    func testJSONRepositoryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = JSONFileRepository(url: url)
        let (snap, _) = makeSnapshot()
        try repo.save(snap)
        XCTAssertEqual(try repo.load(), snap)
        try repo.deleteAll()
        XCTAssertEqual(try repo.load(), CollectionSnapshot())
    }

    func testMasteryRules() {
        var (snap, song) = makeSnapshot()
        let rules = MasteryRules()
        let all = Set(snap.lines(for: song.id).map(\.index))
        XCTAssertFalse(rules.canMarkConquered(songID: song.id, in: snap))
        snap.sessions.append(ListenSession(songID: song.id, linesReached: all))
        XCTAssertTrue(rules.canMarkConquered(songID: song.id, in: snap))
        XCTAssertFalse(rules.shouldSuggest(songID: song.id, in: snap))
        snap.sessions.append(ListenSession(songID: song.id, linesReached: all, explanationsOpened: [0, 1]))
        snap.sessions.append(ListenSession(songID: song.id, linesReached: all, explanationsOpened: [2]))
        // 3 play-throughs, 3 of 10 lines explained = 30% → suggest.
        XCTAssertTrue(rules.shouldSuggest(songID: song.id, in: snap))
    }
}

final class TranslationJobTests: XCTestCase {
    actor Sink {
        var results: [LineResult] = []
        var last: TranslationProgress?
        func add(_ r: LineResult) { results.append(r) }
        func set(_ p: TranslationProgress) { last = p }
    }

    func testDemoEngineTranslatesWholeSongAndSkipsDoneLines() async throws {
        let id = UUID()
        let lines = LRCParser.parse(DemoContent.lrc).lyricLines(songID: id)
        let job = TranslationJob(songID: id, lines: lines, target: .korean, engine: DemoEngine(lineDelay: 0))
        let sink = Sink()
        try await job.run(alreadyDone: [0, 1], commit: { await sink.add($0) }, progress: { await sink.set($0) })
        let results = await sink.results
        let last = await sink.last
        XCTAssertEqual(results.count, lines.count - 2)
        XCTAssertEqual(Set(results.map(\.index)), Set(2..<lines.count))
        XCTAssertEqual(last?.done, lines.count)
        XCTAssertEqual(last?.stage, .save)
        XCTAssertTrue(results.contains(.translated(index: 2, text: "근데 넌 말했지, 편하게 생각해, 그냥 흘려보내")))
    }

    func testCancelledJobDoesNotMarkLinesFailed() async throws {
        let id = UUID()
        let lines = LRCParser.parse(DemoContent.lrc).lyricLines(songID: id)
        let job = TranslationJob(songID: id, lines: lines, target: .korean, engine: DemoEngine(lineDelay: 0.05))
        let sink = Sink()
        let task = Task { try await job.run(alreadyDone: [], commit: { await sink.add($0) }, progress: { await sink.set($0) }) }
        try await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        let results = await sink.results
        XCTAssertLessThan(results.count, lines.count)
        XCTAssertFalse(results.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testKoreanLinesAreCopiedForKoreanTarget() async throws {
        let line = LyricLine(songID: UUID(), index: 0, start: nil, text: "사랑해요")
        var results: [LineResult] = []
        for try await r in DemoEngine(lineDelay: 0).translateSong([line], to: .korean) { results.append(r) }
        XCTAssertEqual(results, [.copied(index: 0)])
    }
}

final class CloudEngineTests: XCTestCase {
    struct StubTransport: HTTPTransport {
        let status: Int
        let body: String
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testClaudeTranslationParsesStructuredOutput() async throws {
        let inner = #"{\"lines\":[{\"i\":0,\"t\":\"하나\"},{\"i\":1,\"t\":\"둘\"}]}"#
        let body = #"{"content":[{"type":"text","text":"\#(inner)"}],"stop_reason":"end_turn"}"#
        let engine = ClaudeEngine(apiKey: "sk-test", transport: StubTransport(status: 200, body: body))
        let id = UUID()
        let lines = [LyricLine(songID: id, index: 0, start: nil, text: "one"), LyricLine(songID: id, index: 1, start: nil, text: "two")]
        var results: [LineResult] = []
        for try await r in engine.translateSong(lines, to: .korean) { results.append(r) }
        XCTAssertEqual(results, [.translated(index: 0, text: "하나"), .translated(index: 1, text: "둘")])
    }

    func testClaudeAuthErrorMapsToInvalidKey() async {
        let engine = ClaudeEngine(apiKey: "bad", transport: StubTransport(status: 401, body: "{}"))
        do {
            try await engine.verifyKey()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .invalidKey)
        }
    }

    func testMissingKeyFailsFast() async {
        let engine = GeminiEngine(apiKey: "")
        XCTAssertFalse(engine.isAvailable)
        do {
            try await engine.verifyKey()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
    }
}

final class MiscTests: XCTestCase {
    func testBundledShelvesLoad() {
        let shelves = Curation.bundledShelves()
        XCTAssertGreaterThanOrEqual(shelves.count, 3)
        XCTAssertTrue(shelves.allSatisfy { !$0.songs.isEmpty })
    }

    func testStaticProviderSearch() async throws {
        let provider = StaticLyricsProvider(candidates: DemoContent.candidates)
        let results = try await provider.search("day off")
        XCTAssertEqual(results.first?.availability, .synced)
        XCTAssertEqual(DemoContent.plainOnly.availability, .plain)
        XCTAssertEqual(DemoContent.noLyrics.availability, LyricsCandidate.Availability.none)
    }

    func testSecretMasking() throws {
        XCTAssertEqual(maskSecret("sk-ant-api03-abcdefgh1234"), "sk-ant…1234")
        let store = InMemorySecureStore()
        try store.set("k", for: .claudeAPIKey)
        try store.deleteAll()
        XCTAssertNil(try store.value(for: .claudeAPIKey))
    }

    func testSimulatedSourceStreamsSnapshots() async throws {
        let source = SimulatedSource(track: TrackKey(title: "a", artist: "b", duration: 60))
        var iterator = source.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.isPlaying, false)
        try await source.seek(to: 12)
        let second = await iterator.next()
        XCTAssertEqual(second?.position ?? 0, 12, accuracy: 0.01)
    }
}
