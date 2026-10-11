import SwiftUI
import LyricsCore

/// FG-07 Line detail bottom sheet (RQ-11, ONRQ-5, ONRQ-12, ONRQ-13).
/// Generated on first tap with a skeleton loader, cached permanently afterwards.
struct LineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let songID: UUID
    let index: Int
    var canSeek: Bool
    var onReplay: () -> Void

    @State private var explanation: Explanation?
    @State private var error: LLMError?
    @State private var isLoading = false

    private var line: LyricLine? { model.collection.lines(for: songID).first { $0.index == index } }

    var body: some View {
        let saved = model.collection.isSaved(songID: songID, index: index)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line?.text ?? "")
                            .font(.headline)
                            .foregroundStyle(theme.textPrimary)
                        if let t = model.collection.translationText(songID: songID, index: index, target: model.target.code) {
                            Text(t).font(.subheadline).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Divider().overlay(theme.stroke)
                    content
                }
                .padding(20)
            }

            HStack(spacing: 10) {
                Button(action: { onReplay(); dismiss() }) {
                    Label("이 줄 다시 듣기", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.secondary)
                .disabled(!canSeek)
                .opacity(canSeek ? 1 : 0.4)
                .accessibilityHint(canSeek ? "" : "음악 앱이 이동을 지원하지 않거나 연결되지 않았어요")

                Button {
                    _ = model.toggleSaved(songID: songID, index: index)
                } label: {
                    Label(saved ? "담김" : "담기", systemImage: saved ? "star.fill" : "star")
                }
                .buttonStyle(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let explanation {
            explanationBody(explanation)
        } else if let error {
            VStack(alignment: .leading, spacing: 10) {
                Text(error == .refused ? "현재 엔진에서는 이 해설을 제공할 수 없어요." : "해설을 불러오지 못했어요 — 다시 시도")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                HStack {
                    Button("다시 시도") { Task { await load() } }
                    if model.settings.engine != .onDevice {
                        Button("온디바이스로 시도") { Task { await load(engine: EngineFactory.make(.onDevice, apiKey: nil)) } }
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        } else {
            SkeletonLines(count: 6)
        }

        if model.settings.engine == .onDevice, explanation != nil, let key = availableCloudEngine {
            Button {
                Task { await load(engine: EngineFactory.make(key, apiKey: model.apiKey(for: key))) }
            } label: {
                Label("더 정확한 해설 보기 (내 API 키)", systemImage: "sparkles")
                    .font(.caption)
            }
            .foregroundStyle(theme.textSecondary)
            .disabled(isLoading || !model.network.isOnline)
        }
    }

    private var availableCloudEngine: EngineKind? {
        [EngineKind.claude, .gemini].first { model.apiKey(for: $0) != nil }
    }

    private func explanationBody(_ e: Explanation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !e.expressions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("핵심 표현")
                    ForEach(e.expressions, id: \.phrase) { expr in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(expr.phrase)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(theme.marker))
                                .foregroundStyle(theme.textPrimary)
                            Text(expr.meaning)
                                .font(.subheadline)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            block("문장 구조", e.structure)
            block("이럴 때 써요", e.usage)
            if !e.example.isEmpty {
                Text("예문: \(e.example)")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ title: String, _ body: String) -> some View {
        if !body.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title)
                Text(body).font(.subheadline).foregroundStyle(theme.textPrimary)
            }
        }
    }

    private func load(engine: (any TranslationEngine)? = nil) async {
        if engine == nil, let cached = model.cachedExplanation(songID: songID, index: index) {
            explanation = cached
            return
        }
        isLoading = true
        error = nil
        if engine != nil { explanation = nil }
        defer { isLoading = false }
        do {
            explanation = try await model.explain(songID: songID, index: index, engine: engine)
        } catch let e as LLMError {
            error = e
        } catch {
            self.error = .unavailable("해설을 불러오지 못했어요.")
        }
    }
}
