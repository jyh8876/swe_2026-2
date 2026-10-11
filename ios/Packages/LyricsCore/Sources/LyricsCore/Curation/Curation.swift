import Foundation

/// Curated song shelves (RQ-17). A versioned JSON file bundled with the app; Android and web
/// reuse it unchanged. After December it may also be served from free static hosting.
public struct ShelfFile: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var updatedAt: String
    public var shelves: [CuratedShelf]
}

public struct CuratedShelf: Codable, Sendable, Hashable, Identifiable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var title: String
        public var artist: String
        public var duration: TimeInterval?

        public var id: String { "\(artist)—\(title)" }
        public var trackKey: TrackKey { TrackKey(title: title, artist: artist, duration: duration) }
    }

    public var id: String
    public var title: String
    public var subtitle: String
    public var songs: [Entry]
}

public enum Curation {
    public static func bundledShelves() -> [CuratedShelf] {
        guard let url = Bundle.module.url(forResource: "curated_shelves", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ShelfFile.self, from: data) else { return [] }
        return file.shelves
    }
}

/// Offline demo content so the prototype runs end-to-end in the simulator, on the Mac,
/// and with no network. Lyrics are original text written for this prototype.
public enum DemoContent {
    public static let songTitle = "Day-Off"
    public static let songArtist = "Team 9"

    public static let lrc = """
    [00:05.00]Wake up, the city's humming low
    [00:09.20]I've been running on empty since the summer show
    [00:13.80]But you said take it easy, let it go
    [00:18.10]So I'm calling it a day-off, nowhere to go
    [00:22.60]
    [00:24.00]No alarms, no deadlines on my mind
    [00:28.30]Leave the rush hour traffic far behind
    [00:32.70]We could talk until the sun goes down
    [00:37.00]Just you and me against this sleepy town
    [00:41.50]Hit pause on everything, it's fine
    [00:45.80]Today the whole world can wait in line
    """

    public static let candidate = LyricsCandidate(
        id: -1,
        trackName: songTitle,
        artistName: songArtist,
        albumName: "Prototype",
        duration: 52,
        instrumental: false,
        plainLyrics: LRCParser.parse(lrc).lines.map(\.text).joined(separator: "\n"),
        syncedLyrics: lrc
    )

    public static let plainOnly = LyricsCandidate(
        id: -2, trackName: "Quiet Room", artistName: "Team 9", albumName: "Prototype", duration: 120,
        plainLyrics: "Lights are low in the quiet room\nEvery word you say is a little too soon", syncedLyrics: nil)

    public static let noLyrics = LyricsCandidate(
        id: -3, trackName: "Instrumental Interlude", artistName: "Team 9", albumName: "Prototype", duration: 90, instrumental: true)

    public static var candidates: [LyricsCandidate] { [candidate, plainOnly, noLyrics] }
}
