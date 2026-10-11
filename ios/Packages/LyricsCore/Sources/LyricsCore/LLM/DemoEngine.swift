import Foundation

/// Deterministic stand-in engine for the prototype, previews, the simulator and tests.
/// It lets the full add → translate → study loop run before spike S1 picks the real
/// on-device engine (llama.cpp vs. Apple Foundation Models, Win-AGRE-4).
public struct DemoEngine: TranslationEngine {
    public var id: String { "demo@\(Prompts.version)" }
    public var isAvailable: Bool { true }
    public var kind: EngineKind { .onDevice }

    /// Simulated per-line latency so progress UI (FG-04) can be exercised.
    public var lineDelay: TimeInterval
    public var glossary: [String: String]

    public init(lineDelay: TimeInterval = 0.15, glossary: [String: String] = DemoEngine.sampleGlossary) {
        self.lineDelay = lineDelay
        self.glossary = glossary
    }

    public func translateSong(_ lines: [LyricLine], to target: Language) -> AsyncThrowingStream<LineResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines {
                    if Task.isCancelled { break }
                    if lineDelay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(lineDelay * 1_000_000_000))
                    }
                    if LanguageGuess.isLikely(line.text, language: target.code) {
                        continuation.yield(.copied(index: line.index))
                    } else if let known = glossary[line.text] {
                        continuation.yield(.translated(index: line.index, text: known))
                    } else {
                        continuation.yield(.translated(index: line.index, text: "(\(target.nativeName)) \(line.text)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func explain(_ line: LyricLine, context: [LyricLine], in target: Language) async throws -> Explanation {
        if lineDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(lineDelay * 4 * 1_000_000_000))
        }
        let words = line.text.split(separator: " ").map(String.init)
        let phrase = words.prefix(min(3, words.count)).joined(separator: " ")
        return Explanation(
            expressions: [Expression(phrase: phrase, meaning: "‘\(phrase)’의 뜻 설명 (데모 엔진)")],
            structure: "문장 구조를 한 줄로 설명합니다.",
            usage: "어떤 상황에서 쓰는 표현인지 설명합니다.",
            example: "Example sentence using “\(phrase)”."
        )
    }

    /// Matches the bundled demo song in `DemoContent` (original text written for this prototype).
    public static let sampleGlossary: [String: String] = [
        "Wake up, the city's humming low": "일어나, 도시가 낮게 웅웅거려",
        "I've been running on empty since the summer show": "여름 공연 이후로 난 계속 바닥난 채로 달려왔어",
        "But you said take it easy, let it go": "근데 넌 말했지, 편하게 생각해, 그냥 흘려보내",
        "So I'm calling it a day-off, nowhere to go": "그래서 오늘은 쉬는 날로 할래, 갈 데도 없이",
    ]
}

/// Cheap script-based guess used only by the demo engine. The app uses Apple NaturalLanguage (RQ-15).
public enum LanguageGuess {
    public static func isLikely(_ text: String, language code: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let hangul = letters.filter { (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) }.count
        let latin = letters.filter { $0.isASCII }.count
        switch code {
        case "ko": return Double(hangul) / Double(letters.count) > 0.5
        case "en": return Double(latin) / Double(letters.count) > 0.9
        default: return false
        }
    }
}
