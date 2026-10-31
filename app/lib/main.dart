import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import 'app/app_model.dart';
import 'app/i18n.dart';
import 'app/theme.dart';
import 'ui/add_song.dart';
import 'ui/components.dart';
import 'ui/library.dart';
import 'ui/mini_player.dart';
import 'ui/login.dart';
import 'ui/phrase_box.dart';
import 'ui/player.dart';
import 'ui/quiz.dart';
import 'ui/saved.dart';
import 'ui/search.dart';
import 'ui/settings.dart';
import 'ui/spotify_library.dart';
import 'ui/translating.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = await AppModel.create();
  runApp(LyricsTranslatorApp(model: model));
}

class LyricsTranslatorApp extends StatefulWidget {
  final AppModel model;
  const LyricsTranslatorApp({super.key, required this.model});

  @override
  State<LyricsTranslatorApp> createState() => _LyricsTranslatorAppState();
}

class _LyricsTranslatorAppState extends State<LyricsTranslatorApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => widget.model.handleLifecycle(state);

  @override
  Widget build(BuildContext context) {
    return AppScope(
      model: widget.model,
      child: ListenableBuilder(
        listenable: widget.model,
        builder: (context, _) {
          final theme = widget.model.theme;
          PlayerPalette.brand = theme.brand;
          I18n.lang = widget.model.settings.uiLanguage;
          return MaterialApp(
            // A new key rebuilds every screen (including const widgets) when the app language changes.
            key: ValueKey('ui-${I18n.lang}'),
            title: 'Vynilo',
            debugShowCheckedModeBanner: false,
            theme: theme.material,
            builder: (context, child) => AppThemeScope(
              theme: theme,
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: theme.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
                child: child!,
              ),
            ),
            // Music plays through Spotify, so the app starts with the Spotify login (no skipping).
            home: widget.model.needsSpotifyLogin ? const SpotifyLoginView() : const MainTabView(),
          );
        },
      ),
    );
  }
}

/// Bottom tabs (Figma tab bar + Notion "홈화면 하단 바"): library, quiz, saved phrases, my page.
class MainTabView extends StatefulWidget {
  const MainTabView({super.key});
  @override
  State<MainTabView> createState() => _MainTabViewState();
}

class _MainTabViewState extends State<MainTabView> {
  final _libraryNav = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final onPlayer = model.selectedTab == AppTab.library && model.libraryPath.isNotEmpty && model.libraryPath.last is PlayerRoute;
    // The player is full-screen: no tab bar, as in the prototype.
    final showChrome = !onPlayer;
    final showMini = showChrome && model.nowPlaying != null;

    return PopScope(
      canPop: model.selectedTab == AppTab.library && model.libraryPath.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (model.selectedTab != AppTab.library) {
          model.selectTab(AppTab.library);
        } else {
          model.pop();
        }
      },
      child: Scaffold(
        body: Stack(children: [
          IndexedStack(
            index: model.selectedTab.index,
            children: [
              // The library stack is driven by model.libraryPath, so any screen can reset the flow.
              Navigator(
                key: _libraryNav,
                pages: [
                  const MaterialPage(key: ValueKey('library'), child: LibraryView()),
                  for (final (i, r) in model.libraryPath.indexed) _page(r, i),
                ],
                onDidRemovePage: (page) {
                  // Called for user pops (back gesture); declarative removals no longer match the path.
                  final path = model.libraryPath;
                  for (var i = 0; i < path.length; i++) {
                    if (_keyFor(path[i], i) == page.key) {
                      model.setPath(path.sublist(0, i));
                      return;
                    }
                  }
                },
              ),
              const QuizHomeView(),
              const PhraseBoxView(),
              const SettingsView(asTab: true),
            ],
          ),
          if (model.banner case final b?)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).padding.top + 4,
              child: BannerView(
                message: b.message,
                actionTitle: b.actionTitle,
                action: b.actionTitle == null ? null : (b.onAction ?? model.openSettings),
                dismiss: () => model.showBanner(null),
              ),
            ),
        ]),
        bottomNavigationBar: showChrome ? _tabBar(model, t, showMini) : null,
      ),
    );
  }

  /// The tab bar, with the mini player docked on top of it as one full-width box.
  Widget _tabBar(AppModel model, AppTheme t, bool showMini) {
    Widget tab(AppTab tab, IconData icon, String label) {
      final on = model.selectedTab == tab;
      return Expanded(
        child: Semantics(
          label: label,
          selected: on,
          button: true,
          excludeSemantics: true,
          // No splash on the tab bar: the icon and label change is the feedback.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              // Tapping Home again returns the library to its root.
              if (on && tab == AppTab.library) model.setPath([]);
              model.selectTab(tab);
            },
            child: SizedBox(
              height: 58,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 22, color: on ? t.textPrimary : t.textTertiary),
                const SizedBox(height: 3),
                Text(label, style: TextStyle(fontSize: 11, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? t.textPrimary : t.textTertiary)),
              ]),
            ),
          ),
        ),
      );
    }

    return Material(
      color: t.surface,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (showMini) ...[
            const MiniPlayer(),
            Divider(height: 1, thickness: 1, color: t.stroke.withValues(alpha: 0.6)),
          ],
          Row(children: [
            tab(AppTab.library, Icons.library_music_outlined, tr('라이브러리')),
            tab(AppTab.quiz, Icons.quiz_outlined, tr('퀴즈')),
            tab(AppTab.phrases, Icons.bookmark_border_rounded, tr('문장 저장함')),
            tab(AppTab.my, Icons.person_outline_rounded, tr('마이페이지')),
          ]),
        ]),
      ),
    );
  }

  ValueKey<String> _keyFor(Route r, int i) => ValueKey('$i:${switch (r) {
        SearchRoute() => 'search',
        AddRoute() => 'add',
        TranslatingRoute(:final songID) => 'translating:$songID',
        SavedRoute(:final songID) => 'saved:$songID',
        PlayerRoute(:final songID) => 'player:$songID',
        SpotifyListRoute(:final list) => 'spotify:${list.kind.name}:${list.id}',
      }}');

  Page<void> _page(Route r, int i) {
    final Widget child = switch (r) {
      SearchRoute(:final prefill, :final hint) => SearchView(initialQuery: prefill, hint: hint),
      AddRoute(:final draft) => AddSongView(draft: draft),
      TranslatingRoute(:final songID) => TranslatingView(songID: songID),
      SavedRoute(:final songID) => SavedView(songID: songID),
      PlayerRoute(:final songID) => PlayerView(songID: songID),
      SpotifyListRoute(:final list) => SpotifyTracksView(list: list),
    };
    return MaterialPage(key: _keyFor(r, i), child: child);
  }
}
