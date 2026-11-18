import 'dart:convert';

import 'package:flutter/material.dart' hide Route;
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/lyrics.dart';
import 'components.dart';

/// Opens the in-app browser (Android System WebView = Chromium, iOS WKWebView) on the web search
/// for the song's LRC. Resolves to the lyrics the user took from a page, or null when they close
/// it. Nothing is fetched by the app on its own: the user picks the page.
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

  /// LRC found on the current page (or in an opened .lrc file), offered in the banner.
  String? _found;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() => _found = null);
          if (!_barFocus.hasFocus) _bar.text = _display(url);
        },
        onPageFinished: (_) => _afterLoad(),
        onNavigationRequest: _onNavigation,
      ))
      ..loadRequest(LyricsWebSearch.urlFor(widget.query));
  }

  @override
  void dispose() {
    _bar.dispose();
    _barFocus.dispose();
    super.dispose();
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
    // An .lrc file would be a download, which a web view cannot show: read it and offer it.
    if (u.path.toLowerCase().endsWith('.lrc')) {
      _readLrcFile(u);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _readLrcFile(Uri u) async {
    try {
      final r = await http.get(u).timeout(const Duration(seconds: 15));
      final text = r.statusCode == 200 ? utf8.decode(r.bodyBytes, allowMalformed: true) : '';
      final lrc = PageLyrics.lrc(text);
      if (!mounted) return;
      if (lrc == null) {
        showMessage(context, tr('이 파일에서 가사를 찾지 못했어요.'));
      } else {
        setState(() => _found = lrc);
      }
    } catch (_) {
      if (mounted) showMessage(context, tr('파일을 열지 못했어요.'));
    }
  }

  Future<void> _afterLoad() async {
    if (!mounted) return;
    final back = await _web.canGoBack(), forward = await _web.canGoForward();
    final lrc = PageLyrics.lrc(await _pageText('document.body ? document.body.innerText : ""'));
    if (!mounted) return;
    setState(() {
      _canBack = back;
      _canForward = forward;
      _found = lrc;
    });
  }

  /// Runs [js] and returns its string result (Android hands it back JSON-quoted).
  Future<String> _pageText(String js) async {
    try {
      final r = await _web.runJavaScriptReturningResult(js);
      if (r is String && r.length >= 2 && r.startsWith('"')) {
        try {
          return jsonDecode(r) as String;
        } catch (_) {}
      }
      return r is String ? r : '';
    } catch (_) {
      return '';
    }
  }

  /// "가사 가져오기": the selected text, else the LRC on the page.
  Future<void> _take() async {
    final selected = (await _pageText('window.getSelection ? window.getSelection().toString() : ""')).trim();
    if (!mounted) return;
    if (selected.isNotEmpty) {
      Navigator.pop(context, PageLyrics.lrc(selected) ?? selected);
      return;
    }
    if (_found != null) {
      Navigator.pop(context, _found);
      return;
    }
    showMessage(context, tr('가사 부분을 길게 눌러 선택한 다음 다시 눌러 주세요.'));
  }

  void _go(String input) {
    if (input.trim().isEmpty) return;
    _barFocus.unfocus();
    _web.loadRequest(LyricsWebSearch.urlFor(input));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    final found = _found;
    final timedLines = found == null ? 0 : found.split('\n').where((l) => RegExp(r'^\[\d').hasMatch(l)).length;
    return Scaffold(
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
        Expanded(child: WebViewWidget(controller: _web)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: found == null
              ? const SizedBox.shrink()
              : Material(
                  key: const ValueKey('found'),
                  color: t.surfaceRaised,
                  child: ListTile(
                    leading: Icon(Icons.lyrics_outlined, color: t.brand),
                    title: Text(tr('싱크 가사를 찾았어요'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
                    subtitle: Text(tr('{0}줄 · 시간 정보 포함', ['$timedLines']), style: TextStyle(fontSize: 12, color: t.textSecondary)),
                    trailing: FilledButton(
                      onPressed: () => Navigator.pop(context, found),
                      style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
                      child: Text(tr('이 가사 사용')),
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            decoration: BoxDecoration(color: t.background, border: Border(top: BorderSide(color: t.stroke))),
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(children: [
              IconButton(tooltip: tr('뒤로'), onPressed: _canBack ? _web.goBack : null, icon: const Icon(Icons.arrow_back_ios_new, size: 18)),
              IconButton(tooltip: tr('앞으로'), onPressed: _canForward ? _web.goForward : null, icon: const Icon(Icons.arrow_forward_ios, size: 18)),
              IconButton(tooltip: tr('새로고침'), onPressed: _web.reload, icon: const Icon(Icons.refresh, size: 20)),
              const Spacer(),
              FilledButton.icon(
                onPressed: _take,
                style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(tr('가사 가져오기')),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
