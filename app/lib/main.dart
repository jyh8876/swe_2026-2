import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import 'app/app_model.dart';
import 'app/i18n.dart';
import 'app/theme.dart';
import 'ui/add_song.dart';
import 'ui/cover_select.dart';
import 'ui/components.dart';
import 'ui/library.dart';
import 'ui/mini_player.dart';
import 'ui/onboarding.dart';
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

class _LyricsTranslatorAppState extends State<LyricsTranslatorApp>
    with WidgetsBindingObserver {
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
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      widget.model.handleLifecycle(state);

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
            title: 'Vinylo',
            debugShowCheckedModeBanner: false,
            theme: theme.material,
            builder: (context, child) => AppThemeScope(
              theme: theme,
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: theme.isDark
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark,
                child: child!,
              ),
            ),
            // First run: sign-in and the Gemini key (Figma 00 to 00-4); then the tabs.
            home: widget.model.settings.hasOnboarded
                ? const MainTabView()
                : const OnboardingFlow(),
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

class _MainTabViewState extends State<MainTabView>
    with SingleTickerProviderStateMixin {
  final _libraryNav = GlobalKey<NavigatorState>();
  // A short cross-fade when the tab changes; the tabs themselves stay alive in the IndexedStack.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final onPlayer =
        model.selectedTab == AppTab.library &&
        model.libraryPath.isNotEmpty &&
        model.libraryPath.last is PlayerRoute;
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
        body: Stack(
          children: [
            FadeTransition(
              opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
              child: IndexedStack(
                index: model.selectedTab.index,
                children: [
                  // The library stack is driven by model.libraryPath, so any screen can reset the flow.
                  Navigator(
                    key: _libraryNav,
                    pages: [
                      const MaterialPage(
                        key: ValueKey('library'),
                        child: LibraryView(),
                      ),
                      for (final (i, r) in model.libraryPath.indexed)
                        _page(r, i),
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
            ),
            // Swipe right from the left edge to go back (iOS and Android alike).
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v > 300) _swipeBack(model);
                },
              ),
            ),
            if (model.banner case final b?)
              Positioned(
                left: 0,
                right: 0,
                top: MediaQuery.of(context).padding.top + 4,
                child: BannerView(
                  message: b.message,
                  actionTitle: b.actionTitle,
                  action: b.actionTitle == null
                      ? null
                      : (b.onAction ?? model.openSettings),
                  dismiss: () => model.showBanner(null),
                ),
              ),
          ],
        ),
        bottomNavigationBar: showChrome ? _tabBar(model, t, showMini) : null,
      ),
    );
  }

  /// Edge swipe: one step back in the library stack, or from another tab to Home.
  /// The translating screen cannot be left (it is working); "saved" goes straight home like its button.
  void _swipeBack(AppModel model) {
    if (model.selectedTab != AppTab.library) {
      model.selectTab(AppTab.library);
    } else if (model.libraryPath.isNotEmpty) {
      switch (model.libraryPath.last) {
        case TranslatingRoute():
          break;
        case SavedRoute():
          model.setPath([]);
        default:
          model.pop();
      }
    }
  }

  /// The tab bar, with the mini player docked on top of it as one full-width box.
  Widget _tabBar(AppModel model, AppTheme t, bool showMini) {
    Widget tab(AppTab tab, IconData icon, IconData selectedIcon, String label, String caption) {
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
              if (!on) {
                HapticFeedback.selectionClick();
                _fade.forward(from: 0);
              }
              model.selectTab(tab);
            },
            child: SizedBox(
              height: 58,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(on ? selectedIcon : icon, size: 24, color: on ? t.textPrimary : t.textTertiary),
                  const SizedBox(height: 2),
                  // The spoken label above can be longer; this one is the short visible caption.
                  Text(
                    caption,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: -0.1,
                      color: on ? t.textPrimary : t.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: t.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showMini) ...[
              const MiniPlayer(),
              Divider(
                height: 1,
                thickness: 1,
                color: t.stroke.withValues(alpha: 0.6),
              ),
            ],
            Row(
              children: [
                tab(
                  AppTab.library,
                  Icons.home_outlined,
                  Icons.home_rounded,
                  tr('라이브러리'),
                  tr('홈'),
                ),
                tab(
                  AppTab.quiz,
                  Icons.quiz_outlined,
                  Icons.quiz_rounded,
                  tr('퀴즈'),
                  tr('퀴즈'),
                ),
                tab(
                  AppTab.phrases,
                  Icons.star_outline_rounded,
                  Icons.star_rounded,
                  tr('문장 저장함'),
                  tr('즐겨찾기'),
                ),
                tab(
                  AppTab.my,
                  Icons.person_outline_rounded,
                  Icons.person_rounded,
                  tr('마이페이지'),
                  tr('마이페이지'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ValueKey<String> _keyFor(Route r, int i) => ValueKey(
    '$i:${switch (r) {
      SearchRoute() => 'search',
      AddRoute() => 'add',
      CoverSelectRoute() => 'cover',
      TranslatingRoute(:final songID) => 'translating:$songID',
      SavedRoute(:final songID) => 'saved:$songID',
      PlayerRoute(:final songID) => 'player:$songID',
      SpotifyListRoute(:final list) => 'spotify:${list.kind.name}:${list.id}',
    }}',
  );

  Page<void> _page(Route r, int i) {
    final Widget child = switch (r) {
      SearchRoute(:final prefill, :final hint) => SearchView(
        initialQuery: prefill,
        hint: hint,
      ),
      AddRoute(:final draft) => AddSongView(draft: draft),
      CoverSelectRoute(:final draft) => CoverSelectView(draft: draft),
      TranslatingRoute(:final songID) => TranslatingView(songID: songID),
      SavedRoute(:final songID) => SavedView(songID: songID),
      PlayerRoute(:final songID, :final openTiming) => PlayerView(
        songID: songID,
        openTiming: openTiming,
      ),
      SpotifyListRoute(:final list) => SpotifyTracksView(list: list),
    };
    return MaterialPage(key: _keyFor(r, i), child: child);
  }
}
