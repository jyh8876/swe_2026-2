import Foundation

/// SSRD A.III `LLMEngine`.
/// id: "llama:<model>@<quant>" | "apple-fm@<os>" | "claude:<model>" | "gemini:<model>" | "mock"
public protocol LLMEngine: Sendable {
    var id: String { get }
    var isAvailable: Bool { get }
    var kind: EngineKind { get }
}

/// Per-line outcome of a song translation.
public enum LineResult: Sendable, Hashable {
    case translated(index: Int, text: String)
    /// Line already in the target language; copied, not translated (RQ-7).
    case copied(index: Int)
    case failed(index: Int, reason: String)

    public var index: Int {
        switch self {
        case .translated(let i, _), .copied(let i), .failed(let i, _): return i
        }
    }
}

/// SSRD A.III `Translator`. Yields one result per line, in any order.
public protocol Translator: LLMEngine {
    func translateSong(_ lines: [LyricLine], to target: Language) -> AsyncThrowingStream<LineResult, Error>
}

/// SSRD A.III `Explainer`.
public protocol Explainer: LLMEngine {
    func explain(_ line: LyricLine, context: [LyricLine], in target: Language) async throws -> Explanation
}

public typealias TranslationEngine = Translator & Explainer

/// User-facing engine choice (FG-00, FG-09).
public enum EngineKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case onDevice
    case claude
    case gemini

    public var id: String { rawValue }

    public var requiresAPIKey: Bool { self != .onDevice }

    /// Badge label shown on FG-04/FG-06 (SIR-3).
    public var badgeLabel: String {
        switch self {
        case .onDevice: return "On-device"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

public enum LLMError: Error, Equatable, Sendable {
    case missingAPIKey
    /// Authentication error: stop, mark the key invalid (ONRQ-10).
    case invalidKey
    case outOfCredit
    case rateLimited
    case server(Int)
    case network
    /// Output failed validation after retry (ONRQ-12).
    case malformedOutput(String)
    /// Provider declined (ONRQ-13).
    case refused
    case unavailable(String)

    /// Plain-language message for the UI (Korean, matching the Figma copy).
    public var userMessage: String {
        switch self {
        case .missingAPIKey: return "API 키를 먼저 입력해 주세요."
        case .invalidKey: return "API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .outOfCredit: return "API 계정의 크레딧이 부족해요."
        case .rateLimited: return "요청이 많아 잠시 후 다시 시도해요."
        case .server(let code): return "서버 오류가 발생했어요 (\(code))."
        case .network: return "인터넷에 연결되어 있지 않아요."
        case .malformedOutput: return "번역 결과를 확인하지 못했어요. 다시 시도해 주세요."
        case .refused: return "현재 엔진에서는 이 해설을 제공할 수 없어요."
        case .unavailable(let why): return why
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server: return true
        default: return false
        }
    }
}

/// Retry with exponential backoff, up to 3 attempts (ONRQ-10).
func withBackoff<T: Sendable>(attempts: Int = 3, baseDelay: TimeInterval = 0.5, _ op: @Sendable () async throws -> T) async throws -> T {
    var lastError: Error?
    for attempt in 0..<attempts {
        do {
            return try await op()
        } catch let error as LLMError where error.isRetryable {
            lastError = error
            if attempt < attempts - 1 {
                try await Task.sleep(nanoseconds: UInt64(baseDelay * pow(2, Double(attempt)) * 1_000_000_000))
            }
        }
    }
    throw lastError ?? LLMError.network
}
