import Foundation

/// Progress of a whole-song pre-translation (FG-04).
public struct TranslationProgress: Sendable, Hashable {
    public enum Stage: Int, Sendable, Hashable, CaseIterable {
        case fetchLyrics
        case translate
        case save
    }

    public var done: Int
    public var total: Int
    public var stage: Stage
    /// Estimated seconds remaining, nil until the first line completes.
    public var eta: TimeInterval?
    public var firstLinePreview: String?

    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
}

/// Runs a full-song pre-translation (RQ-7). Lines that already have a successful translation
/// for this target are skipped, so a restarted job only processes what is left.
public struct TranslationJob: Sendable {
    public let songID: UUID
    public let lines: [LyricLine]
    public let target: Language
    public let engine: any Translator

    public init(songID: UUID, lines: [LyricLine], target: Language, engine: any Translator) {
        self.songID = songID
        self.lines = lines
        self.target = target
        self.engine = engine
    }

    /// - Parameters:
    ///   - alreadyDone: indexes that need no work.
    ///   - commit: called for every finished line before progress is reported (per-line commit).
    ///   - progress: progress updates for the UI.
    public func run(
        alreadyDone: Set<Int>,
        commit: @Sendable (LineResult) async -> Void,
        progress: @Sendable (TranslationProgress) async -> Void
    ) async throws {
        let pending = lines.filter { !alreadyDone.contains($0.index) }
        let total = lines.count
        var done = total - pending.count
        var firstPreview: String?
        let started = Date()

        await progress(TranslationProgress(done: done, total: total, stage: .translate, eta: nil, firstLinePreview: nil))
        guard !pending.isEmpty else {
            await progress(TranslationProgress(done: total, total: total, stage: .save, eta: 0, firstLinePreview: nil))
            return
        }

        var seen = Set<Int>()
        for try await result in engine.translateSong(pending, to: target) {
            guard seen.insert(result.index).inserted else { continue }
            await commit(result)
            done += 1
            if firstPreview == nil, case .translated(_, let text) = result { firstPreview = text }
            let processed = seen.count
            let perLine = Date().timeIntervalSince(started) / Double(processed)
            let eta = perLine * Double(pending.count - processed)
            await progress(TranslationProgress(done: done, total: total, stage: .translate, eta: eta, firstLinePreview: firstPreview))
        }

        // A cancelled job (app backgrounded, ONRQ-9) resumes later; it must not mark lines failed.
        try Task.checkCancellation()

        // Every line must be accounted for (LOS-2): anything the engine skipped is marked failed.
        for line in pending where !seen.contains(line.index) {
            await commit(.failed(index: line.index, reason: "missing"))
        }
        await progress(TranslationProgress(done: total, total: total, stage: .save, eta: 0, firstLinePreview: firstPreview))
    }
}
