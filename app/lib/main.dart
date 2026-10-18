import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';

import 'app/app_model.dart';
import 'app/theme.dart';
import 'ui/add_song.dart';
import 'ui/components.dart';
import 'ui/library.dart';
import 'ui/mini_player.dart';
import 'ui/onboarding.dart';
import 'ui/phrase_box.dart';
import 'ui/player.dart';
import 'ui/saved.dart';
import 'ui/search.dart';
import 'ui/settings.dart';
import 'ui/translating.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
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
        builder: (context, _) => MaterialApp(
          title: 'DAY-OFF',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light.material,
          home: widget.model.settings.hasOnboarded ? const MainTabView() : const OnboardingView(),
        ),
      ),
    );
  }
}

/// Three bottom tabs from the UI prototype: Home (library), Likes (phrase box), My page (settings).
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
    final showMini = showChrome && model.nowPlaying != null && model.libraryPath.isEmpty;

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
              const PhraseBoxView(),
              const SettingsView(asTab: true),
            ],
          ),
          if (showMini)
            const Positioned(left: 20, right: 20, bottom: 12, child: MiniPlayer()),
          if (model.banner case final b?)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).padding.top + 4,
              child: BannerView(
                message: b.message,
                actionTitle: b.actionTitle,
                action: b.actionTitle == null ? null : model.openSettings,
                dismiss: () => model.showBanner(null),
              ),
            ),
        ]),
        bottomNavigationBar: showChrome ? _tabBar(model, t) : null,
      ),
    );
  }

  Widget _tabBar(AppModel model, AppTheme t) {
    Widget tab(AppTab tab, IconData icon, String label) {
      final on = model.selectedTab == tab;
      return Expanded(
        child: Semantics(
          label: label,
          selected: on,
          button: true,
          excludeSemantics: true,
          child: InkResponse(
            onTap: () {
              // Tapping Home again returns the library to its root.
              if (on && tab == AppTab.library) model.setPath([]);
              model.selectTab(tab);
            },
            child: SizedBox(height: 54, child: Icon(icon, size: 24, color: on ? t.textPrimary : t.disabled)),
          ),
        ),
      );
    }

    return Material(
      color: t.background,
      child: SafeArea(
        top: false,
        child: Row(children: [
          tab(AppTab.library, Icons.home_rounded, '홈'),
          tab(AppTab.phrases, Icons.favorite_rounded, '좋아요'),
          tab(AppTab.my, Icons.person_rounded, '마이페이지'),
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
      }}');

  Page<void> _page(Route r, int i) {
    final Widget child = switch (r) {
      SearchRoute(:final prefill) => SearchView(initialQuery: prefill),
      AddRoute(:final draft) => AddSongView(draft: draft),
      TranslatingRoute(:final songID) => TranslatingView(songID: songID),
      SavedRoute(:final songID) => SavedView(songID: songID),
      PlayerRoute(:final songID) => PlayerView(songID: songID),
    };
    return MaterialPage(key: _keyFor(r, i), child: child);
  }
}
