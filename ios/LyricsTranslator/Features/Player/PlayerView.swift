import SwiftUI
import LyricsCore

/// FG-06 Player · Lyrics — the core study screen (RQ-4, RQ-10, RQ-13, SSRD 3.1.1 modes,
/// DCR-4 offset / wrong lyrics, DCR-6 engine badge, DCR-7 study-only state).
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let songID: UUID

    @State private var selectedLine: SelectedLine?
    @State private var lastManualScroll = Date.distantPast
    @State private var session: ListenSession
    @State private var lastIndex: Int?
    @State private var showConquerPrompt = false
    @State private var goldBurst = false
    @State private var scrubPosition: Double?

    struct SelectedLine: Identifiable {
        let index: Int
        var id: Int { index }
    }

    /// Auto-scroll yields to manual scrolling and resumes after 5 s of no touch (RQ-10).
    private let manualScrollPause: TimeInterval = 5

    init(songID: UUID) {
        self.songID = songID
        _session = State(initialValue: ListenSession(songID: songID))
    }

    // MARK: Derived state

    private var song: Song? { model.collection.song(songID) }
    private var lines: [LyricLine] { model.collection.lines(for: songID) }

    private enum Mode { case linkedSynced, linkedPlain, studyOnly }

    /// Linked when the active source is playing this song (SSRD 3.1.1).
    private var isLinked: Bool {
        guard let song, let snap = model.nowPlaying else { return false }
        return TrackMatcher.matches(song.trackKey, snap.track)
    }

    private var mode: Mode {
        guard isLinked else { return .studyOnly }
        return song?.lyricsType == .synced ? .linkedSynced : .linkedPlain
    }

    private func syncEngine() -> SyncEngine {
        var engine = SyncEngine(offset: song?.offset ?? 0)
        if isLinked, let snap = model.nowPlaying { engine.update(snap) }
        return engine
    }

    // MARK: Body

    var body: some View {
        if let song {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let engine = syncEngine()
                let current = mode == .linkedSynced ? engine.currentLineIndex(in: lines, at: context.date) : nil
                VStack(spacing: 0) {
                    if mode == .studyOnly { studyOnlyBanner(song) }
                    lyricList(current: current)
                    if mode != .studyOnly {
                        transport(engine: engine, at: context.date)
                    }
                }
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    session.linesReached.insert(index)
                    // End of a play-through: store the session and maybe suggest "Conquered" (RQ-13).
                    if index == lines.count - 1 {
                        endSession()
                        if model.shouldSuggestConquered(songID) { showConquerPrompt = true }
                    }
                }
            }
            .background(theme.background.ignoresSafeArea())
            .toolbar { toolbarContent(song) }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $selectedLine) { line in
                LineDetailView(songID: songID, index: line.index, canSeek: canSeek) { seek(toLine: line.index) }
                    .environment(\.theme, theme)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(theme.surface)
                    .onAppear { session.explanationsOpened.insert(line.index) }
            }
            .overlay { if goldBurst { goldOverlay } }
            .alert("이 노래를 정복한 것 같아요!", isPresented: $showConquerPrompt) {
                Button("정복 완료") { conquer() }
                Button("아직이에요", role: .cancel) {}
            } message: {
                Text("세 번 넘게 끝까지 들으며 공부했어요. 골드 LP로 바꿀까요?")
            }
            .onDisappear(perform: endSession)
        } else {
            ContentUnavailableView("노래를 찾을 수 없어요", systemImage: "music.note")
        }
    }

    // MARK: Lyrics

    private func lyricList(current: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(lines) { line in
                        lyricRow(line, current: current)
                            .id(line.index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in lastManualScroll = Date() })
            .onChange(of: current) { _, index in
                guard let index, Date().timeIntervalSince(lastManualScroll) > manualScrollPause else { return }
                if reduceMotion {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.35))
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.35)) }
                }
            }
        }
    }

    private func lyricRow(_ line: LyricLine, current: Int?) -> some View {
        let isCurrent = line.index == current
        let isPast = current.map { line.index < $0 } ?? false
        let translation = model.collection.translationText(songID: songID, index: line.index, target: model.target.code)
        let failed = model.collection.translation(songID: songID, index: line.index, target: model.target.code)?.outcome == .failed
        let saved = model.collection.isSaved(songID: songID, index: line.index)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text)
                    .font(isCurrent ? AppFont.lyricCurrent : AppFont.lyric)
                    .foregroundStyle(isCurrent ? theme.textPrimary : theme.textPrimary.opacity(mode == .linkedSynced ? (isPast ? 0.45 : 0.6) : 0.85))
                if model.settings.showTranslation {
                    if let translation {
                        Text(translation)
                            .font(AppFont.translation)
                            .foregroundStyle(isCurrent ? theme.textSecondary : theme.textTertiary)
                    } else if failed {
                        Button("번역 실패 — 다시 시도") { model.startTranslation(songID: songID) }
                            .font(.caption)
                            .foregroundStyle(theme.textTertiary)
                    } else if model.isTranslating(songID) {
                        Text("번역 중…").font(.caption).foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selectedLine = SelectedLine(index: line.index) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("탭하면 해설을 볼 수 있어요")

            Button {
                _ = model.toggleSaved(songID: songID, index: line.index)
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? theme.textPrimary : theme.textTertiary)
                    .symbolEffect(.bounce, value: saved)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(saved ? "저장 취소" : "문장 저장")
        }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }

    // MARK: Transport (RQ-4)

    private var source: (any NowPlayingSource)? { model.source }
    private var canSeek: Bool { mode != .studyOnly && (source?.capabilities.contains(.seek) ?? false) }
    private var canSkip: Bool { source?.capabilities.contains(.skip) ?? false }

    private func transport(engine: SyncEngine, at date: Date) -> some View {
        let duration = song?.duration ?? model.nowPlaying?.track.duration ?? 0
        let position = scrubPosition ?? engine.position(at: date) ?? 0
        let isPlaying = model.nowPlaying?.isPlaying ?? false

        return VStack(spacing: 8) {
            Divider().overlay(theme.stroke)
            if canSeek, duration > 0 {
                Slider(value: Binding(get: { position }, set: { scrubPosition = $0 }), in: 0...duration, onEditingChanged: { editing in
                    if !editing, let target = scrubPosition {
                        Task { try? await source?.seek(to: target) }
                        scrubPosition = nil
                    }
                })
                .tint(theme.textPrimary)
                .accessibilityLabel("재생 위치")
            } else {
                ProgressView(value: duration > 0 ? min(position, duration) : 0, total: max(duration, 1))
                    .tint(theme.textPrimary)
            }
            HStack {
                Text(position.mmss)
                Spacer()
                Text(duration.mmss)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.textSecondary)

            HStack(spacing: 44) {
                Button { Task { try? await source?.previous() } } label: { Image(systemName: "backward.end") }
                    .disabled(!canSkip)
                    .accessibilityLabel("이전 곡")
                Button {
                    Task {
                        if isPlaying {
                            try? await source?.pause()
                        } else {
                            try? await source?.play()
                        }
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(theme.accent))
                        .foregroundStyle(theme.onAccent)
                }
                .accessibilityLabel(isPlaying ? "일시정지" : "재생")
                Button { Task { try? await source?.next() } } label: { Image(systemName: "forward.end") }
                    .disabled(!canSkip)
                    .accessibilityLabel("다음 곡")
            }
            .font(.title3)
            .foregroundStyle(theme.textPrimary)
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .background(theme.background)
    }

    private func seek(toLine index: Int) {
        guard canSeek, let line = lines.first(where: { $0.index == index }),
              let target = syncEngine().seekTarget(for: line) else { return }
        lastManualScroll = .distantPast
        Task { try? await source?.seek(to: target) }
    }

    // MARK: Study-only mode (DCR-7)

    private func studyOnlyBanner(_ song: Song) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "book")
            Text(song.lyricsType == .synced ? "가사 공부 모드 · 음악 앱과 연결되지 않았어요" : "가사 공부 모드 · 싱크 정보가 없는 가사예요")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            if song.lyricsType == .synced {
                Button(model.activeSourceID == nil || model.activeSourceID == .simulator ? "데모 재생" : "이 곡 재생") {
                    model.playDemo(for: song)
                }
                    .font(.caption.weight(.semibold))
                    .accessibilityHint("음악 없이 가사 싱크를 미리 볼 수 있어요")
            }
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.surface)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ song: Song) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                CoverArt(path: song.coverPath, cornerRadius: 4).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(song.artist).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                if song.isConquered {
                    Image(systemName: "trophy.fill").font(.caption).foregroundStyle(theme.gold)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("엔진") {
                    Text(EngineFactory.label(for: model.settings.engine))
                }
                Section("타이밍 조절 (현재 \(String(format: "%+.1f", song.offset))초)") {
                    Button { model.setOffset(songID, song.offset - SyncEngine.offsetStep) } label: { Label("가사 0.5초 빠르게", systemImage: "minus") }
                    Button { model.setOffset(songID, song.offset + SyncEngine.offsetStep) } label: { Label("가사 0.5초 느리게", systemImage: "plus") }
                    if song.offset != 0 {
                        Button("초기화") { model.setOffset(songID, 0) }
                    }
                }
                Button {
                    model.libraryPath.append(.search(prefill: "\(song.title) \(song.artist)"))
                } label: { Label("가사가 이상해요?", systemImage: "questionmark.bubble") }
                Button { model.retranslate(songID) } label: { Label("현재 엔진으로 다시 번역", systemImage: "character.bubble") }
                if song.isConquered {
                    Button { model.setConquered(songID, false) } label: { Label("정복 취소", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { conquer() } label: { Label("이 노래 정복!", systemImage: "trophy") }
                        .disabled(!model.canMarkConquered(songID) && session.linesReached.count < max(1, Int(Double(lines.count) * 0.9)))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("더보기")
        }
    }

    // MARK: Mastery (RQ-13) — signature motion #3: the LP turns gold

    private func endSession() {
        model.recordSession(session)
        session = ListenSession(songID: songID)
    }

    private func conquer() {
        model.setConquered(songID, true)
        Haptics.success()
        guard !reduceMotion else { return }
        goldBurst = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { goldBurst = false }
    }

    private var goldOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VinylRecord(labelColor: theme.gold, grooves: 4, filled: true)
                .frame(width: 220, height: 220)
                .overlay(Circle().stroke(theme.gold, lineWidth: 4))
                .shadow(color: theme.gold.opacity(0.6), radius: 30)
                .transition(.scale.combined(with: .opacity))
            Text("골드 LP 획득!")
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.gold)
                .offset(y: 150)
        }
        .allowsHitTesting(false)
    }
}
