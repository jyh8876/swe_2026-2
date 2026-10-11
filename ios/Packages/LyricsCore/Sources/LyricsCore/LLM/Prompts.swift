import Foundation

/// Prompt templates. Versioned: translations and explanations are keyed by prompt version,
/// so changing a prompt never overwrites earlier results (A.III data model).
public enum Prompts {
    public static let version = "p1"

    public static func translationSystem(target: Language) -> String {
        """
        You translate song lyrics for language learners.
        Translate each numbered line into natural, idiomatic \(target.englishName) (\(target.code)).
        Rules:
        - Keep the meaning, tone and register of the song; prefer natural phrasing over literal word order.
        - Use the surrounding lines as context for pronouns, tense and slang.
        - Return exactly one entry per input index. Never merge or split lines.
        - If a line is already in \(target.englishName), return it with "copy": true and no translation.
        - Do not censor the original meaning.
        Respond only with JSON: {"lines":[{"i":0,"t":"..."},{"i":1,"copy":true}]}
        """
    }

    public static func translationUser(_ lines: [LyricLine]) -> String {
        lines.map { "\($0.index)\t\($0.text)" }.joined(separator: "\n")
    }

    public static func explanationSystem(target: Language) -> String {
        """
        You explain one line of song lyrics to a learner whose native language is \(target.englishName).
        Write every field in \(target.englishName). Quote original expressions as they appear in the lyric.
        Pick at most 3 key expressions, ranked by learning value (slang and idioms first).
        Respond only with JSON:
        {"expressions":[{"phrase":"...","meaning":"..."}],"structure":"one line","usage":"when to use it","example":"an example sentence"}
        """
    }

    public static func explanationUser(line: LyricLine, context: [LyricLine]) -> String {
        let ctx = context.map { ($0.index == line.index ? "> " : "  ") + $0.text }.joined(separator: "\n")
        return "Stanza:\n\(ctx)\n\nExplain the line marked with >:\n\(line.text)"
    }

    /// Stanza-sized context window around a line (RQ-7: "translated with its surrounding stanza").
    public static func context(for line: LyricLine, in lines: [LyricLine], radius: Int = 3) -> [LyricLine] {
        let lo = max(0, line.index - radius)
        let hi = min(lines.count - 1, line.index + radius)
        guard lo <= hi else { return [line] }
        return Array(lines[lo...hi])
    }
}

/// Decoding and validation of model output (ONRQ-12).
public enum OutputValidator {
    struct TranslationPayload: Decodable {
        struct Entry: Decodable {
            let i: Int
            let t: String?
            let copy: Bool?
        }
        let lines: [Entry]
    }

    /// Extracts the first JSON object from model text (models sometimes wrap it in prose or fences).
    public static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    /// Maps raw model output to per-line results. Every input index is accounted for:
    /// missing, empty, or repeated-garbage lines become `.failed` so they can be retried (LOS-2).
    public static func translationResults(from text: String, lines: [LyricLine]) -> [LineResult] {
        let byIndex: [Int: TranslationPayload.Entry]
        if let json = extractJSON(text),
           let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(TranslationPayload.self, from: data) {
            byIndex = Dictionary(payload.lines.map { ($0.i, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            byIndex = [:]
        }

        return lines.map { line in
            guard let entry = byIndex[line.index] else {
                return .failed(index: line.index, reason: "missing")
            }
            if entry.copy == true { return .copied(index: line.index) }
            let t = (entry.t ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return .failed(index: line.index, reason: "empty") }
            if isDegenerate(t) { return .failed(index: line.index, reason: "repetition") }
            return .translated(index: line.index, text: t)
        }
    }

    public static func explanation(from text: String) throws -> Explanation {
        guard let json = extractJSON(text), let data = json.data(using: .utf8) else {
            throw LLMError.malformedOutput("no JSON")
        }
        do {
            let e = try JSONDecoder().decode(Explanation.self, from: data)
            guard !e.structure.isEmpty || !e.expressions.isEmpty else { throw LLMError.malformedOutput("empty") }
            return Explanation(expressions: e.expressions, structure: e.structure, usage: e.usage, example: e.example)
        } catch let e as LLMError {
            throw e
        } catch {
            throw LLMError.malformedOutput("schema")
        }
    }

    /// Detects runaway repetition such as "la la la la la la la la" produced by small models.
    static func isDegenerate(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard words.count >= 8 else { return false }
        return Set(words).count * 4 < words.count
    }
}
