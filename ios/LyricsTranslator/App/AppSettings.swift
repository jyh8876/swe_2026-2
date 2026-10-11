import Foundation
import LyricsCore

/// User preferences (FG-09). Stored in UserDefaults; secrets live in the Keychain instead.
struct AppSettings: Codable, Equatable {
    var hasOnboarded = false
    var engine: EngineKind = .onDevice
    var targetLanguage = Language.korean.code
    var showTranslation = true
    var theme: AppTheme.ID = .midnight
    /// One-time notice before the first cloud translation (SIR-3).
    var cloudNoticeAccepted = false
    var connectedSources: Set<SourceID> = []

    private static let key = "app.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    var target: Language { Language.named(targetLanguage) }
}
