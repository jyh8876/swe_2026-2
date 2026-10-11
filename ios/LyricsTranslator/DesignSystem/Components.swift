import SwiftUI
import LyricsCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Buttons (FG-00 note: "Later" and "Connect" are the same size)

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(theme.onAccent)
            .background(theme.accent.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(theme.textPrimary)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.textPrimary.opacity(0.8), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Vinyl record

/// Concentric-groove record used on onboarding, translating and in LP cards.
struct VinylRecord: View {
    @Environment(\.theme) private var theme
    var labelColor: Color?
    var grooves = 3
    var filled = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if filled {
                    Circle().fill(theme.vinyl)
                }
                ForEach(0..<grooves, id: \.self) { i in
                    Circle()
                        .stroke(filled ? theme.background.opacity(0.15) : theme.stroke, lineWidth: 1)
                        .frame(width: side * (1 - CGFloat(i) * 0.1), height: side * (1 - CGFloat(i) * 0.1))
                }
                Circle()
                    .fill(labelColor ?? theme.surfaceRaised)
                    .frame(width: side * 0.36, height: side * 0.36)
                Circle()
                    .fill(theme.background)
                    .frame(width: side * 0.04, height: side * 0.04)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Spinning record for FG-04. Respects Reduce Motion (SIR-2).
struct SpinningRecord: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        VinylRecord(grooves: 4)
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

// MARK: - Cover art

struct CoverArt: View {
    @Environment(\.theme) private var theme
    var path: String?
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(theme.surfaceRaised)
            if let path, let image = loadImage(path) {
                image.resizable().scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func loadImage(_ path: String) -> Image? {
        guard let data = try? Data(contentsOf: CoverStore.url(for: path)) else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

// MARK: - LP card (FG-01: record peeking out of the sleeve)

struct LPCard: View {
    @Environment(\.theme) private var theme
    let song: Song
    var isTranslating = false
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let sleeve = geo.size.height
                ZStack(alignment: .leading) {
                    VinylRecord(labelColor: song.isConquered ? theme.gold : theme.surfaceRaised, grooves: 2, filled: true)
                        .frame(width: sleeve * 0.92, height: sleeve * 0.92)
                        .offset(x: geo.size.width - sleeve * 0.92 + sleeve * 0.05)
                        .overlay {
                            if song.isConquered {
                                Circle().stroke(theme.gold, lineWidth: 2)
                                    .frame(width: sleeve * 0.92, height: sleeve * 0.92)
                                    .offset(x: geo.size.width - sleeve * 0.92 + sleeve * 0.05)
                            }
                        }
                    CoverArt(path: song.coverPath)
                        .frame(width: sleeve, height: sleeve)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(highlighted ? theme.textPrimary : .clear, lineWidth: 2)
                        )
                }
            }
            .aspectRatio(1.15, contentMode: .fit)
            .clipped()

            Text(song.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(song.artist)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            StatusBadge(status: badgeStatus)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title), \(song.artist), \(badgeStatus.label)")
    }

    private var badgeStatus: StatusBadge.Status {
        if song.isConquered { return .conquered }
        if isTranslating || song.status == .translating { return .translating }
        if song.status == .failed { return .retry }
        return .done
    }
}

struct StatusBadge: View {
    @Environment(\.theme) private var theme

    enum Status {
        case translating, done, conquered, retry

        var label: String {
            switch self {
            case .translating: return "번역 중"
            case .done: return "완료"
            case .conquered: return "정복 완료"
            case .retry: return "재시도"
            }
        }
    }

    let status: Status

    var body: some View {
        HStack(spacing: 4) {
            if status == .translating {
                ProgressView().controlSize(.mini).tint(theme.textSecondary)
            }
            Text(status.label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(status == .conquered ? theme.onAccent : theme.textSecondary)
        .background(
            Capsule().fill(status == .conquered ? theme.accent : theme.surfaceRaised)
        )
    }
}

// MARK: - Lyrics availability badge (FG-02)

struct LyricsBadge: View {
    @Environment(\.theme) private var theme
    let availability: LyricsCandidate.Availability

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(availability == .none ? theme.textTertiary : theme.textSecondary)
            .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
    }

    private var label: String {
        switch availability {
        case .synced: return "싱크 가사"
        case .plain: return "일반 가사"
        case .none: return "가사 없음"
        }
    }
}

// MARK: - Engine badge (SIR-3)

struct EngineBadge: View {
    @Environment(\.theme) private var theme
    let label: String

    var body: some View {
        Label(label, systemImage: label.hasPrefix("On-device") ? "iphone" : "cloud")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(theme.textSecondary)
            .background(Capsule().fill(theme.surfaceRaised))
            .accessibilityLabel("번역 엔진: \(label)")
    }
}

// MARK: - Skeleton loader (RQ-11)

struct SkeletonLines: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var count = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.surfaceRaised)
                    .frame(height: 14)
                    .frame(maxWidth: i == count - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .opacity(pulse ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
        .accessibilityLabel("해설을 불러오는 중")
    }
}

// MARK: - Section label

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(AppFont.sectionLabel)
            .foregroundStyle(theme.textSecondary)
    }
}

// MARK: - Banner (ONRQ-6: non-blocking, states cause and the one fixing action)

struct BannerView: View {
    @Environment(\.theme) private var theme
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.footnote.weight(.semibold))
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .accessibilityLabel("닫기")
        }
        .foregroundStyle(theme.textPrimary)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surfaceRaised))
        .padding(.horizontal, 16)
    }
}

// MARK: - Helpers

extension TimeInterval {
    /// 72 → "1:12"
    var mmss: String {
        let total = Int(self.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
