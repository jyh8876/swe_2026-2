import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import 'components.dart';

/// Opens the in-app browser (Android System WebView = Chromium, iOS WKWebView) on the web search
/// for the song's LRC. Resolves to the text the user selected on a page, or null when they close
/// it. The app never reads or extracts a page by itself (feedback 11/19 #13, option 2): only what
/// the user selects is taken, as with copy and paste.
///
/// Toolbar like KakaoTalk's in-app browser (feedback 11/22 #14): back, forward, reload and "open in
/// the browser" along the bottom. The last one is the way out when a site's bot check (Cloudflare on
/// Lyricsify) does not pass inside a web view (#3): the user copies there and pastes on return.
Future<String?> openLyricsBrowser(BuildContext context, {required String title, String artist = ''}) {
  return Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => LyricsBrowserView(query: LyricsWebSearch.query(title: title, artist: artist)),
  ));
}

class LyricsBrowserView extends StatefulWidget {
  final String query;
  const LyricsBrowserView({super.key, required this.query});
  @override
  State<LyricsBrowserView> createState() => _LyricsBrowserViewState();
}

class _LyricsBrowserViewState extends State<LyricsBrowserView> {
  late final WebViewController _web;
  late final _bar = TextEditingController(text: widget.query);
  final _barFocus = FocusNode();
  int _progress = 0;
  bool _canBack = false, _canForward = false;

  /// The text the user has selected on the page, reported by the page as it changes.
  String _selection = '';

