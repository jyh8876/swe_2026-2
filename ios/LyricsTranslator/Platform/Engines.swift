import Foundation
import LyricsCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks the concrete engine for a user choice (Win-AGRE-4).
/// On-device: Apple Foundation Models where available, else llama.cpp once integrated,
/// else the deterministic demo engine so the prototype stays usable.
enum EngineFactory {
    static func make(_ kind: EngineKind, apiKey: String?) -> any TranslationEngine {
        switch kind {
        case .claude:
            return ClaudeEngine(apiKey: apiKey ?? "")
        case .gemini:
            return GeminiEngine(apiKey: apiKey ?? "")
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *), FoundationModelsEngine.isSupported {
                return AppleFMEngine()
            }
            #endif
            if LlamaEngine.isModelInstalled {
                return LlamaEngine()
            }
            return DemoEngine()
        }
    }

    /// The engine id currently answering for a choice, for the badge (SIR-3).
    static func label(for kind: EngineKind) -> String {
        guard kind == .onDevice else { return kind.badgeLabel }
        if FoundationModelsEngine.isSupported { return "On-device · Apple" }
        if LlamaEngine.isModelInstalled { return "On-device · Gemma" }
        return "On-device · Demo"
    }
}

// MARK: - Apple Foundation Models (candidate O-4b)

enum FoundationModelsEngine {
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
/// One language-model session per request; JSON output validated by `OutputValidator` (SIR-8).
/// Spike S1 will compare this with llama.cpp on the 10-song benchmark.
@available(iOS 26.0, macOS 26.0, *)
struct AppleFMEngine: TranslationEngine {
    var id: String { "apple-fm@\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)" }
    var isAvailable: Bool { FoundationModelsEngine.isSupported }
    var kind: EngineKind { .onDevice }

    private func respond(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: user).content
        } catch {
            throw LLMError.unavailable("온디바이스 모델이 응답하지 않았어요.")
        }
    }

    func translateSong(_ lines: [LyricLine], to target: Language) -> AsyncThrowingStream<LineResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Stanza-sized windows keep the context small for the on-device model (LOS-5).
                let windows = stride(from: 0, to: lines.count, by: 8).map { Array(lines[$0..<min($0 + 8, lines.count)]) }
                for window in windows {
                    if Task.isCancelled { break }
                    do {
                        let text = try await respond(system: Prompts.translationSystem(target: target), user: Prompts.translationUser(window))
                        for r in OutputValidator.translationResults(from: text, lines: window) { continuation.yield(r) }
                    } catch {
                        for line in window { continuation.yield(.failed(index: line.index, reason: "engine")) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func explain(_ line: LyricLine, context: [LyricLine], in target: Language) async throws -> Explanation {
        let text = try await respond(system: Prompts.explanationSystem(target: target),
                                     user: Prompts.explanationUser(line: line, context: context))
        return try OutputValidator.explanation(from: text)
    }
}
#endif

// MARK: - llama.cpp (candidate O-4a)

/// Placeholder for the llama.cpp engine. Integration (pinned llama.cpp Swift package, Metal
/// backend, Gemma 2B / 4B Q4 GGUF) lands after spike S1 if it wins the measurement.
/// Until then it delegates to the demo engine so the flow can be exercised.
struct LlamaEngine: TranslationEngine {
    static var isModelInstalled: Bool { ModelManager.isInstalled }

    var id: String { "llama:\(ModelManager.modelName)@q4" }
    var isAvailable: Bool { Self.isModelInstalled }
    var kind: EngineKind { .onDevice }

    private let fallback = DemoEngine()

    func translateSong(_ lines: [LyricLine], to target: Language) -> AsyncThrowingStream<LineResult, Error> {
        // TODO(S1): llama_decode loop with one persistent context per song.
        fallback.translateSong(lines, to: target)
    }

    func explain(_ line: LyricLine, context: [LyricLine], in target: Language) async throws -> Explanation {
        try await fallback.explain(line, context: context, in: target)
    }
}

/// Downloads, verifies (SHA-256), and deletes the GGUF model (PR-9). Not needed with Apple FM.
enum ModelManager {
    static let modelName = "gemma-2b-it"
    /// Pinned in the repo once spike S1 selects the file.
    static let expectedSHA256 = "TBD-after-S1"
    static let approximateBytes: Int64 = 1_600_000_000

    static var modelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LyricsTranslator/Models/\(modelName).gguf")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    static var modelBytes: Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    /// Needs model size + 500 MB headroom (ONRQ-14).
    static func hasRoomForDownload(_ device: DeviceCapability) -> Bool {
        device.freeDiskBytes > approximateBytes + 500_000_000
    }

    /// Prototype download: reports progress for ~4 s, then writes a small marker file in place of
    /// the GGUF so the installed state, storage meter and delete button can be tested.
    /// The real version streams the file and checks `expectedSHA256` before moving it into place.
    static func download(progress: @MainActor (Double) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(nanoseconds: 200_000_000)
            await progress(Double(step) / 20)
        }
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prototype-model-placeholder".utf8).write(to: modelURL, options: .atomic)
    }

    static func deleteModel() {
        try? FileManager.default.removeItem(at: modelURL)
    }
}
