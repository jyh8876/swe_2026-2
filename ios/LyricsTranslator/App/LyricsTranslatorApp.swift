import SwiftUI
import LyricsCore

@main
struct LyricsTranslatorApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.theme, AppTheme.theme(model.settings.theme))
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if model.settings.hasOnboarded {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .background(theme.background.ignoresSafeArea())
        .tint(theme.accent)
    }
}

/// Two bottom tabs: Library and Phrase box (SSRD 4.1.2).
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack(path: $model.libraryPath) {
                LibraryView()
                    .navigationDestination(for: Route.self) { route in
                        destination(for: route)
                    }
            }
            .tabItem { Label("라이브러리", systemImage: "books.vertical") }
            .tag(AppModel.Tab.library)

            NavigationStack {
                PhraseBoxView()
            }
            .tabItem { Label("문장 저장함", systemImage: "bookmark") }
            .tag(AppModel.Tab.phrases)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(
                    message: banner.message,
                    actionTitle: banner.actionTitle,
                    action: banner.actionTitle == nil ? nil : { model.banner = nil; model.libraryPath = []; model.showSettings = true },
                    dismiss: { model.banner = nil }
                )
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .sheet(isPresented: $model.showSettings) {
            NavigationStack { SettingsView() }
                .environment(\.theme, theme)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .search(let prefill):
            SearchView(initialQuery: prefill)
        case .add(let draft):
            AddSongView(draft: draft)
        case .translating(let id):
            TranslatingView(songID: id)
        case .saved(let id):
            SavedView(songID: id)
        case .player(let id):
            PlayerView(songID: id)
        }
    }
}
