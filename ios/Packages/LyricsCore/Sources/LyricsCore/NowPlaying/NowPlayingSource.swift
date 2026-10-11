import Foundation

public enum SourceID: String, Codable, Sendable, Hashable, CaseIterable {
    case spotify
    case appleMusic
    case simulator
    // 2027: androidSession, spotifyWeb
}

public enum SourceCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case read
    case playPause
    case skip
    case seek
}

/// A position report from a playback source.
public struct PlaybackSnapshot: Sendable, Hashable {
    public var track: TrackKey
    /// Playback position in seconds at `reportedAt`.
    public var position: TimeInterval
    public var reportedAt: Date
    public var rate: Double
    public var isPlaying: Bool

    public init(track: TrackKey, position: TimeInterval, reportedAt: Date = Date(), rate: Double = 1, isPlaying: Bool) {
        self.track = track
        self.position = position
        self.reportedAt = reportedAt
        self.rate = rate
        self.isPlaying = isPlaying
    }
}

public enum SourceError: Error, Equatable, Sendable {
    case unsupported(SourceCapability)
    case notConnected
    case notInstalled
    case premiumRequired
    case permissionDenied
}

/// SSRD A.III `NowPlayingSource`. One adapter per source, each declaring its capabilities.
/// Commands complete when the source acknowledges, or throw `SourceError.unsupported`.
public protocol NowPlayingSource: AnyObject, Sendable {
    var id: SourceID { get }
    var capabilities: Set<SourceCapability> { get }
    var snapshots: AsyncStream<PlaybackSnapshot> { get }

    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(to position: TimeInterval) async throws
}

/// A fake source that "plays" a track on a timer. Used in the simulator, previews,
/// on the Mac, as a mock Spotify / Apple Music link, and for demos where no Spotify/Apple Music link is possible.
public final class SimulatedSource: NowPlayingSource, @unchecked Sendable {
    public let id: SourceID
    public let capabilities: Set<SourceCapability> = Set(SourceCapability.allCases)

    private let lock = NSLock()
    private var track: TrackKey
    private var anchorPosition: TimeInterval = 0
    private var anchorDate = Date()
    private var isPlaying = false
    private var continuations: [UUID: AsyncStream<PlaybackSnapshot>.Continuation] = [:]

    /// `id` lets the simulator stand in for Spotify or Apple Music when the real link
    /// is unavailable (no SDK, iOS Simulator, Mac), so every connected-state screen can be tried.
    public init(track: TrackKey, id: SourceID = .simulator) {
        self.track = track
        self.id = id
    }

    public var snapshots: AsyncStream<PlaybackSnapshot> {
        AsyncStream { continuation in
            let token = UUID()
            lock.withLock { continuations[token] = continuation }
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: token) }
            }
        }
    }

    public func load(_ track: TrackKey, autoplay: Bool = true) {
        lock.withLock {
            self.track = track
            anchorPosition = 0
            anchorDate = Date()
            isPlaying = autoplay
        }
        broadcast()
    }

    public func play() async throws {
        lock.withLock {
            anchorDate = Date()
            isPlaying = true
        }
        broadcast()
    }

    public func pause() async throws {
        lock.withLock {
            anchorPosition = positionLocked()
            anchorDate = Date()
            isPlaying = false
        }
        broadcast()
    }

    public func next() async throws { try await seek(to: 0) }
    public func previous() async throws { try await seek(to: 0) }

    public func seek(to position: TimeInterval) async throws {
        lock.withLock {
            anchorPosition = max(0, position)
            anchorDate = Date()
        }
        broadcast()
    }

    private func positionLocked() -> TimeInterval {
        let p = isPlaying ? anchorPosition + Date().timeIntervalSince(anchorDate) : anchorPosition
        if let d = track.duration { return min(p, d) }
        return p
    }

    private func currentSnapshot() -> PlaybackSnapshot {
        lock.withLock {
            PlaybackSnapshot(track: track, position: positionLocked(), reportedAt: Date(), rate: 1, isPlaying: isPlaying)
        }
    }

    private func broadcast() {
        let snap = currentSnapshot()
        let targets = lock.withLock { Array(continuations.values) }
        targets.forEach { $0.yield(snap) }
    }
}
