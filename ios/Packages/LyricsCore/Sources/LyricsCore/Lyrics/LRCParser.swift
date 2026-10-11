import Foundation

/// Parsed lyrics, independent of any song record.
public struct LyricsDocument: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public var start: TimeInterval?
        public var end: TimeInterval?
        public var text: String

        public init(start: TimeInterval?, end: TimeInterval? = nil, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var lines: [Line]
    public var type: LyricsType

    public init(lines: [Line], type: LyricsType) {
        self.lines = lines
        self.type = type
    }

    public func lyricLines(songID: UUID) -> [LyricLine] {
        lines.enumerated().map { index, line in
            LyricLine(songID: songID, index: index, start: line.start, end: line.end, text: line.text)
        }
    }
}

/// LRC parsing (SSRD A.III `parseLRC`, RQ-6).
public enum LRCParser {
    /// Text in which at least this share of non-empty lines starts with a time tag is synced (RQ-6).
    public static let syncedThreshold = 0.8

    // Matches [mm:ss], [mm:ss.x], [mm:ss.xx], [mm:ss.xxx] and [mm:ss:xx].
    private static let tagPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#

    /// Parses LRC or plain text. Metadata tags such as [ar:...] are dropped,
    /// multiple time tags on one line are expanded, and lines are sorted by time.
    public static func parse(_ text: String) -> LyricsDocument {
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let nonEmpty = rawLines.filter { !$0.isEmpty && !isMetadataTag($0) }
        guard !nonEmpty.isEmpty else { return LyricsDocument(lines: [], type: .plain) }

        let tagged = nonEmpty.filter { !timeTags(in: $0).isEmpty }
        let isSynced = Double(tagged.count) / Double(nonEmpty.count) >= syncedThreshold

        if !isSynced {
            let lines = nonEmpty.map { LyricsDocument.Line(start: nil, text: stripTags($0)) }
                .filter { !$0.text.isEmpty }
            return LyricsDocument(lines: lines, type: .plain)
        }

        var timed: [(TimeInterval, String)] = []
        for raw in nonEmpty {
            let tags = timeTags(in: raw)
            guard !tags.isEmpty else { continue }
            let body = stripTags(raw)
            for t in tags { timed.append((t, body)) }
        }
        timed.sort { $0.0 < $1.0 }

        // Empty-bodied timed lines mark instrumental gaps: they end the previous line
        // but are not shown as lyric lines themselves.
        var lines: [LyricsDocument.Line] = []
        for (i, entry) in timed.enumerated() {
            let next = i + 1 < timed.count ? timed[i + 1].0 : nil
            if entry.1.isEmpty { continue }
            lines.append(LyricsDocument.Line(start: entry.0, end: next, text: entry.1))
        }
        return LyricsDocument(lines: lines, type: .synced)
    }

    static func timeTags(in line: String) -> [TimeInterval] {
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else { return [] }
        let ns = line as NSString
        var result: [TimeInterval] = []
        var cursor = 0
        // Only leading tags count; "[00:12.34]text [00:15.00]" style inline tags are rare in LRCLIB.
        while cursor < ns.length,
              let m = regex.firstMatch(in: line, range: NSRange(location: cursor, length: ns.length - cursor)),
              m.range.location == cursor {
            let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var fraction = 0.0
            if m.range(at: 3).location != NSNotFound {
                let digits = ns.substring(with: m.range(at: 3))
                fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            }
            result.append(minutes * 60 + seconds + fraction)
            cursor = m.range.location + m.range.length
        }
        return result
    }

    static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isMetadataTag(_ line: String) -> Bool {
        line.range(of: #"^\[(ar|ti|al|by|offset|length|re|ve|au|#):.*\]$"#, options: .regularExpression) != nil
    }

    /// Formats seconds as an LRC tag, e.g. 12.34 → "[00:12.34]".
    public static func tag(for seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "[%02d:%05.2f]", m, s)
    }
}