  static const _safariUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  /// Reads the current selection. Polled from the app rather than reported by the page: a listener
  /// and a JavaScript channel would leave app objects in every page, including Cloudflare's bot check,
  /// which can take them for automation (feedback 11/22 #3, hypothesis 4).
  static const _readSelection = "window.getSelection ? String(window.getSelection()) : ''";
  Timer? _poll;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // WKWebView's own user agent lacks the Version/Safari tokens, so sites with a bot check (Lyricsify)
      // fail to verify; a regular mobile Safari agent passes.
      ..setUserAgent(Platform.isIOS ? _safariUserAgent : null)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() => _selection = '');
          if (!_barFocus.hasFocus) _bar.text = _display(url);
          _syncHistory();
        },
        onPageFinished: (_) => _syncHistory(),
        // Pages that change the address without loading (search results, single-page sites) would leave
        // the arrows stale, which is why they seemed not to work on Android.
        onUrlChange: (_) => _syncHistory(),
        onNavigationRequest: _onNavigation,
      ))
      ..loadRequest(LyricsWebSearch.urlFor(widget.query));
    // iOS: swipe from the left edge for the previous page, as in Safari.
    final platform = _web.platform;
    if (platform is WebKitWebViewController) platform.setAllowsBackForwardNavigationGestures(true);
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _pollSelection());
  }

  Future<void> _pollSelection() async {
    if (_reading || !mounted) return;
    _reading = true;
    try {
      final r = await _web.runJavaScriptReturningResult(_readSelection);
      var text = r is String ? r : '$r';
      // Android returns the value JSON-encoded, iOS as it is.
      if (Platform.isAndroid && text.startsWith('"')) text = jsonDecode(text) as String;
      if (mounted && text != _selection) setState(() => _selection = text);
    } catch (_) {
      // Page still loading or navigating: try again on the next tick.
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _bar.dispose();
    _barFocus.dispose();
    super.dispose();
  }

  /// Whether the page history has somewhere to go, for the arrow buttons.
  Future<void> _syncHistory() async {
    final back = await _web.canGoBack(), forward = await _web.canGoForward();
    if (mounted && (back != _canBack || forward != _canForward)) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  /// The search words on a search page, the address elsewhere.
  String _display(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    if (u.host.contains('google.') && u.path == '/search') return u.queryParameters['q'] ?? url;
    return url;
  }

  Future<NavigationDecision> _onNavigation(NavigationRequest r) async {
    final u = Uri.tryParse(r.url);
    // App links (intent://, market://) would leave the app; stay on the web.
    if (u == null || (u.scheme != 'https' && u.scheme != 'http')) return NavigationDecision.prevent;
    // A file download (.lrc) cannot be shown here, and the app does not fetch it itself.
    if (u.path.toLowerCase().endsWith('.lrc')) {
      if (mounted) showMessage(context, tr('파일은 열 수 없어요. 가사가 보이는 페이지에서 선택해 주세요.'));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  int get _selectedLines => _selection.split('\n').where((l) => l.trim().isNotEmpty).length;

  /// "선택한 가사 가져오기": the text the user selected, as it is.
  Future<void> _take() async {
    final text = _selection.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, PageLyrics.lrc(text) ?? text);
  }

  void _go(String input) {
    if (input.trim().isEmpty) return;
    _barFocus.unfocus();
    _web.loadRequest(LyricsWebSearch.urlFor(input));
  }

  Future<void> _goBack() async {
    await _web.goBack();
    _syncHistory();
  }

  Future<void> _goForward() async {
    await _web.goForward();
    _syncHistory();
  }

  /// Opens this page in the phone's browser and closes the in-app one: lyrics copied there are offered
  /// for pasting in the lyrics field on return.
  Future<void> _openOutside() async {
    final url = await _web.currentUrl();
    final u = url == null ? null : Uri.tryParse(url);
    if (u == null || !mounted) return;
    try {
      await Links.open(u);
    } catch (_) {
      if (mounted) showMessage(context, tr('브라우저를 열지 못했어요.'));
      return;
    }
    if (!mounted) return;
    showMessage(context, tr('가사를 복사해서 돌아오면 가사 칸에 붙여넣을 수 있어요.'));
    Navigator.pop(context);
  }

  /// The system back button goes back in the page history before it closes the browser.
  Future<void> _back() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final n = _selectedLines;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: t.background,
        appBar: AppBar(
          backgroundColor: t.background,
          titleSpacing: 0,
          leading: IconButton(tooltip: tr('닫기'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          title: Container(
            height: 40,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(20)),
            child: TextField(
              controller: _bar,
              focusNode: _barFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: _go,
              onTap: () => _bar.selection = TextSelection(baseOffset: 0, extentOffset: _bar.text.length),
              style: TextStyle(fontSize: 14, color: t.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                prefixIcon: Icon(Icons.search, size: 18, color: t.textTertiary),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
              ),
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: _progress > 0 && _progress < 100
                ? LinearProgressIndicator(value: _progress / 100, minHeight: 2, color: t.brand, backgroundColor: Colors.transparent)
                : const SizedBox(height: 2),
          ),
        ),
        body: Column(children: [
          // What to do, visible from the start (13-1).
          Container(
            width: double.infinity,
            color: t.surfaceRaised,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              _step('1', tr('가사를 길게 눌러 선택')),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 14, color: t.textTertiary)),
              _step('2', tr('가져오기')),
            ]),
          ),
          Expanded(child: WebViewWidget(controller: _web)),
          SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(color: t.background, border: Border(top: BorderSide(color: t.stroke))),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: n == 0 ? null : _take,
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: t.onAccent,
                      disabledBackgroundColor: t.surfaceRaised,
                      disabledForegroundColor: t.textTertiary,
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(n == 0 ? tr('가사를 선택해 주세요') : tr('선택한 가사 가져오기 ({0}줄)', ['$n'])),
                  ),
                ),
                // KakaoTalk-style toolbar: evenly spaced, greyed out when there is nowhere to go.
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  IconButton(tooltip: tr('이전 페이지'), onPressed: _canBack ? _goBack : null, icon: const Icon(Icons.chevron_left_rounded, size: 30)),
                  IconButton(tooltip: tr('다음 페이지'), onPressed: _canForward ? _goForward : null, icon: const Icon(Icons.chevron_right_rounded, size: 30)),
                  IconButton(tooltip: tr('새로고침'), onPressed: _web.reload, icon: const Icon(Icons.refresh_rounded, size: 24)),
                  IconButton(tooltip: tr('브라우저에서 열기'), onPressed: _openOutside, icon: const Icon(Icons.open_in_browser_rounded, size: 24)),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _step(String n, String text) {
    final t = context.theme;
    return Flexible(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
          child: Text(n, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.onAccent)),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.textPrimary))),
      ]),
    );
  }
}

/// "가사는 어떻게 불러오나요?" (feedback 11/19 #9): search with .lrc, copy the timed lyrics,
/// paste. The steps play one after another; the motion graphics from design replace them later.
Future<void> showLyricsGuide(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const LyricsGuideView()));

class LyricsGuideView extends StatefulWidget {
  const LyricsGuideView({super.key});
  @override
  State<LyricsGuideView> createState() => _LyricsGuideViewState();
}

class _LyricsGuideViewState extends State<LyricsGuideView> with SingleTickerProviderStateMixin {
  late final _play = AnimationController(vsync: this, duration: const Duration(seconds: 9));

  @override
  void initState() {
    super.initState();
    _play.repeat();
  }

