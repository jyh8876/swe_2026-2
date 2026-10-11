import SwiftUI
import PhotosUI
import LyricsCore

/// FG-03 Add to collection (RQ-6). Coming from search, saving needs exactly one tap.
struct AddSongView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var draft: AddSongDraft
    @State private var photoItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var duplicate: Song?
    @State private var showCloudNotice = false

    init(draft: AddSongDraft) {
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                coverPicker.frame(maxWidth: .infinity)

                field("제목", text: $draft.title, placeholder: "Song Title")
                field("아티스트", text: $draft.artist, placeholder: "Artist")

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel("가사")
                        Spacer()
                        if !draft.lyrics.isEmpty {
                            Text(LRCParser.parse(draft.lyrics).type == .synced ? "싱크 가사" : "일반 가사")
                                .font(.caption2).foregroundStyle(theme.textTertiary)
                        }
                    }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft.lyrics)
                            .font(.footnote.monospaced())
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(theme.textPrimary)
                            .frame(minHeight: 260)
                            .padding(8)
                        if draft.lyrics.isEmpty {
                            Text("가사를 불러오지 못하면 여기에 직접 붙여넣기\n[00:12.34] 형식의 LRC 가사도 인식해요")
                                .font(.footnote)
                                .foregroundStyle(theme.textTertiary)
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.stroke))
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button("저장", action: attemptSave)
                .buttonStyle(.primary)
                .disabled(!canSave)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(theme.background)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("컬렉션에 추가")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: photoItem) { _, item in
            Task { coverData = try? await item?.loadTransferable(type: Data.self) }
        }
        .alert("이미 컬렉션에 있는 노래예요", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), presenting: duplicate) { song in
            Button("기존 LP 열기") { model.libraryPath = [.player(song.id)] }
            Button("그래도 추가") { save() }
            Button("취소", role: .cancel) {}
        }
        .alert("가사가 선택한 AI 서비스로 전송돼요", isPresented: $showCloudNotice) {
            Button("계속") {
                model.settings.cloudNoticeAccepted = true
                save()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(model.settings.engine.badgeLabel) API로 가사를 보내 번역하고, 사용량은 내 API 계정에 청구돼요. 노래 한 곡에 약 $0.01 미만이에요.")
        }
    }

    private var coverPicker: some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(theme.surfaceRaised)
                    if let coverData, let image = platformImage(coverData) {
                        image.resizable().scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.title2.weight(.light))
                            Text("앨범 커버").font(.caption)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("앨범 커버 선택")
            Text("탭해서 나만의 커버로").font(.caption).foregroundStyle(theme.textSecondary)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(label)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary))
                .textFieldStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.stroke))
        }
    }

    private func attemptSave() {
        let key = TrackKey(title: draft.title, artist: draft.artist, duration: draft.duration)
        if let existing = model.collection.existingSong(matching: key) {
            duplicate = existing
            return
        }
        if model.settings.engine.requiresAPIKey && !model.settings.cloudNoticeAccepted {
            showCloudNotice = true
            return
        }
        save()
    }

    private func save() {
        if model.settings.engine.requiresAPIKey, model.apiKey(for: model.settings.engine) == nil {
            model.banner = AppModel.Banner(message: LLMError.missingAPIKey.userMessage, actionTitle: "설정")
        }
        let id = model.addSong(draft, cover: coverData)
        // Replace the add flow with the translating screen (linear flow, SSRD 4.1.2).
        model.libraryPath = [.translating(id)]
    }

    private func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
