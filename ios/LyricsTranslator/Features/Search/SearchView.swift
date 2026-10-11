import SwiftUI
import LyricsCore

/// FG-02 Song search (RQ-5, ONRQ-1, ONRQ-11, RQ-17).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var query: String
    @State private var results: [LyricsCandidate] = []
    @State private var isLoading = false
    @State private var error: LyricsError?
    @State private var tab: SearchTab = .search
    @State private var loadingCandidateID: Int?

    enum SearchTab { case search, spotify }

    init(initialQuery: String) {
        _query = State(initialValue: initialQuery)
    }

    private var spotifyLinked: Bool { model.settings.connectedSources.contains(.spotify) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.top, 8)

            // Users without Spotify see no empty playlist tab (FG-02 note).
            if spotifyLinked {
                tabs.padding(.horizontal, 20).padding(.top, 12)
            }

            content
                .frame(maxHeight: .infinity)

            Button { model.libraryPath.append(.add(AddSongDraft())) } label: {
                Label("직접 추가하기", systemImage: "plus")
            }
            .buttonStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("노래 검색")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: query) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.textSecondary)
            TextField("", text: $query, prompt: Text("제목, 아티스트 검색").foregroundStyle(theme.textTertiary))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityLabel("지우기")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.surface))
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("검색", .search)
            tabButton("내 스포티파이 플레이리스트", .spotify)
        }
    }

    private func tabButton(_ title: String, _ value: SearchTab) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(tab == value ? theme.textPrimary : theme.textSecondary)
                Rectangle().fill(tab == value ? theme.textPrimary : theme.stroke).frame(height: tab == value ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if tab == .spotify {
            spotifyPlaylists
        } else if !model.network.isOnline && results.isEmpty {
            ContentUnavailableView("오프라인", systemImage: "wifi.slash",
                                   description: Text("검색하려면 인터넷 연결이 필요해요. 가사를 붙여넣어 직접 추가할 수는 있어요."))
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView {
                CuratedShelvesView(shelves: model.shelves) { entry, _ in
                    query = "\(entry.title) \(entry.artist)"
                }
                .padding(20)
            }
        } else if isLoading && results.isEmpty {
            ProgressView().tint(theme.textSecondary).frame(maxHeight: .infinity)
        } else if results.isEmpty {
            noResults
        } else {
            List(results) { candidate in
                resultRow(candidate)
                    .listRowBackground(theme.background)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// Mock "my playlists" (built from the curated shelves) until the Spotify Web API is wired.
    /// Tapping a song searches LRCLIB for it, as the real tab will.
    private var spotifyPlaylists: some View {
        List {
            ForEach(model.shelves) { shelf in
                Section {
                    ForEach(shelf.songs) { entry in
                        Button {
                            query = "\(entry.title) \(entry.artist)"
                            tab = .search
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 40, height: 40)
                                    .overlay(Image(systemName: "music.note").foregroundStyle(theme.textTertiary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(.subheadline).foregroundStyle(theme.textPrimary).lineLimit(1)
                                    Text(entry.artist).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                if model.collection.existingSong(matching: entry.trackKey) != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                                        .accessibilityLabel("이미 추가됨")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(theme.background)
                    }
                } header: {
                    Text(shelf.title).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(theme.textTertiary)
            Text("가사를 찾지 못했어요").font(.headline).foregroundStyle(theme.textPrimary)
            Text(error == nil
                 ? "영어 제목이나 원래 언어의 제목으로 다시 검색해 보세요.\n또는 가사를 붙여넣어 직접 추가할 수 있어요."
                 : "가사 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(32)
        .frame(maxHeight: .infinity)
    }

    private func resultRow(_ c: LyricsCandidate) -> some View {
        Button { select(c) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.trackName).font(.subheadline).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Text("\(TrackNormalizer.primaryArtist(c.artistName)) · \((c.duration ?? 0).mmss)")
                        .font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if loadingCandidateID == c.id {
                    ProgressView().controlSize(.small)
                } else {
                    LyricsBadge(availability: c.availability)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "No lyrics" results cannot be added without pasting (ONRQ-1) → open manual add pre-filled.
        .accessibilityHint(c.availability == .none ? "가사가 없어 직접 붙여넣어야 해요" : "")
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        // Debounce typing.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await model.lyricsProvider.search(q)
            guard !Task.isCancelled else { return }
            results = found.filter { !$0.instrumental || $0.hasSynced || $0.hasPlain } + found.filter { $0.instrumental && !$0.hasSynced && !$0.hasPlain }
            error = nil
        } catch let e as LyricsError {
            results = []
            error = e
        } catch {
            results = []
        }
    }

    private func select(_ c: LyricsCandidate) {
        if let existing = model.collection.existingSong(matching: c.trackKey) {
            // Duplicate add → open the existing LP (RQ-6).
            model.libraryPath.append(.player(existing.id))
            return
        }
        var draft = AddSongDraft(candidate: c)
        if c.availability == .none { draft.lyrics = "" }
        model.libraryPath.append(.add(draft))
    }
}
