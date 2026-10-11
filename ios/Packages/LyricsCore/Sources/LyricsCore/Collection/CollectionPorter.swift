import Foundation

/// Portable, versioned export file (RQ-18). Android and web will read the same schema.
public struct ExportDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var app: String
    public var collection: CollectionSnapshot
}

public struct ImportReport: Sendable, Hashable {
    public var songsAdded: Int
    public var songsUpdated: Int
    public var phrasesAdded: Int
}

public enum ImportError: Error, Equatable, Sendable {
    case invalidFile
    case newerSchema(Int)
}

/// SSRD A.III `CollectionPorter`.
public protocol CollectionPorter {
    func export() throws -> Data
    func `import`(_ data: Data) throws -> ImportReport
}

public enum CollectionMerger {
    public static func export(_ snapshot: CollectionSnapshot, now: Date = Date()) throws -> Data {
        let doc = ExportDocument(schemaVersion: ExportDocument.currentSchemaVersion, exportedAt: now, app: "LyricsTranslator", collection: snapshot)
        return try JSONEncoder.portable.encode(doc)
    }

    /// Validates the schema version first; an invalid or newer file changes nothing (ONRQ-16).
    public static func decode(_ data: Data) throws -> ExportDocument {
        struct Header: Decodable { let schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw ImportError.invalidFile }
        guard header.schemaVersion <= ExportDocument.currentSchemaVersion else { throw ImportError.newerSchema(header.schemaVersion) }
        guard let doc = try? JSONDecoder.portable.decode(ExportDocument.self, from: data) else { throw ImportError.invalidFile }
        return doc
    }

    /// Merge rule (ONRQ-16): union of songs and phrases; for the same record the most recent
    /// change wins; nothing is deleted by a merge.
    public static func merge(_ incoming: CollectionSnapshot, into base: inout CollectionSnapshot) -> ImportReport {
        var report = ImportReport(songsAdded: 0, songsUpdated: 0, phrasesAdded: 0)

        for song in incoming.songs {
            if let i = base.songs.firstIndex(where: { $0.id == song.id }) {
                // Most recent wins: conquered state and offset are the user-editable fields.
                if (song.conqueredAt ?? .distantPast) > (base.songs[i].conqueredAt ?? .distantPast) || song.status == .done && base.songs[i].status != .done {
                    base.songs[i] = song
                    report.songsUpdated += 1
                }
            } else {
                base.songs.append(song)
                report.songsAdded += 1
            }
        }

        let existingLines = Set(base.lines.map(\.id))
        base.lines += incoming.lines.filter { !existingLines.contains($0.id) }

        func translationKey(_ t: Translation) -> String { "\(t.songID)#\(t.index)#\(t.targetLanguage)#\(t.engineID)#\(t.promptVersion)#\(Int((t.createdAt.timeIntervalSince1970 * 1000).rounded()))" }
        let existingTranslations = Set(base.translations.map(translationKey))
        base.translations += incoming.translations.filter { !existingTranslations.contains(translationKey($0)) }

        func explanationKey(_ e: ExplanationRecord) -> String { "\(e.songID)#\(e.index)#\(e.targetLanguage)#\(e.engineID)#\(e.promptVersion)" }
        let existingExplanations = Set(base.explanations.map(explanationKey))
        base.explanations += incoming.explanations.filter { !existingExplanations.contains(explanationKey($0)) }

        for phrase in incoming.phrases where !base.phrases.contains(where: { $0.songID == phrase.songID && $0.index == phrase.index }) {
            base.phrases.append(phrase)
            report.phrasesAdded += 1
        }

        base.sessions += incoming.sessions.filter { s in
            !base.sessions.contains { $0.songID == s.songID && abs($0.startedAt.timeIntervalSince(s.startedAt)) < 0.001 }
        }
        return report
    }
}