  @override
  void dispose() {
    _play.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final still = MediaQuery.of(context).disableAnimations;
    return Scaffold(
      appBar: AppBar(title: Text(tr('가사 불러오는 법')), centerTitle: true),
      body: AnimatedBuilder(
        animation: _play,
        builder: (context, _) {
          // Which step is playing: each takes a third of the loop.
          final active = still ? -1 : (_play.value * 3).floor();
          final within = still ? 1.0 : (_play.value * 3) % 1;
          return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
            _card(0, active, tr('노래를 .lrc 와 함께 검색해요'), tr('노래 추가 화면의 "가사 검색" 버튼을 누르면 제목·아티스트 뒤에 .lrc 를 붙여 검색해요.'),
                _searchBar('Count on Me Bruno Mars .lrc', active == 0 ? within : 1)),
            _card(1, active, tr('시간이 붙은 가사를 길게 눌러 복사해요'), tr('[00:13.04] 처럼 시간이 붙은 가사가 LRC 가사예요. 길게 눌러 처음부터 끝까지 선택해요.'),
                _lrcSample(active == 1 ? within : 1)),
            _card(2, active, tr('가사 칸에 붙여넣어요'), tr('시간 정보가 있으면 자동으로 알아보고, 노래에 맞춰 가사가 넘어가요.'), _pasted(active == 2 ? within : 1)),
            const SizedBox(height: 8),
            Text(tr('LRC 가사가 없으면 일반 가사를 붙여넣어도 돼요. 재생 화면에서 탭으로 싱크를 맞출 수 있어요.'),
                style: TextStyle(fontSize: 13, color: t.textSecondary, height: 1.5)),
          ]);
        },
      ),
    );
  }

  Widget _card(int i, int active, String title, String body, Widget demo) {
    final t = context.theme;
    final on = active == i || active < 0;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: on ? 1 : 0.45,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active == i ? t.accent : t.stroke),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
              child: Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.onAccent)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary))),
          ]),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(fontSize: 13, color: t.textSecondary, height: 1.45)),
          const SizedBox(height: 12),
          demo,
        ]),
      ),
    );
  }

  /// The query typing itself out.
  Widget _searchBar(String q, double p) {
    final t = context.theme;
    final shown = q.substring(0, (q.length * (p * 1.6).clamp(0.0, 1.0)).round());
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: t.background, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Icon(Icons.search, size: 18, color: t.textTertiary),
        const SizedBox(width: 8),
        Expanded(child: Text(shown, maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(fontSize: 13, color: t.textPrimary))),
      ]),
    );
  }

  static const _sample = ['[00:13.04] You can count on me like one, two, three', "[00:16.52] I'll be there", '[00:18.11] And I know when I need it'];

  /// The LRC lines getting selected one by one.
  Widget _lrcSample(double p) {
    final t = context.theme;
    final selected = (p * 1.4 * _sample.length).floor();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: t.background, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < _sample.length; i++)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            color: i < selected ? t.accent.withValues(alpha: 0.25) : Colors.transparent,
            child: Text(_sample[i], style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: t.textPrimary)),
          ),
      ]),
    );
  }

  /// The pasted lyrics and the recognised mark.
  Widget _pasted(double p) {
    final t = context.theme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: t.stroke)),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: p > 0.25 ? 1 : 0,
          child: Text(_sample.join('\n'), style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: t.textPrimary)),
        ),
      ),
      const SizedBox(height: 8),
      AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: p > 0.5 ? 1 : 0,
        child: Row(children: [
          Icon(Icons.check_circle_rounded, size: 16, color: t.brandInk),
          const SizedBox(width: 6),
          Text(tr('싱크 가사를 인식했어요'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.brandInk)),
        ]),
      ),
    ]);
  }
}


/// "곡명 – 아티스트  가사 검색 ↗": opens the in-app lyrics search for the song being typed.
class LyricsSearchChip extends StatelessWidget {
  final String title, artist;
  final VoidCallback onTap;
  const LyricsSearchChip({super.key, required this.title, required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: t.surface,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(
                  [title.trim(), artist.trim()].where((x) => x.isNotEmpty).join(' – '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: t.textPrimary),
                ),
              ),
              Text(' ${tr('가사 검색')}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary)),
              const SizedBox(width: 6),
              Icon(Icons.north_east, size: 16, color: t.textPrimary),
            ]),
          ),
        ),
      ),
    );
  }
}


/// "클립보드에서 붙여넣기": appears once the clipboard holds text (after copying lyrics in the browser
/// or another app) and puts it into [controller]. `hasStrings` does not trigger iOS's paste prompt;
/// the text itself is read only when the button is tapped.
class ClipboardPasteChip extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback? onPasted;
  const ClipboardPasteChip({super.key, required this.controller, this.onPasted});
  @override
  State<ClipboardPasteChip> createState() => _ClipboardPasteChipState();
}

class _ClipboardPasteChipState extends State<ClipboardPasteChip> with WidgetsBindingObserver {
  bool _has = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    bool has;
    try {
      has = await Clipboard.hasStrings();
    } catch (_) {
      has = false;
    }
    if (mounted && has != _has) setState(() => _has = has);
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    widget.controller.text = PageLyrics.lrc(text) ?? text;
    widget.onPasted?.call();
    _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!_has) return const SizedBox();
    final t = context.theme;
    return Material(
      color: t.surface,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _paste,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.content_paste_rounded, size: 16, color: t.textPrimary),
            const SizedBox(width: 6),
            Text(tr('클립보드에서 붙여넣기'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.textPrimary)),
          ]),
        ),
      ),
    );
  }
}
