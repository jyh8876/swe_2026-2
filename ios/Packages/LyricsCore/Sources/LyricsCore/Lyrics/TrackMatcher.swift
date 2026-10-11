import Foundation

/// Title/artist normalisation for matching noisy now-playing metadata (RQ-3, ONRQ-4).
public enum TrackNormalizer {
    private static let noiseTags = [
        "official music video", "official video", "official audio", "official mv", "official",
        "lyric video", "lyrics", "lyric", "mv", "m/v", "audio", "remastered", "remaster",
        "radio edit", "explicit", "hd", "4k",
    ]

    /// Lowercases, strips bracketed tags, "feat." clauses, noise words, and punctuation.
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Remove bracketed segments: (...) [...] {...}
        t = t.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        // Remove "feat." / "ft." / "featuring" clauses to the end.
        t = t.replacingOccurrences(of: #"\b(feat\.?|ft\.?|featuring)\s.*$"#, with: " ", options: .regularExpression)
        // Remove " - 2011 Remaster" style suffixes.
        t = t.replacingOccurrences(of: #"\s-\s.*\b(remaster(ed)?|version|edit|live)\b.*$"#, with: " ", options: .regularExpression)
        for tag in noiseTags {
            t = t.replacingOccurrences(of: #"\b\#(NSRegularExpression.escapedPattern(for: tag))\b"#, with: " ", options: .regularExpression)
        }
        // Keep letters (any script) and digits.
        t = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        return t.split(separator: " ").joined(separator: " ")
    }

    /// "Coldplay/Coldplay", "A, B & C" → first artist (SIR-7).
    public static func primaryArtist(_ artist: String) -> String {
        let separators = CharacterSet(charactersIn: "/,&;")
        let first = artist.components(separatedBy: separators).first ?? artist
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// Splits a YouTube-style title "Artist - Song (Official MV)" into (artist, title).
    public static func splitArtistTitle(_ s: String) -> (artist: String, title: String)? {
        let parts = s.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        return (parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
    }
}

/// Matching rule: normalised title + primary artist, and duration within ±2 s when both known (RQ-3).
public enum TrackMatcher {
    public static let durationTolerance: TimeInterval = 2

    public static func matches(_ a: TrackKey, _ b: TrackKey) -> Bool {
        guard TrackNormalizer.normalize(a.title) == TrackNormalizer.normalize(b.title) else { return false }
        let artistA = TrackNormalizer.normalize(TrackNormalizer.primaryArtist(a.artist))
        let artistB = TrackNormalizer.normalize(TrackNormalizer.primaryArtist(b.artist))
        guard artistA == artistB || artistA.contains(artistB) || artistB.contains(artistA) else { return false }
        if let da = a.duration, let db = b.duration {
            return abs(da - db) <= durationTolerance
        }
        return true
    }

    /// Finds the collection song for the playing track; retries with a split "Artist - Title" (ONRQ-4).
    public static func match(_ playing: TrackKey, in songs: [Song]) -> Song? {
        if let hit = songs.first(where: { matches($0.trackKey, playing) }) { return hit }
        if let split = TrackNormalizer.splitArtistTitle(playing.title) {
            let retry = TrackKey(title: split.title, artist: split.artist, duration: playing.duration)
            return songs.first { matches($0.trackKey, retry) }
        }
        return nil
    }

    /// Ranks lyrics candidates: synced first, then closest duration; >2 s off is ranked last (ONRQ-2).
    public static func rank(_ candidates: [LyricsCandidate], for track: TrackKey) -> [LyricsCandidate] {
        func score(_ c: LyricsCandidate) -> (Int, Int, Double) {
            let delta = (c.duration.flatMap { d in track.duration.map { abs(d - $0) } }) ?? 0
            let offVersion = delta > durationTolerance ? 1 : 0
            let syncRank = c.hasSynced ? 0 : (c.hasPlain ? 1 : 2)
            return (offVersion, syncRank, delta)
        }
        return candidates.sorted { score($0) < score($1) }
    }
}
