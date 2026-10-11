import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP transport so the cloud engines can be tested without the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.network
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.network }
        return (data, http)
    }
}

/// Shared shape of the BYOK engines: one request per song, never one per line (SIR-9).
public protocol CloudChatEngine: TranslationEngine {
    var transport: HTTPTransport { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

extension CloudChatEngine {
    public func translateSong(_ lines: [LyricLine], to target: Language) -> AsyncThrowingStream<LineResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let toTranslate = lines.filter { !$0.text.isEmpty }
                    let text = try await withBackoff {
                        try await complete(system: Prompts.translationSystem(target: target),
                                           user: Prompts.translationUser(toTranslate),
                                           maxTokens: 4096)
                    }
                    var results = OutputValidator.translationResults(from: text, lines: toTranslate)

                    // Failed lines are retried individually once with a stricter prompt (ONRQ-12).
                    for (pos, result) in results.enumerated() {
                        guard case .failed(let index, _) = result, let line = lines.first(where: { $0.index == index }) else { continue }
                        let ctx = Prompts.context(for: line, in: lines)
                        let retryText = try? await complete(
                            system: Prompts.translationSystem(target: target) + "\nReturn exactly one entry, for the index given.",
                            user: Prompts.translationUser([line]) + "\n\nContext:\n" + ctx.map(\.text).joined(separator: "\n"),
                            maxTokens: 512)
                        if let retryText, let retried = OutputValidator.translationResults(from: retryText, lines: [line]).first {
                            results[pos] = retried
                        }
                    }
                    for r in results { continuation.yield(r) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func explain(_ line: LyricLine, context: [LyricLine], in target: Language) async throws -> Explanation {
        let system = Prompts.explanationSystem(target: target)
        let user = Prompts.explanationUser(line: line, context: context)
        let text = try await withBackoff { try await complete(system: system, user: user, maxTokens: 1024) }
        do {
            return try OutputValidator.explanation(from: text)
        } catch {
            // Invalid output is retried once, then surfaced as unavailable (RQ-11).
            let retry = try await complete(system: system + "\nOutput valid JSON only.", user: user, maxTokens: 1024)
            return try OutputValidator.explanation(from: retry)
        }
    }

    /// One minimal request for "Verify key" (RQ-14).
    public func verifyKey() async throws {
        _ = try await complete(system: "Reply with OK.", user: "ping", maxTokens: 5)
    }
}

/// Claude Messages API adapter (SIR-9). There is no official Swift SDK; this is a small URLSession client.
public struct ClaudeEngine: CloudChatEngine {
    public static let defaultModel = "claude-haiku-4-5"
    public static let qualityModel = "claude-sonnet-5-5"

    public let apiKey: String
    public let model: String
    public let transport: HTTPTransport
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = ClaudeEngine.defaultModel, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public var id: String { "claude:\(model)" }
    public var isAvailable: Bool { !apiKey.isEmpty }
    public var kind: EngineKind { .claude }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(request)
        try Self.check(status: http.statusCode, body: data)

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let stop_reason: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LLMError.malformedOutput("response")
        }
        if response.stop_reason == "refusal" { throw LLMError.refused }
        return response.content.compactMap(\.text).joined()
    }

    static func check(status: Int, body: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw LLMError.invalidKey
        case 400:
            let text = String(data: body, encoding: .utf8) ?? ""
            if text.contains("credit") { throw LLMError.outOfCredit }
            throw LLMError.malformedOutput("bad request")
        case 429: throw LLMError.rateLimited
        default: throw LLMError.server(status)
        }
    }
}

/// Gemini API adapter (SIR-10). Same contract as Claude behind the same engine interface.
public struct GeminiEngine: CloudChatEngine {
    /// Configuration value: the team picks Gemini's current fast, low-cost tier.
    public static let defaultModel = "gemini-2.5-flash"

    public let apiKey: String
    public let model: String
    public let transport: HTTPTransport

    public init(apiKey: String, model: String = GeminiEngine.defaultModel, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public var id: String { "gemini:\(model)" }
    public var isAvailable: Bool { !apiKey.isEmpty }
    public var kind: EngineKind { .gemini }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Header, not query string, so the key never lands in URL logs (LOS-10).
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": maxTokens, "responseMimeType": "application/json"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(request)
        switch http.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw LLMError.invalidKey
        case 429: throw LLMError.rateLimited
        default: throw LLMError.server(http.statusCode)
        }

        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable { struct Part: Decodable { let text: String? }; let parts: [Part]? }
                let content: Content?
                let finishReason: String?
            }
            let candidates: [Candidate]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let candidate = response.candidates?.first else {
            throw LLMError.malformedOutput("response")
        }
        if candidate.finishReason == "SAFETY" { throw LLMError.refused }
        return candidate.content?.parts?.compactMap(\.text).joined() ?? ""
    }
}
