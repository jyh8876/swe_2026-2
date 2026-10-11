import SwiftUI
import UniformTypeIdentifiers
import LyricsCore

/// FG-09 Settings (RQ-14, RQ-15, RQ-18, PR-10, DCR-9 data section). Platform-standard Form.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDeleteAll = false
    @State private var exportDocument: ExportFile?
    @State private var showImporter = false
    @State private var message: String?
    @State private var downloadProgress: Double?
    @State private var modelInstalled = ModelManager.isInstalled

    var body: some View {
        @Bindable var model = model
        Form {
            Section("번역 엔진") {
                Picker("번역 엔진", selection: $model.settings.engine) {
                    Text("온디바이스 (기본)").tag(EngineKind.onDevice)
                    Text("Claude API").tag(EngineKind.claude)
                    Text("Gemini API").tag(EngineKind.gemini)
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if model.settings.engine == .onDevice {
                    LabeledContent("사용 중", value: EngineFactory.label(for: .onDevice))
                    if let reason = model.device.onDeviceUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if !FoundationModelsEngine.isSupported {
                        modelDownloadRow
                    }
                } else {
                    NavigationLink("API 키 입력") { APIKeyEntryView(onDone: nil) }
                }
            }

            Section("테마") {
                Picker("테마 선택", selection: $model.settings.theme) {
                    ForEach(AppTheme.ID.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("언어") {
                Picker("번역할 언어의 기본값", selection: $model.settings.targetLanguage) {
                    ForEach(Language.supported) { Text($0.nativeName).tag($0.code) }
                }
            }

            Section("가사 기본 설정") {
                Toggle("해석 표시", isOn: $model.settings.showTranslation)
            }

            Section("음악 앱 연결") {
                connectionRow("Spotify", .spotify)
                connectionRow("Apple Music", .appleMusic)
                Text("그 밖의 음악 앱은 가사 공부 모드로 사용할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("데이터") {
                LabeledContent("저장 공간 사용량", value: StorageMeter.format(model.storageUsedBytes))
                Button("컬렉션 내보내기") {
                    if let data = try? model.exportData() { exportDocument = ExportFile(data: data) }
                }
                Button("컬렉션 가져오기") { showImporter = true }
                if modelInstalled {
                    Button("온디바이스 모델 삭제", role: .destructive) {
                        ModelManager.deleteModel()
                        modelInstalled = false
                    }
                }
                Button("전체 삭제", role: .destructive) { confirmDeleteAll = true }
            }

            Section {
                LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
            } footer: {
                Text("가사는 LRCLIB에서 가져와요. 팀이 운영하는 서버는 없고, 데이터는 이 기기에만 저장돼요.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("설정")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") { dismiss() }
            }
        }
        .confirmationDialog("모든 데이터를 삭제할까요?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("전체 삭제", role: .destructive) {
                model.deleteAll()
                modelInstalled = false
                dismiss()
            }
        } message: {
            Text("컬렉션, 번역, 저장한 문장, 커버, 모델 파일, API 키가 모두 삭제돼요. 되돌릴 수 없어요.")
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: "LyricsTranslator-collection") { result in
            if case .failure = result { message = "내보내지 못했어요." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importFile(result)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) {}
        }
    }

    /// PR-9 / ONRQ-14: download needs Wi-Fi-sized room; progress is shown inline.
    @ViewBuilder
    private var modelDownloadRow: some View {
        if let downloadProgress {
            VStack(alignment: .leading, spacing: 6) {
                Text("모델 다운로드 중… \(Int(downloadProgress * 100))%").font(.subheadline)
                ProgressView(value: downloadProgress).tint(theme.accent)
            }
        } else if modelInstalled {
            LabeledContent("온디바이스 모델", value: "설치됨")
        } else {
            Button("온디바이스 모델 다운로드 (\(StorageMeter.format(ModelManager.approximateBytes)))") {
                guard ModelManager.hasRoomForDownload(model.device) else {
                    message = "저장 공간이 부족해요. 모델 크기보다 500MB 이상 여유가 필요해요."
                    return
                }
                Task { await downloadModel() }
            }
        }
    }

    private func downloadModel() async {
        downloadProgress = 0
        do {
            try await ModelManager.download { downloadProgress = $0 }
            modelInstalled = true
        } catch {
            message = "모델을 내려받지 못했어요. 다시 시도해 주세요."
        }
        downloadProgress = nil
    }

    private func connectionRow(_ title: String, _ id: SourceID) -> some View {
        let connected = model.settings.connectedSources.contains(id)
        return HStack {
            Text(title)
            Spacer()
            Button(connected ? "연결됨 · 해제" : "연결") {
                if connected {
                    model.disconnect(id)
                } else {
                    Task { await model.connect(id) }
                }
            }
            .foregroundStyle(connected ? .secondary : theme.accent)
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let report = try model.importData(Data(contentsOf: url))
            message = "노래 \(report.songsAdded)곡, 문장 \(report.phrasesAdded)개를 가져왔어요."
        } catch ImportError.newerSchema {
            message = "더 새로운 버전의 앱에서 만든 파일이에요. 앱을 업데이트해 주세요."
        } catch {
            message = "파일을 읽을 수 없어요. 아무것도 변경되지 않았어요."
        }
    }
}

/// API key entry with "Verify key" (RQ-14, ONRQ-10). Keys are masked after saving and stored
/// only in the Keychain.
struct APIKeyEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var onDone: (() -> Void)?

    @State private var provider: EngineKind = .claude
    @State private var key = ""
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, verifying, ok, failed(String) }

    var body: some View {
        Form {
            Picker("제공자", selection: $provider) {
                Text("Claude").tag(EngineKind.claude)
                Text("Gemini").tag(EngineKind.gemini)
            }
            .pickerStyle(.segmented)

            Section {
                if let saved = model.apiKey(for: provider), key.isEmpty {
                    LabeledContent("저장된 키", value: maskSecret(saved))
                }
                HStack {
                    SecureField("API 키 입력", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button("키 확인") { Task { await verify() } }
                        .disabled(key.isEmpty || status == .verifying)
                }
                switch status {
                case .idle: EmptyView()
                case .verifying: ProgressView()
                case .ok: Label("키가 확인됐어요", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .failed(let why): Label(why, systemImage: "xmark.circle").foregroundStyle(.red)
                }
            } footer: {
                Text(helpText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("API 키")
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) { Button("완료", action: onDone) }
            }
        }
        .onAppear {
            if model.settings.engine.requiresAPIKey { provider = model.settings.engine }
        }
    }

    private var helpText: String {
        switch provider {
        case .gemini:
            return "Google AI Studio(aistudio.google.com)에서 API 키를 만들 수 있어요. Gemini 앱 구독은 API 키가 아니에요. 가사는 Google로 전송되고 사용량은 내 계정에 청구돼요."
        default:
            return "Claude Console(console.anthropic.com)에서 API 키를 만들 수 있어요. Claude Pro/Max 구독은 API 키가 아니에요. 가사는 Anthropic으로 전송되고 사용량은 내 계정에 청구돼요 (한 곡에 약 $0.006)."
        }
    }

    private func verify() async {
        status = .verifying
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch provider {
            case .gemini: try await GeminiEngine(apiKey: trimmed).verifyKey()
            default: try await ClaudeEngine(apiKey: trimmed).verifyKey()
            }
            if let secret = SecretKey.apiKey(for: provider) {
                try model.secureStore.set(trimmed, for: secret)
            }
            model.settings.engine = provider
            key = ""
            status = .ok
        } catch let e as LLMError {
            status = .failed(e.userMessage)
        } catch {
            status = .failed("키를 저장하지 못했어요.")
        }
    }
}

/// JSON export wrapper for `fileExporter`.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
