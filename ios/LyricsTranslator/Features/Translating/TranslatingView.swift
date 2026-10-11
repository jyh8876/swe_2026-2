import SwiftUI
import LyricsCore

/// FG-04 Translating (RQ-7, SIR-3). "Send to background" means "continue while I use other
/// screens of this app" (ONRQ-9).
struct TranslatingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let songID: UUID

    var body: some View {
        let progress = model.progress[songID]
        let total = progress?.total ?? model.collection.lines(for: songID).count
        let done = progress?.done ?? model.collection.translatedCount(songID: songID, target: model.target.code)

        VStack(spacing: 24) {
            HStack {
                Spacer()
                EngineBadge(label: EngineFactory.label(for: model.settings.engine))
            }

            SpinningRecord()
                .frame(width: 200, height: 200)
                .padding(.top, 24)

            Text("번역 중 (\(done)/\(total)줄)")
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())

            ProgressView(value: total == 0 ? 0 : Double(done), total: Double(max(total, 1)))
                .tint(theme.textPrimary)

            stages(current: progress?.stage ?? .fetchLyrics)

            Text(etaText(progress?.eta))
                .font(.caption)
                .foregroundStyle(theme.textSecondary)

            VStack(spacing: 4) {
                Text(model.collection.lines(for: songID).first?.text ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                Text(progress?.firstLinePreview ?? "가사 첫 줄 해석이 미리 떠오릅니다")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.surfaceRaised))
            .animation(.easeOut, value: progress?.firstLinePreview)

            Button("백그라운드로 보내기") { model.libraryPath = [] }
                .buttonStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .background(theme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .onChange(of: model.isTranslating(songID)) { _, running in
            if !running { finish() }
        }
        .onAppear {
            if !model.isTranslating(songID) { finish() }
        }
    }

    /// RQ-8: the reward screen is shown only if the job finishes while this screen is visible.
    private func finish() {
        guard let song = model.collection.song(songID) else { return }
        if song.status == .done {
            Haptics.success()
            model.libraryPath = [.saved(songID)]
        } else {
            model.libraryPath = [.player(songID)]
        }
    }

    private func stages(current: TranslationProgress.Stage) -> some View {
        HStack(spacing: 8) {
            stage("가사 불러오기", active: current == .fetchLyrics)
            Image(systemName: "chevron.right").font(.caption2)
            stage("번역", active: current == .translate)
            Image(systemName: "chevron.right").font(.caption2)
            stage("저장", active: current == .save)
        }
        .foregroundStyle(theme.textTertiary)
    }

    private func stage(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? theme.textPrimary : theme.textTertiary)
    }

    private func etaText(_ eta: TimeInterval?) -> String {
        guard let eta else { return "예상 시간 약 20초" }
        return "예상 시간 약 \(max(1, Int(eta.rounded())))초"
    }
}
