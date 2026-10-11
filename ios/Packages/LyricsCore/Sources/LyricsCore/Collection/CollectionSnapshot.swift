import Foundation

/// The whole local collection as one value. The app holds one of these, mutates it, and
/// persists through a `CollectionRepository` after every change (per-line commits, LOS-3).
///
/// Prototype note: persistence is an atomically written JSON file. The SSRD target is SQLite
/// in WAL mode with versioned migrations; swap the repository without touching callers.
public struct CollectionSnapshot: Codable, Sendable, Hashable {
    public var songs: [Song]
    public var lines: [LyricLine]
    public var translations: [Translation]
    public var explanations: [ExplanationRecord]
    public var phrases: [Phrase]
    public var sessions: [ListenSession]

    public init(songs: [Song] = [], lines: [LyricLine] = [], translations: [Translation] = [], explanations: [ExplanationRecord] = [], phrases: [Phrase] = [], sessions: [ListenSession] = []) {
        self.songs = songs
        self.lines = lines
        self.translations = translations
        self.explanations = explanations
        self.phrases = phrases
        self.sessions = sessions
    }

    // MARK: Queries

    /// Newest first (RQ-9).
    public var songsNewestFirst: [Song] { songs.sorted { $0.addedAt > $1.addedAt } }

    public func song(_ id: UUID) -> Song? { songs.first { $0.id == id } }

    public func lines(for songID: UUID) -> [LyricLine] {
        lines.filter { $0.songID == songID }.sorted { $0.index < $1.index }
    }

    /// Latest translation of a line for a target language, any engine.
    public func translation(songID: UUID, index: Int, target: String) -> Translation? {
        translations
            .filter { $0.songID == songID && $0.index == index && $0.targetLanguage == target }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Display text for a line's translation: copied lines show a dash (RQ-15).
    public func translationText(songID: UUID, index: Int, target: String) -> String? {
        guard let t = translation(songID: songID, index: index, target: target) else { return nil }
        switch t.outcome {
        case .translated: return t.text
        case .copied: return "—"
        case .failed: return nil
        }
    }

    public func translatedCount(songID: UUID, target: String) -> Int {
        Set(translations.filter { $0.songID == songID && $0.targetLanguage == target && $0.outcome != .failed }.map(\.index)).count
    }

    public func explanation(songID: UUID, index: Int, target: String) -> ExplanationRecord? {
        explanations
            .filter { $0.songID == songID && $0.index == index && $0.targetLanguage == target }
            .max { $0.createdAt < $1.createdAt }
    }

    public func isSaved(songID: UUID, index: Int) -> Bool {
        phrases.contains { $0.songID == songID && $0.index == index }
    }

    public var stats: Stats {
        Stats(songs: songs.count, conquered: songs.filter(\.isConquered).count, phrases: phrases.count)
    }

    public struct Stats: Sendable, Hashable {
        public var songs: Int
        public var conquered: Int
        public var phrases: Int
    }

    /// Duplicate check: same normalised title, artist and duration ±2 s (RQ-6).
    public func existingSong(matching key: TrackKey) -> Song? {
        songs.first { TrackMatcher.matches($0.trackKey, key) }
    }

    // MARK: Mutations

    public mutating func addSong(_ song: Song, document: LyricsDocument) {
        songs.append(song)
        lines.append(contentsOf: document.lyricLines(songID: song.id))
    }

    public mutating func updateSong(_ id: UUID, _ change: (inout Song) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        change(&songs[i])
    }

    /// Deleting a song asks whether to keep its saved phrases (default: keep, RQ-12).
    /// Kept phrases keep their song/line data so they still render.
    public mutating func deleteSong(_ id: UUID, keepPhrases: Bool = true) {
        let keptIndexes = Set(phrases.filter { $0.songID == id }.map(\.index))
        if keepPhrases && !keptIndexes.isEmpty {
            // Keep the song record hidden-but-present is out of scope for the prototype:
            // retain only lines and translations that saved phrases reference.
            lines.removeAll { $0.songID == id && !keptIndexes.contains($0.index) }
            translations.removeAll { $0.songID == id && !keptIndexes.contains($0.index) }
        } else {
            lines.removeAll { $0.songID == id }
            translations.removeAll { $0.songID == id }
            phrases.removeAll { $0.songID == id }
        }
        songs.removeAll { $0.id == id }
        explanations.removeAll { $0.songID == id && !(keepPhrases && keptIndexes.contains($0.index)) }
        sessions.removeAll { $0.songID == id }
    }

    /// Commits one line result immediately (ONRQ-9, LOS-3).
    public mutating func commit(_ result: LineResult, songID: UUID, target: String, engineID: String) {
        let t: Translation
        switch result {
        case .translated(let i, let text):
            t = Translation(songID: songID, index: i, targetLanguage: target, engineID: engineID, promptVersion: Prompts.version, text: text, outcome: .translated)
        case .copied(let i):
            t = Translation(songID: songID, index: i, targetLanguage: target, engineID: engineID, promptVersion: Prompts.version, text: nil, outcome: .copied)
        case .failed(let i, _):
            t = Translation(songID: songID, index: i, targetLanguage: target, engineID: engineID, promptVersion: Prompts.version, text: nil, outcome: .failed)
        }
        translations.append(t)
    }

    /// Star toggle (RQ-10/RQ-12). Returns the new saved state.
    @discardableResult
    public mutating func toggleSaved(songID: UUID, index: Int) -> Bool {
        if let i = phrases.firstIndex(where: { $0.songID == songID && $0.index == index }) {
            phrases.remove(at: i)
            return false
        }
        phrases.append(Phrase(songID: songID, index: index))
        return true
    }

    public mutating func cacheExplanation(_ record: ExplanationRecord) {
        explanations.append(record)
    }
}

// MARK: - Persistence

public protocol CollectionRepository: Sendable {
    func load() throws -> CollectionSnapshot
    func save(_ snapshot: CollectionSnapshot) throws
    func deleteAll() throws
}

/// Atomically written JSON file in Application Support.
public struct JSONFileRepository: CollectionRepository {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> CollectionSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return CollectionSnapshot() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.lyrics.decode(CollectionSnapshot.self, from: data)
    }

    public func save(_ snapshot: CollectionSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.lyrics.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public final class InMemoryRepository: CollectionRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CollectionSnapshot

    public init(_ snapshot: CollectionSnapshot = CollectionSnapshot()) {
        stored = snapshot
    }

    public func load() throws -> CollectionSnapshot { lock.withLock { stored } }
    public func save(_ snapshot: CollectionSnapshot) throws { lock.withLock { stored = snapshot } }
    public func deleteAll() throws { lock.withLock { stored = CollectionSnapshot() } }
}

extension JSONEncoder {
    /// Local store encoding: lossless dates.
    public static var lyrics: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// Portable export encoding: ISO-8601 with milliseconds, readable by Android and web.
    public static var portable: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
}

extension JSONDecoder {
    public static var lyrics: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    public static var portable: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(s)"))
        }
        return d
    }
}
