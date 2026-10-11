import SwiftUI
import LyricsCore

/// FG-01 Library and FG-01-1 Empty state (RQ-9, RQ-13, RQ-17, DCR-2, DCR-8).
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var pendingDelete: Song?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let songs = model.collection.songsNewestFirst
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NowPlayingBar()

                if songs.isEmpty {
                    emptyState
                } else {
                    header
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        addCard
                        ForEach(songs) { song in
                            Button { open(song) } label: {
                                LPCard(song: song,
                                       isTranslating: model.isTranslating(song.id),
                                       highlighted: model.nowPlayingSong?.id == song.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: song) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("DAY-OFF").font(AppFont.brand).foregroundStyle(theme.textPrimary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
            }
        }
        .confirmationDialog("이 노래를 삭제할까요?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { song in
            Button("삭제 (저장한 문장은 유지)", role: .destructive) { model.deleteSong(song.id, keepPhrases: true); pendingDelete = nil }
            Button("저장한 문장까지 모두 삭제", role: .destructive) { model.deleteSong(song.id, keepPhrases: false); pendingDelete = nil }
            Button("취소", role: .cancel) { pendingDelete = nil }
        }
    }

    private var header: some View {
        let stats = model.collection.stats
        return HStack(alignment: .firstTextBaseline) {
            Text("내 컬렉션")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("\(stats.songs)곡 · 정복 \(stats.conquered)곡")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private var addCard: some View {
        Button { model.libraryPath.append(.search(prefill: "")) } label: {
            VStack(alignment: .leading, spacing: 6) {
                AddSongTile()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 20)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("노래 추가")
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            Button { model.libraryPath.append(.search(prefill: "")) } label: {
                AddSongTile().frame(width: 200, height: 200)
            }
            .buttonStyle(.plain)
            .padding(.top, 48)
            .accessibilityLabel("노래 추가")

            VStack(spacing: 8) {
                Text("첫 노래를 추가해보세요")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text("좋아하는 팝송을 검색해서 LP로 모아요")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }

            CuratedShelvesView(shelves: model.shelves) { entry, shelf in
                model.libraryPath.append(.search(prefill: "\(entry.title) \(entry.artist)"))
                _ = shelf
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func menu(for song: Song) -> some View {
        if song.isConquered {
            Button { model.setConquered(song.id, false) } label: { Label("정복 취소", systemImage: "arrow.uturn.backward") }
        } else if model.canMarkConquered(song.id) {
            Button { model.setConquered(song.id, true) } label: { Label("이 노래 정복!", systemImage: "trophy") }
        }
        if song.status == .failed {
            Button { model.startTranslation(songID: song.id) } label: { Label("번역 재시도", systemImage: "arrow.clockwise") }
        }
        Button { model.retranslate(song.id) } label: { Label("현재 엔진으로 다시 번역", systemImage: "character.bubble") }
        Button(role: .destructive) { pendingDelete = song } label: { Label("삭제", systemImage: "trash") }
    }

    private func open(_ song: Song) {
        if model.isTranslating(song.id) {
            model.libraryPath.append(.translating(song.id))
        } else {
            model.libraryPath.append(.player(song.id))
        }
    }
}

struct AddSongTile: View {
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.title2.weight(.light))
                    Text("노래 추가").font(.caption)
                }
                .foregroundStyle(theme.textSecondary)
            }
            .contentShape(Rectangle())
    }
}

/// DCR-2: shows what the user's music app is playing; tap → player, or "Add this song".
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let snapshot = model.nowPlaying, !snapshot.track.title.isEmpty {
            let song = model.nowPlayingSong
            Button {
                if let song {
                    model.libraryPath.append(.player(song.id))
                } else {
                    model.libraryPath.append(.search(prefill: cleanedQuery(snapshot.track)))
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                        .symbolEffect(.variableColor, isActive: snapshot.isPlaying)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(snapshot.track.artist).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text(song == nil ? "이 노래 추가" : "가사 보기")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceRaised))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("지금 재생 중: \(snapshot.track.title), \(snapshot.track.artist)")
        }
    }

    /// ONRQ-4: strip "Official MV" etc. and split "Artist - Title" before searching.
    private func cleanedQuery(_ track: TrackKey) -> String {
        if let split = TrackNormalizer.splitArtistTitle(track.title) {
            return "\(TrackNormalizer.normalize(split.title)) \(split.artist)"
        }
        return "\(TrackNormalizer.normalize(track.title)) \(TrackNormalizer.primaryArtist(track.artist))"
    }
}

/// Curated shelves (RQ-17, DCR-8). Horizontal rows of entries with a "synced" guarantee.
struct CuratedShelvesView: View {
    @Environment(\.theme) private var theme
    let shelves: [CuratedShelf]
    let onSelect: (CuratedShelf.Entry, CuratedShelf) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(shelves) { shelf in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(shelf.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.textPrimary)
                        Text(shelf.subtitle).font(.caption2).foregroundStyle(theme.textTertiary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(shelf.songs) { entry in
                                Button { onSelect(entry, shelf) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8).fill(theme.surface)
                                            VinylRecord(grooves: 2).padding(18)
                                        }
                                        .frame(width: 110, height: 110)
                                        Text(entry.title).font(.caption.weight(.medium)).foregroundStyle(theme.textPrimary).lineLimit(1)
                                        Text(entry.artist).font(.caption2).foregroundStyle(theme.textSecondary).lineLimit(1)
                                    }
                                    .frame(width: 110, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
