import Foundation

/// Turns sparse position reports into a smooth playhead and decides which line is current (LOS-1).
/// position(now) = anchor.position + (now − anchor.reportedAt) × rate, re-anchored on every report.
public struct SyncEngine: Sendable {
    public private(set) var anchor: PlaybackSnapshot?
    /// Per-song offset in seconds (RQ-10). Positive = lyrics appear later.
    public var offset: TimeInterval

    public init(offset: TimeInterval = 0) {
        self.offset = offset
    }

    /// Re-anchors on every state change (ONRQ-15).
    public mutating func update(_ snapshot: PlaybackSnapshot) {
        anchor = snapshot
    }

    public func position(at now: Date = Date()) -> TimeInterval? {
        guard let anchor else { return nil }
        guard anchor.isPlaying else { return anchor.position }
        let elapsed = max(0, now.timeIntervalSince(anchor.reportedAt))
        var p = anchor.position + elapsed * anchor.rate
        if let d = anchor.track.duration { p = min(p, d) }
        return p
    }

    /// Index of the line whose start ≤ (position − offset), or nil before the first line
    /// or for plain lyrics.
    public func currentLineIndex(in lines: [LyricLine], at now: Date = Date()) -> Int? {
        guard let p = position(at: now) else { return nil }
        return Self.lineIndex(for: p - offset, in: lines)
    }

    /// Binary search over line starts. Lines must be sorted by start.
    public static func lineIndex(for position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first?.start, position >= first else { return nil }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let s = lines[mid].start, s <= position {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// Where to seek to land on a line, taking the per-song offset into account (RQ-4).
    public func seekTarget(for line: LyricLine) -> TimeInterval? {
        line.start.map { max(0, $0 + offset) }
    }

    /// Offset step used by the player's timing control (RQ-10; OI-4 may make it finer).
    public static let offsetStep: TimeInterval = 0.5
}
