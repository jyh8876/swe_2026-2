import Foundation

/// "Conquered" rules (RQ-13). Thresholds are configuration values, tuned after user testing (OI-3).
public struct MasteryRules: Sendable {
    /// A play-through counts when this share of the song's lines was reached with lyrics open.
    public var playThroughShare: Double = 0.9
    /// Suggest "Conquered" after this many play-throughs…
    public var suggestAfterPlayThroughs: Int = 3
    /// …and when explanations were opened for at least this share of distinct lines.
    public var suggestExplanationShare: Double = 0.3

    public init() {}

    public func isPlayThrough(_ session: ListenSession, lineCount: Int) -> Bool {
        guard lineCount > 0 else { return false }
        return Double(session.linesReached.count) / Double(lineCount) >= playThroughShare
    }

    public func playThroughs(songID: UUID, in snapshot: CollectionSnapshot) -> Int {
        let count = snapshot.lines(for: songID).count
        return snapshot.sessions.filter { $0.songID == songID && isPlayThrough($0, lineCount: count) }.count
    }

    /// The action is available after at least one full listen with the lyrics open.
    public func canMarkConquered(songID: UUID, in snapshot: CollectionSnapshot) -> Bool {
        playThroughs(songID: songID, in: snapshot) >= 1
    }

    public func shouldSuggest(songID: UUID, in snapshot: CollectionSnapshot) -> Bool {
        guard let song = snapshot.song(songID), !song.isConquered else { return false }
        let lineCount = snapshot.lines(for: songID).count
        guard lineCount > 0, playThroughs(songID: songID, in: snapshot) >= suggestAfterPlayThroughs else { return false }
        let opened = snapshot.sessions.filter { $0.songID == songID }.reduce(into: Set<Int>()) { $0.formUnion($1.explanationsOpened) }
        return Double(opened.count) / Double(lineCount) >= suggestExplanationShare
    }
}
