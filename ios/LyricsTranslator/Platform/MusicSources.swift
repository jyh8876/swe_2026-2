import Foundation
import LyricsCore
#if os(iOS)
import MediaPlayer
#endif

// MARK: - Apple Music (SIR-6)

/// Reads now-playing from the system music player and controls it.
/// Works only for playback in Apple's Music app. Position is polled (SSRD 3.1.2).
final class AppleMusicSource: NowPlayingSource, @unchecked Sendable {
    let id: SourceID = .appleMusic
    let capabilities: Set<SourceCapability> = [.read, .playPause, .skip, .seek]

    #if os(iOS)
    private let player = MPMusicPlayerController.systemMusicPlayer
    #endif

    /// On a real iPhone this links to the Music app. In the iOS Simulator and on the Mac
    /// (no system music player) it returns a mock link so connected-state UI can be tested.
    static func connect(mockTrack: TrackKey) async throws -> any NowPlayingSource {
        #if os(iOS) && !targetEnvironment(simulator)
        let status = await withCheckedContinuation { (c: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw SourceError.permissionDenied }
        return AppleMusicSource()
        #else
        return MockMusicLink.make(.appleMusic, track: mockTrack)
        #endif
    }

    var snapshots: AsyncStream<PlaybackSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor [self] in
                #if os(iOS)
                self.player.beginGeneratingPlaybackNotifications()
                defer { self.player.endGeneratingPlaybackNotifications() }
                while !Task.isCancelled {
                    if let item = self.player.nowPlayingItem {
                        let track = TrackKey(
                            title: item.title ?? "",
                            artist: item.artist ?? "",
                            album: item.albumTitle,
                            duration: item.playbackDuration
                        )
                        continuation.yield(PlaybackSnapshot(
                            track: track,
                            position: self.player.currentPlaybackTime,
                            reportedAt: Date(),
                            rate: Double(self.player.currentPlaybackRate == 0 ? 1 : self.player.currentPlaybackRate),
                            isPlaying: self.player.playbackState == .playing
                        ))
                    }
                    // The Sync Engine extrapolates between polls; 0.5 s keeps LOS-1 with low battery cost.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func play() async throws {
        #if os(iOS)
        await MainActor.run { self.player.play() }
        #endif
    }

    func pause() async throws {
        #if os(iOS)
        await MainActor.run { self.player.pause() }
        #endif
    }

    func next() async throws {
        #if os(iOS)
        await MainActor.run { self.player.skipToNextItem() }
        #endif
    }

    func previous() async throws {
        #if os(iOS)
        await MainActor.run { self.player.skipToPreviousItem() }
        #endif
    }

    func seek(to position: TimeInterval) async throws {
        #if os(iOS)
        await MainActor.run { self.player.currentPlaybackTime = position }
        #endif
    }
}

// MARK: - Spotify (SIR-5)

/// Spotify App Remote adapter.
///
/// The Spotify iOS SDK (SpotifyiOS.xcframework) is not vendored in this prototype: it is
/// distributed as a binary that must be downloaded from Spotify and registered with a client
/// ID on the developer dashboard (Development Mode allowlist). Integration steps live in
/// README.md → "Spotify". Until then, `connect()` returns a mock link (see `MockMusicLink`).
final class SpotifySource: NowPlayingSource, @unchecked Sendable {
    let id: SourceID = .spotify
    let capabilities: Set<SourceCapability> = [.read, .playPause, .skip, .seek]

    /// Redirect URI registered on the Spotify dashboard and in Info.plist URL types.
    static let redirectURI = URL(string: "lyricstranslator://spotify-callback")!
    /// Set in Config/Secrets.xcconfig (git-ignored). No client secret is shipped (PKCE).
    static var clientID: String { Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "" }

    static func connect(mockTrack: TrackKey) async throws -> any NowPlayingSource {
        #if canImport(SpotifyiOS)
        // TODO(Iteration 1): SPTConfiguration(clientID:redirectURL:), SPTSessionManager PKCE,
        // then SPTAppRemote connect; store refresh token in KeychainSecureStore (.spotifyRefreshToken).
        return SpotifySource()
        #else
        return MockMusicLink.make(.spotify, track: mockTrack)
        #endif
    }

    var snapshots: AsyncStream<PlaybackSnapshot> {
        AsyncStream { $0.finish() }
    }

    func play() async throws { throw SourceError.notConnected }
    func pause() async throws { throw SourceError.notConnected }
    func next() async throws { throw SourceError.notConnected }
    func previous() async throws { throw SourceError.notConnected }
    func seek(to position: TimeInterval) async throws { throw SourceError.notConnected }
}

// MARK: - Mock link (UI testing without SDKs or a device)

/// A simulated player that reports itself as Spotify or Apple Music. It "plays" the given track
/// on a timer, so the now-playing bar, synced lyrics and transport controls all work.
enum MockMusicLink {
    static func make(_ id: SourceID, track: TrackKey) -> SimulatedSource {
        let source = SimulatedSource(track: track, id: id)
        source.load(track)
        return source
    }
}
