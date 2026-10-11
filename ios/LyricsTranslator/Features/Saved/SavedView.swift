import SwiftUI
import LyricsCore

/// FG-05 Saved (RQ-8). Signature motion #2: LP drops onto the shelf. ≤ 1.2 s, Reduce Motion aware.
struct SavedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let songID: UUID
    @State private var dropped = false

    var body: some View {
        let song = model.collection.song(songID)
        VStack(spacing: 20) {
            Spacer()
            shelf
                .frame(height: 160)
                .padding(.horizontal, 40)

            Text("컬렉션에 추가됐어요!")
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.textPrimary)
            Text("\(song?.title ?? "") · \(song?.artist ?? "")")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Text("가사 \(model.collection.translatedCount(songID: songID, target: model.target.code))줄 번역 완료")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)

            VStack(spacing: 12) {
                Button("바로 공부하기") { model.libraryPath = [.player(songID)] }
                    .buttonStyle(.primary)
                Button("라이브러리로") { model.libraryPath = [] }
                    .buttonStyle(.secondary)
            }
            .padding(.top, 16)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(theme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .onAppear {
            if reduceMotion {
                dropped = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) { dropped = true }
            }
        }
    }

    private var shelf: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(theme.stroke).frame(width: 10, height: 120)
                }
                CoverArt(path: model.collection.song(songID)?.coverPath, cornerRadius: 4)
                    .frame(width: 140, height: 140)
                    .offset(y: dropped ? 0 : -220)
                    .opacity(dropped ? 1 : 0)
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(theme.stroke).frame(width: 10, height: 120)
                }
            }
            Rectangle().fill(theme.textPrimary).frame(height: 3)
        }
    }
}
