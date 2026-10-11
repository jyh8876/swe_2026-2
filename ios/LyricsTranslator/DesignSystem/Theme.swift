import SwiftUI

/// Colours sampled from the Figma prototype (dark vinyl/LP visual language).
/// Contrast of primary and secondary text on background is ≥ 4.5:1 (SIR-2).
struct AppTheme: Equatable {
    enum ID: String, Codable, CaseIterable, Identifiable {
        case midnight
        case woody

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .midnight: return "미드나잇"
            case .woody: return "우디"
            }
        }
    }

    let id: ID
    let background: Color
    let surface: Color
    let surfaceRaised: Color
    let stroke: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let onAccent: Color
    let vinyl: Color
    let gold: Color
    let marker: Color

    static func theme(_ id: ID) -> AppTheme {
        switch id {
        case .midnight:
            return AppTheme(
                id: .midnight,
                background: Color(hex: 0x16171B),
                surface: Color(hex: 0x1E1F24),
                surfaceRaised: Color(hex: 0x2A2B31),
                stroke: Color(hex: 0x3A3B42),
                textPrimary: Color(hex: 0xF2F2F4),
                textSecondary: Color(hex: 0xA3A4AB),
                textTertiary: Color(hex: 0x6E6F76),
                accent: Color(hex: 0xF2F2F4),
                onAccent: Color(hex: 0x16171B),
                vinyl: Color(hex: 0xF2F2F4),
                gold: Color(hex: 0xE3B341),
                marker: Color(hex: 0x3B3D45)
            )
        case .woody:
            return AppTheme(
                id: .woody,
                background: Color(hex: 0x1C1612),
                surface: Color(hex: 0x261E18),
                surfaceRaised: Color(hex: 0x342920),
                stroke: Color(hex: 0x4A3B2E),
                textPrimary: Color(hex: 0xF4EADC),
                textSecondary: Color(hex: 0xC2AE96),
                textTertiary: Color(hex: 0x8A7763),
                accent: Color(hex: 0xE8D3B5),
                onAccent: Color(hex: 0x1C1612),
                vinyl: Color(hex: 0xE8D3B5),
                gold: Color(hex: 0xE3B341),
                marker: Color(hex: 0x5A4430)
            )
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.theme(.midnight)
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Type scale used across screens. Uses Dynamic Type text styles so lyrics scale (SIR-2).
enum AppFont {
    static let brand = Font.system(.title3, design: .rounded).weight(.semibold)
    static let screenTitle = Font.headline
    static let sectionLabel = Font.footnote
    static let lyric = Font.title3.weight(.medium)
    static let lyricCurrent = Font.title3.weight(.bold)
    static let translation = Font.subheadline
    static let caption = Font.caption
}
