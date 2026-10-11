import SwiftUI
import LyricsCore

/// FG-08 Phrase box (RQ-12, RQ-13 statistics). No share/export in MVP (FG-08 note).
struct PhraseBoxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var sort: Sort = .newest
    @State private var openPhrase: Phrase?
    @State private var undo: Phrase?

    enum Sort { case newest, bySong }

    var body: some View {
        let phrases = sorted(model.collection.phrases)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsCard
                HStack(spacing: 8) {
                    chip("최신순", .newest)
                    chip("곡별", .bySong)
                }
                if phrases.isEmpty {
                    Text("가사 옆의 ☆를 눌러 마음에 드는 문장을 모아보세요.")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 24)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(phrases) { phrase in
                            card(phrase)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("문장 저장함")
        .overlay(alignment: .bottom) {
            if let undo {
                HStack {
                    Text("문장을 삭제했어요").font(.footnote)
                    Spacer()
                    Button("실행 취소") { restore(undo) }.font(.footnote.weight(.semibold))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.surfaceRaised))
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: undo.id) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.undo?.id == undo.id { self.undo = nil }
                }
            }
        }
        .animation(.easeInOut, value: undo?.id)
        .sheet(item: $openPhrase) { phrase in
            LineDetailView(songID: phrase.songID, index: phrase.index, canSeek: false, onReplay: {})
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.surface)
        }
    }

    private var statsCard: some View {
        let stats = model.collection.stats
        return HStack {
            stat("\(stats.phrases)", "저장한 문장")
            Spacer()
            stat("\(stats.songs)", "곡")
            Spacer()
            stat("\(stats.conquered)", "정복")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).foregroundStyle(theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(theme.textSecondary)
        }
    }

    private func chip(_ title: String, _ value: Sort) -> some View {
        Button(title) { sort = value }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(sort == value ? theme.onAccent : theme.textSecondary)
            .background(Capsule().fill(sort == value ? theme.accent : .clear))
            .overlay(Capsule().stroke(sort == value ? .clear : theme.stroke))
            .buttonStyle(.plain)
    }

    private func card(_ phrase: Phrase) -> some View {
        let line = model.collection.lines.first { $0.songID == phrase.songID && $0.index == phrase.index }
        let song = model.collection.song(phrase.songID)
        let translation = model.collection.translationText(songID: phrase.songID, index: phrase.index, target: model.target.code)

        return Button { openPhrase = phrase } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(line?.text ?? "").font(.headline).foregroundStyle(theme.textPrimary)
                if let translation {
                    Text(translation).font(.subheadline).foregroundStyle(theme.textSecondary)
                }
                Divider().overlay(theme.stroke)
                HStack(spacing: 8) {
                    CoverArt(path: song?.coverPath, cornerRadius: 3).frame(width: 22, height: 22)
                    Text("\(song?.title ?? "삭제된 노래") · \(song?.artist ?? "")")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        _ = model.toggleSaved(songID: phrase.songID, index: phrase.index)
                        undo = phrase
                    } label: {
                        Image(systemName: "star.fill").foregroundStyle(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("저장 취소")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.stroke))
        }
        .buttonStyle(.plain)
    }

    private func sorted(_ phrases: [Phrase]) -> [Phrase] {
        switch sort {
        case .newest:
            return phrases.sorted { $0.savedAt > $1.savedAt }
        case .bySong:
            let titles = Dictionary(uniqueKeysWithValues: model.collection.songs.map { ($0.id, $0.title) })
            return phrases.sorted {
                let a = titles[$0.songID] ?? "", b = titles[$1.songID] ?? ""
                return a == b ? $0.index < $1.index : a < b
            }
        }
    }

    private func restore(_ phrase: Phrase) {
        if !model.collection.isSaved(songID: phrase.songID, index: phrase.index) {
            _ = model.toggleSaved(songID: phrase.songID, index: phrase.index)
        }
        undo = nil
    }
}
