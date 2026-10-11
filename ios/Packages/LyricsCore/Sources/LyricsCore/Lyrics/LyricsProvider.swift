import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A lyrics search result. `hasSynced` / `hasPlain` drive the badges in search (RQ-5).
public struct LyricsCandidate: Identifiable, Codable, Sendable, Hashable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: TimeInterval?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(id: Int, trackName: String, artistName: String, albumName: String? = nil, duration: TimeInterval? = nil, instrumental: Bool = false, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    public var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
    public var hasPlain: Bool { !(plainLyrics ?? "").isEmpty }

    public enum Availability: String, Sendable {
        case synced, plain, none
    }

    /// Badge state; exactly reflects syncedLyrics / plainLyrics presence (RQ-5).
    public var availability: Availability {
        if hasSynced { return .synced }
        if hasPlain { return .plain }
        return .none
    }

    /// Best lyrics text for parsing: synced if present, else plain.
    public var bestLyricsText: String? {
        hasSynced ? syncedLyrics : (hasPlain ? plainLyrics : nil)
    }

    public var trackKey: TrackKey {
        TrackKey(title: trackName, artist: artistName, album: albumName, duration: duration)
    }
}

/// SSRD A.III `LyricsProvider`.
public protocol LyricsProvider: Sendable {
    func search(_ query: String) async throws -> [LyricsCandidate]
    func lyrics(for track: TrackKey) async throws -> LyricsCandidate?
}

public enum LyricsError: Error, Equatable, Sendable {
    case offline
    case http(Int)
    case decoding
}

/// LRCLIB adapter (SIR-7). Plain HTTPS GET, no key; polite User-Agent; results cached in memory.
public final class LRCLIBClient: LyricsProvider, @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String
    private let cache = NSCache<NSString, CacheBox>()

    private final class CacheBox {
        let value: [LyricsCandidate]
        init(_ value: [LyricsCandidate]) { self.value = value }
    }

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://lrclib.net/api")!,
        userAgent: String = "LyricsTranslator/0.1 (https://github.com/team9/lyricstranslator)"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    public func search(_ query: String) async throws -> [LyricsCandidate] {
        let key = "search:\(query.lowercased())" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let results: [LyricsCandidate] = try await get(components.url!)
        cache.setObject(CacheBox(results), forKey: key)
        return results
    }

    public func lyrics(for track: TrackKey) async throws -> LyricsCandidate? {
        var components = URLComponents(url: baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: TrackNormalizer.primaryArtist(track.artist)),
        ]
        if let album = track.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = track.duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components.queryItems = items
        do {
            let candidate: LyricsCandidate = try await get(components.url!)
            return candidate
        } catch LyricsError.http(404) {
            return nil
        }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LyricsError.offline
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LyricsError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LyricsError.decoding
        }
    }
}

/// Offline provider backed by fixtures; used by previews, tests and the demo mode.
public struct StaticLyricsProvider: LyricsProvider {
    public var candidates: [LyricsCandidate]

    public init(candidates: [LyricsCandidate]) {
        self.candidates = candidates
    }

    public func search(_ query: String) async throws -> [LyricsCandidate] {
        let q = TrackNormalizer.normalize(query)
        guard !q.isEmpty else { return [] }
        return candidates.filter {
            let hay = TrackNormalizer.normalize("\($0.trackName) \($0.artistName)")
            return q.split(separator: " ").allSatisfy { hay.contains($0) }
        }
    }

    public func lyrics(for track: TrackKey) async throws -> LyricsCandidate? {
        candidates.first { TrackMatcher.matches($0.trackKey, track) }
    }
}
