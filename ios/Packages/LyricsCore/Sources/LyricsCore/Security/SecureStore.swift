import Foundation

public enum SecretKey: String, CaseIterable, Sendable {
    case claudeAPIKey = "api.claude"
    case geminiAPIKey = "api.gemini"
    case spotifyRefreshToken = "spotify.refresh"

    public static func apiKey(for engine: EngineKind) -> SecretKey? {
        switch engine {
        case .onDevice: return nil
        case .claude: return .claudeAPIKey
        case .gemini: return .geminiAPIKey
        }
    }
}

/// SSRD A.III `SecureStore`. iOS implementation is Keychain-backed (LOS-10).
public protocol SecureStore: Sendable {
    func set(_ value: String, for key: SecretKey) throws
    func value(for key: SecretKey) throws -> String?
    func delete(_ key: SecretKey) throws
}

extension SecureStore {
    /// "Delete all" removes every secret explicitly — Keychain items can survive an uninstall (PR-10).
    public func deleteAll() throws {
        for key in SecretKey.allCases { try delete(key) }
    }
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    public init() {}

    public func set(_ value: String, for key: SecretKey) throws { lock.withLock { values[key] = value } }
    public func value(for key: SecretKey) throws -> String? { lock.withLock { values[key] } }
    public func delete(_ key: SecretKey) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Masks a key for display after saving (RQ-14): "sk-ant-…a1b2".
public func maskSecret(_ s: String) -> String {
    guard s.count > 8 else { return String(repeating: "•", count: s.count) }
    return "\(s.prefix(6))…\(s.suffix(4))"
}
