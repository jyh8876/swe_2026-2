import SwiftUI
import LyricsCore

/// FG-00 Onboarding (RQ-1, RQ-2, DCR-1).
/// At most 3 intro cards; engine choice; "Connect your music" with an equally sized "Later".
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var page = 0
    @State private var engine: EngineKind = .onDevice
    @State private var showConnectOptions = false
    @State private var showKeyEntry = false

    private let cards: [(title: String, body: String)] = [
        ("노래로 공부하고,\nLP로 모으자", "팝송 가사를 AI로 해석하고 나만의 컬렉션으로 모아요"),
        ("한 줄씩,\n음악에 맞춰서", "지금 듣는 노래의 가사가 박자에 맞춰 흐르고, 해석이 바로 아래에 보여요"),
        ("모르는 표현은\n탭 한 번으로", "슬랭과 관용구를 쉽게 풀어주고, 좋은 문장은 저장함에 담아요"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("\(page + 1) / \(cards.count)")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { i in
                    introCard(cards[i]).tag(i)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .frame(maxHeight: 420)

            pageDots.padding(.bottom, 28)

            enginePicker
                .padding(.horizontal, 20)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                Button("음악 앱 연결하기") { showConnectOptions = true }
                    .buttonStyle(.primary)
                Button("나중에 하기") { finish() }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(theme.background.ignoresSafeArea())
        .confirmationDialog("음악 앱 연결", isPresented: $showConnectOptions, titleVisibility: .visible) {
            Button("Spotify") { connect(.spotify) }
            Button("Apple Music") { connect(.appleMusic) }
            Button("나중에", role: .cancel) {}
        } message: {
            Text("iPhone에서는 Spotify와 Apple Music을 연결할 수 있어요. 다른 앱은 가사 공부 모드로 쓸 수 있어요.")
        }
        .sheet(isPresented: $showKeyEntry) {
            NavigationStack { APIKeyEntryView(onDone: { showKeyEntry = false }) }
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
        }
    }

    private func introCard(_ card: (title: String, body: String)) -> some View {
        VStack(spacing: 28) {
            VinylRecord(grooves: 4)
                .frame(width: 180, height: 180)
                .padding(.top, 24)
            Text(card.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textPrimary)
            Text(card.body)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 32)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(cards.indices, id: \.self) { i in
                Circle()
                    .fill(i == page ? theme.textPrimary : theme.stroke)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("번역 엔진")
            HStack(spacing: 10) {
                engineCard(.onDevice, title: "온디바이스", subtitle: "기본 · 무료",
                           disabledReason: model.device.onDeviceUnavailableReason)
                engineCard(.claude, title: "내 API 키", subtitle: "Claude · Gemini", disabledReason: nil)
            }
            if engine == .onDevice {
                Text(onDeviceNote)
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
            } else if let reason = model.device.onDeviceUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var onDeviceNote: String {
        if FoundationModelsEngine.isSupported { return "이 기기에 내장된 AI로 번역해요. 추가 다운로드가 없어요." }
        return "처음 한 번 Wi-Fi에서 약 1–2GB 모델을 내려받아요."
    }

    private func engineCard(_ kind: EngineKind, title: String, subtitle: String, disabledReason: String?) -> some View {
        let selected = kind == .onDevice ? engine == .onDevice : engine != .onDevice
        return Button {
            engine = kind
            if kind != .onDevice { showKeyEntry = true }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(theme.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? theme.textPrimary : theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.4 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func connect(_ source: SourceID) {
        Task {
            await model.connect(source)
            finish()
        }
    }

    private func finish() {
        // If on-device is not possible, fall back to whichever key engine the user set up.
        var chosen = engine
        if chosen == .onDevice, model.device.onDeviceUnavailableReason != nil { chosen = .claude }
        if chosen != .onDevice, model.apiKey(for: chosen) == nil, model.apiKey(for: .gemini) != nil { chosen = .gemini }
        model.settings.engine = chosen
        model.settings.hasOnboarded = true
    }
}
