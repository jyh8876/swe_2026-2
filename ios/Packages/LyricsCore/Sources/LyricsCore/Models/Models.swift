import Foundation

// Core data model — SSRD Appendix A.III "Core data model".
// The same field names are used in the export schema (RQ-18).

public enum LyricsType: String, Codable, Sendable, Hashable {
    case synced
    case plain
}

public enum SongStatus: String, Codable, Sendable, Hashable {
    case translating
    case done
    case failed
}

public struct Song: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var album: String?
    /// Track duration in seconds.
    public var duration: TimeInterval?
    /// Path relative to the app's covers directory. Covers are never uploaded (RQ-6).
    public var coverPath: String?
    public var lyricsType: LyricsType
    /// Where the lyrics came from, for example "lrclib" or "manual".
    public var sourceProvider: String
    /// Per-song timing offset in seconds (RQ-10). Positive = lyrics shown later.
    public var offset: TimeInterval
    public var status: SongStatus
    public var conqueredAt: Date?
    public var addedAt: Date
    public var curatedShelfID: String?

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        coverPath: String? = nil,
        lyricsType: LyricsType,
        sourceProvider: String,
        offset: TimeInterval = 0,
        status: SongStatus = .translating,
        conqueredAt: Date? = nil,
        addedAt: Date = Date(),
        curatedShelfID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverPath = coverPath
        self.lyricsType = lyricsType
        self.sourceProvider = sourceProvider
        self.offset = offset
        self.status = status
        self.conqueredAt = conqueredAt
        self.addedAt = addedAt
        self.curatedShelfID = curatedShelfID
    }

    public var isConquered: Bool { conqueredAt != nil }
    public var trackKey: TrackKey { TrackKey(title: title, artist: artist, album: album, duration: duration) }
}

public struct LyricLine: Codable, Sendable, Hashable, Identifiable {
    public var songID: UUID
    public var index: Int
    /// Start time in seconds; nil for plain lyrics.
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var text: String
    /// BCP-47 code detected on the device (RQ-15), nil until detected.
    public var detectedLanguage: String?

    public var id: String { "\(songID.uuidString)#\(index)" }

    public init(songID: UUID, index: Int, start: TimeInterval?, end: TimeInterval? = nil, text: String, detectedLanguage: String? = nil) {
        self.songID = songID
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.detectedLanguage = detectedLanguage
    }
}

public struct Translation: Codable, Sendable, Hashable {
    public var songID: UUID
    public var index: Int
    public var targetLanguage: String
    public var engineID: String
    public var promptVersion: String
    /// Translated text. Nil when the line was copied (already in the target language) or failed.
    public var text: String?
    public var outcome: Outcome
    public var createdAt: Date

    public enum Outcome: String, Codable, Sendable, Hashable {
        case translated
        case copied
        case failed
    }

    public init(songID: UUID, index: Int, targetLanguage: String, engineID: String, promptVersion: String, text: String?, outcome: Outcome, createdAt: Date = Date()) {
        self.songID = songID
        self.index = index
        self.targetLanguage = targetLanguage
        self.engineID = engineID
        self.promptVersion = promptVersion
        self.text = text
        self.outcome = outcome
        self.createdAt = createdAt
    }
}

public struct Expression: Codable, Sendable, Hashable {
    public var phrase: String
    public var meaning: String

    public init(phrase: String, meaning: String) {
        self.phrase = phrase
        self.meaning = meaning
    }
}

/// Structured line explanation (RQ-11). At most 3 expressions (Win-AGRE-7).
public struct Explanation: Codable, Sendable, Hashable {
    public var expressions: [Expression]
    public var structure: String
    public var usage: String
    public var example: String

    public static let maxExpressions = 3

    public init(expressions: [Expression], structure: String, usage: String, example: String) {
        self.expressions = Array(expressions.prefix(Self.maxExpressions))
        self.structure = structure
        self.usage = usage
        self.example = example
    }
}

public struct ExplanationRecord: Codable, Sendable, Hashable {
    public var songID: UUID
    public var index: Int
    public var targetLanguage: String
    public var engineID: String
    public var promptVersion: String
    public var explanation: Explanation
    public var createdAt: Date

    public init(songID: UUID, index: Int, targetLanguage: String, engineID: String, promptVersion: String, explanation: Explanation, createdAt: Date = Date()) {
        self.songID = songID
        self.index = index
        self.targetLanguage = targetLanguage
        self.engineID = engineID
        self.promptVersion = promptVersion
        self.explanation = explanation
        self.createdAt = createdAt
    }
}

public struct Phrase: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var songID: UUID
    public var index: Int
    public var savedAt: Date

    public init(id: UUID = UUID(), songID: UUID, index: Int, savedAt: Date = Date()) {
        self.id = id
        self.songID = songID
        self.index = index
        self.savedAt = savedAt
    }
}

/// One study session with the lyrics open; drives the mastery suggestion (RQ-13).
public struct ListenSession: Codable, Sendable, Hashable {
    public var songID: UUID
    public var startedAt: Date
    public var linesReached: Set<Int>
    public var explanationsOpened: Set<Int>

    public init(songID: UUID, startedAt: Date = Date(), linesReached: Set<Int> = [], explanationsOpened: Set<Int> = []) {
        self.songID = songID
        self.startedAt = startedAt
        self.linesReached = linesReached
        self.explanationsOpened = explanationsOpened
    }
}

/// Identity of a track used for lyrics lookup and matching.
public struct TrackKey: Codable, Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// A target or source language. Adding a language is a configuration entry (LOS-14).
public struct Language: Codable, Sendable, Hashable, Identifiable {
    public var code: String
    public var englishName: String
    public var nativeName: String

    public var id: String { code }

    public init(code: String, englishName: String, nativeName: String) {
        self.code = code
        self.englishName = englishName
        self.nativeName = nativeName
    }

    public static let korean = Language(code: "ko", englishName: "Korean", nativeName: "한국어")
    public static let english = Language(code: "en", englishName: "English", nativeName: "English")
    public static let japanese = Language(code: "ja", englishName: "Japanese", nativeName: "日本語")
    public static let spanish = Language(code: "es", englishName: "Spanish", nativeName: "Español")

    public static let supported: [Language] = [.korean, .english, .japanese, .spanish]

    public static func named(_ code: String) -> Language {
        supported.first { $0.code == code } ?? Language(code: code, englishName: code, nativeName: code)
    }
}
