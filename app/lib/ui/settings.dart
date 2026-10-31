import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/collection.dart';
import '../core/llm.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'calendar.dart';
import 'components.dart';
import 'engine_settings.dart';
import 'share_card.dart';

/// FG-09 Settings (RQ-14, RQ-15, RQ-18, PR-10).
class SettingsView extends StatefulWidget {
  /// Shown as the "My page" tab (no close button) or pushed as a full-screen page.
  final bool asTab;
  const SettingsView({super.key, this.asTab = false});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  double? downloadProgress;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final s = model.settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.asTab ? tr('마이페이지') : tr('설정')),
        automaticallyImplyLeading: false,
        actions: [
          if (!widget.asTab)
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('완료'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (widget.asTab) ...[
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: MyStats()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: SectionLabel(tr('내 컬렉션 달력'))),
              const CollectionCalendar(),
            ]),
          ),
          if (model.collection.songs.isNotEmpty) _section(null, [_nav(tr('내 컬렉션 자랑하기'), () => showShareCard(context))]),
        ],
        _section(tr('테마'), [
          ListTile(
            title: Text(tr('배경'), style: TextStyle(color: t.textPrimary)),
            trailing: SegmentedButton<ThemeBase>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: t.accent,
                selectedForegroundColor: t.onAccent,
                foregroundColor: t.textSecondary,
                side: BorderSide(color: t.stroke),
                visualDensity: VisualDensity.compact,
              ),
              segments: [for (final b in ThemeBase.values) ButtonSegment(value: b, label: Text(tr(b.label), style: const TextStyle(fontSize: 13)))],
              selected: {s.themeBase},
              onSelectionChanged: (v) => model.updateSettings((x) => x.themeBase = v.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('포인트 색'), style: TextStyle(fontSize: 16, color: t.textPrimary)),
              const SizedBox(height: 12),
              Row(children: [
                for (final a in AccentColor.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Semantics(
                      button: true,
                      selected: s.accent == a,
                      label: tr('포인트 색 {0}', [a.label]),
                      excludeSemantics: true,
                      child: GestureDetector(
                        onTap: () => model.updateSettings((x) => x.accent = a),
                        child: Column(children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: a.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: s.accent == a ? t.textPrimary : Colors.transparent, width: 2.5),
                            ),
                            child: s.accent == a ? const Icon(Icons.check, size: 18, color: Color(0xFF16171B)) : null,
                          ),
                          const SizedBox(height: 4),
                          Text(tr(a.label), style: TextStyle(fontSize: 11, color: t.textTertiary)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
        ]),
        _section(tr('번역 엔진'), [
          for (final (kind, label) in [
            (EngineKind.onDevice, tr('온디바이스 (기본)')),
            (EngineKind.vynilo, tr('Vynilo 서버')),
            (EngineKind.gateway, tr('LLM 게이트웨이')),
            (EngineKind.claude, 'Claude API'),
            (EngineKind.gemini, 'Gemini API'),
          ])
            _radio(label, s.engine == kind, () => model.updateSettings((x) => x.engine = kind)),
          if (s.engine == EngineKind.onDevice) ...[
            _row(tr('사용 중'), trailing: EngineFactory.label(EngineKind.onDevice)),
            _modelDownloadRow(model),
          ] else if (s.engine == EngineKind.vynilo || s.engine == EngineKind.gateway) ...[
            _row(tr('사용 중'), trailing: _endpointSummary(model)),
            _nav(s.engine == EngineKind.vynilo ? tr('서버 설정') : tr('게이트웨이 설정'),
                () => Navigator.push(context, MaterialPageRoute(builder: (_) => EndpointSettingsView(kind: s.engine)))),
          ] else
            _nav(tr('API 키 입력'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const APIKeyEntryView()))),
        ]),
        _section(tr('언어'), [
          ListTile(
            leading: Icon(Icons.language, color: t.textSecondary),
            // The English word stays visible so a user can always find the way back.
            title: Text(I18n.lang == 'en' ? 'App language' : '${tr('앱 언어')} · App language', style: TextStyle(color: t.textPrimary)),
            trailing: _languageMenu(s.uiLanguage, Language.uiLanguages, (v) => model.updateSettings((x) => x.uiLanguage = v)),
          ),
          ListTile(
            leading: Icon(Icons.translate, color: t.textSecondary),
            title: Text(tr('번역할 언어'), style: TextStyle(color: t.textPrimary)),
            subtitle: Text(tr('가사를 이 언어로 번역해요'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            trailing: _languageMenu(s.targetLanguage, Language.supported, (v) => model.updateSettings((x) => x.targetLanguage = v)),
          ),
        ]),
        _section(tr('가사 기본 설정'), [
          SwitchListTile(
            title: Text(tr('해석 표시'), style: TextStyle(color: t.textPrimary)),
            value: s.showTranslation,
            onChanged: (v) => model.updateSettings((x) => x.showTranslation = v),
          ),
        ]),
        _section('Spotify', [
          ListTile(
            leading: Image.asset('assets/brand/spotify_icon_green.png', width: 28, height: 28),
            title: Text(tr('Spotify 계정'), style: TextStyle(color: t.textPrimary)),
            subtitle: Text(tr('로그인됨'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            trailing: TextButton(
              onPressed: () => _logout(model),
              child: Text(tr('로그아웃'), style: TextStyle(color: t.textSecondary)),
            ),
          ),
          ListTile(
            leading: Icon(model.usingSpotifyApp ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                color: model.usingSpotifyApp ? t.brand : t.textTertiary),
            title: Text(tr('재생'), style: TextStyle(color: t.textPrimary)),
            subtitle: Text(
              model.usingSpotifyApp ? tr('Spotify 앱으로 재생 · 앱 전환 없이 백그라운드에서 재생해요') : (model.spotifyRemoteIssue ?? tr('Spotify 앱에 연결하는 중…')),
              style: TextStyle(fontSize: 12, color: t.textTertiary),
            ),
            trailing: model.usingSpotifyApp
                ? null
                : TextButton(
                    onPressed: () => model.attachSpotify(retryRemote: true),
                    child: Text(tr('다시 연결'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(tr('노래는 휴대폰의 Spotify 앱으로 재생돼요 (Spotify Premium 필요). 지금 듣는 곡의 가사가 자동으로 따라와요.'),
                style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ),
        ]),
        _section(tr('데이터'), [
          _row(tr('저장 공간 사용량'), trailing: StorageMeter.format(model.storageUsedBytes)),
          _nav(tr('컬렉션 내보내기'), _export),
          _nav(tr('컬렉션 가져오기'), _import),
          if (ModelManager.isInstalled)
            _destructive(tr('온디바이스 모델 삭제'), () {
              ModelManager.deleteModel();
              setState(() {});
            }),
          _destructive(tr('전체 삭제'), _deleteAll),
        ]),
        _section(null, [
          _row(tr('버전'), trailing: '0.9.0 (${Platform.isIOS ? 'iOS' : 'Android'})'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(tr('가사는 LRCLIB에서 가져와요. 컬렉션은 이 기기에만 저장되고, 가사는 선택한 번역 엔진으로만 전송돼요.'),
                style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ),
        ]),
      ]),
    );
  }

  /// A dropdown of languages by their own names. A saved value that is no longer offered stays listed.
  Widget _languageMenu(String value, List<Language> options, ValueChanged<String> onChanged) {
    final t = context.theme;
    final items = [...options, if (!options.any((l) => l.code == value)) Language.named(value)];
    return DropdownButton<String>(
      value: value,
      underline: const SizedBox(),
      dropdownColor: t.surfaceRaised,
      style: TextStyle(color: t.textSecondary, fontSize: 15),
      items: [for (final l in items) DropdownMenuItem(value: l.code, child: Text(l.nativeName))],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }

  Widget _section(String? title, List<Widget> children) {
    final t = context.theme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: SectionLabel(title)),
        Container(
          decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Material(color: Colors.transparent, child: Column(children: children)),
        ),
      ]),
    );
  }

  Widget _radio(String label, bool selected, VoidCallback onTap) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: selected ? Icon(Icons.check, color: t.textPrimary) : null,
      onTap: onTap,
    );
  }

  Widget _row(String label, {required String trailing}) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: Text(trailing, style: TextStyle(color: t.textSecondary, fontSize: 14)),
    );
  }

  Widget _nav(String label, VoidCallback onTap) {
    final t = context.theme;
    return ListTile(
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: Icon(Icons.chevron_right, color: t.textTertiary),
      onTap: onTap,
    );
  }

  Widget _destructive(String label, VoidCallback onTap) =>
      ListTile(title: Text(label, style: const TextStyle(color: Color(0xFFE57373))), onTap: onTap);

  /// PR-9 / ONRQ-14: progress is shown inline.
  Widget _modelDownloadRow(AppModel model) {
    final t = context.theme;
    if (downloadProgress case final p?) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                  tr('Gemma 4 E2B 다운로드 중… {0} / {1}', [StorageMeter.format((p * ModelManager.approximateBytes).round()), StorageMeter.format(ModelManager.approximateBytes)]),
                  style: TextStyle(color: t.textPrimary)),
            ),
            TextButton(onPressed: ModelManager.cancelDownload, child: Text(tr('취소'), style: TextStyle(color: t.textSecondary))),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: p),
          const SizedBox(height: 6),
          Text(tr('Wi-Fi에서 받는 걸 권장해요. 중간에 멈춰도 이어서 받아요.'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ]),
      );
    }
    if (!ModelManager.isSupported) return _row(tr('온디바이스 모델'), trailing: tr('이 기기에서는 지원하지 않아요'));
    if (ModelManager.isInstalled) return _row(tr('온디바이스 모델'), trailing: tr('Gemma 4 E2B 설치됨'));
    return ListTile(
      title: Text(tr('Gemma 4 E2B 내려받기 ({0})', [StorageMeter.format(ModelManager.approximateBytes)]), style: TextStyle(color: t.accent)),
      subtitle: Text(tr('llama.cpp로 이 기기에서 오프라인 번역 · 여유 메모리 약 4 GB 필요'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
      onTap: () async {
        setState(() => downloadProgress = 0);
        try {
          await ModelManager.download((p) {
            if (mounted) setState(() => downloadProgress = p);
          });
          if (mounted) showMessage(context, tr('Gemma 4 E2B를 설치했어요.'));
        } on CancelledException {
          if (mounted) showMessage(context, tr('다운로드를 멈췄어요. 다시 누르면 이어서 받아요.'));
        } catch (_) {
          if (mounted) showMessage(context, tr('모델을 내려받지 못했어요. 다시 시도하면 이어서 받아요.'));
        }
        if (mounted) setState(() => downloadProgress = null);
      },
    );
  }

  String _endpointSummary(AppModel model) {
    final s = model.settings;
    final hasKey = (model.apiKey(s.engine) ?? '').isNotEmpty;
    if (!hasKey) return tr('설정 필요');
    if (s.engine == EngineKind.vynilo) return s.vyniloModel.isEmpty ? tr('서버 기본 모델') : s.vyniloModel;
    return s.gatewayModel.isEmpty ? tr('모델 선택 필요') : s.gatewayModel;
  }

  Future<void> _logout(AppModel model) async {
    final ok = await confirmDialog(context,
        title: tr('Spotify에서 로그아웃할까요?'), message: tr('Vynilo는 Spotify로 노래를 재생해요. 다시 쓰려면 로그인해야 해요.'), confirm: tr('로그아웃'), destructive: true);
    if (ok) await model.disconnect(SourceID.spotify);
  }

  Future<void> _export() async {
    final model = context.readModel;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/LyricsTranslator-collection.json');
      await f.writeAsString(model.exportData(), flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: tr('Vynilo 컬렉션')));
    } catch (_) {
      if (mounted) showMessage(context, tr('내보내지 못했어요.'));
    }
  }

  Future<void> _import() async {
    final model = context.readModel;
    String message;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      final path = files.isEmpty ? null : files.single.path;
      if (path == null) return;
      final report = model.importData(utf8.decode(await File(path).readAsBytes()));
      message = tr('노래 {0}곡, 문장 {1}개를 가져왔어요.', [report.songsAdded, report.phrasesAdded]);
    } on ImportError catch (e) {
      message = e.newerSchema != null ? tr('더 새로운 버전의 앱에서 만든 파일이에요. 앱을 업데이트해 주세요.') : tr('파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.');
    } catch (_) {
      message = tr('파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.');
    }
    if (mounted) showMessage(context, message);
  }

  Future<void> _deleteAll() async {
    final ok = await confirmDialog(context,
        title: tr('모든 데이터를 삭제할까요?'),
        message: tr('컬렉션, 번역, 저장한 문장, 커버, 모델 파일, API 키가 모두 삭제돼요. 되돌릴 수 없어요.'),
        confirm: tr('전체 삭제'),
        destructive: true);
    if (!ok || !mounted) return;
    final model = context.readModel;
    if (!widget.asTab) Navigator.pop(context);
    await model.deleteAll();
  }
}

/// API key entry with "Verify key" (RQ-14, ONRQ-10). Keys are masked after saving and stored
/// only in secure storage.
class APIKeyEntryView extends StatefulWidget {
  final bool showDone;
  const APIKeyEntryView({super.key, this.showDone = false});
  @override
  State<APIKeyEntryView> createState() => _APIKeyEntryViewState();
}

class _APIKeyEntryViewState extends State<APIKeyEntryView> {
  EngineKind provider = EngineKind.claude;
  final _key = TextEditingController();
  String status = 'idle';
  String? failure;

  @override
  void initState() {
    super.initState();
    final e = context.readModel.settings.engine;
    if (e.requiresAPIKey) provider = e;
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final saved = model.apiKey(provider);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('API 키')),
        actions: [
          if (widget.showDone)
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('완료'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SegmentedButton<EngineKind>(
          segments: const [
            ButtonSegment(value: EngineKind.claude, label: Text('Claude')),
            ButtonSegment(value: EngineKind.gemini, label: Text('Gemini')),
          ],
          selected: {provider},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: t.accent,
            selectedForegroundColor: t.onAccent,
            foregroundColor: t.textSecondary,
            side: BorderSide(color: t.stroke),
          ),
          onSelectionChanged: (v) => setState(() {
            provider = v.first;
            status = 'idle';
          }),
        ),
        const SizedBox(height: 20),
        if (saved != null && _key.text.isEmpty) ...[
          Row(children: [
            Text(tr('저장된 키'), style: TextStyle(color: t.textSecondary)),
            const Spacer(),
            Text(maskSecret(saved), style: TextStyle(color: t.textPrimary, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 12),
        ],
        OutlinedField(controller: _key, hint: tr('API 키 입력'), obscure: true, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        PrimaryButton(tr('키 확인'), onPressed: _key.text.isEmpty || status == 'verifying' ? null : _verify),
        const SizedBox(height: 12),
        if (status == 'verifying') const Center(child: CircularProgressIndicator()),
        if (status == 'ok')
          Row(children: [Icon(Icons.check_circle_outline, color: Colors.green), SizedBox(width: 8), Text(tr('키가 확인됐어요'), style: TextStyle(color: Colors.green))]),
        if (status == 'failed')
          Row(children: [
            const Icon(Icons.highlight_off, color: Color(0xFFE57373)),
            const SizedBox(width: 8),
            Expanded(child: Text(failure ?? '', style: const TextStyle(color: Color(0xFFE57373)))),
          ]),
        const SizedBox(height: 16),
        Text(
          provider == EngineKind.gemini
              ? tr('Google AI Studio(aistudio.google.com)에서 API 키를 만들 수 있어요. Gemini 앱 구독은 API 키가 아니에요. 가사는 Google로 전송되고 사용량은 내 계정에 청구돼요.')
              : tr('Claude Console(console.anthropic.com)에서 API 키를 만들 수 있어요. Claude Pro/Max 구독은 API 키가 아니에요. 가사는 Anthropic으로 전송되고 사용량은 내 계정에 청구돼요 (한 곡에 약 \$0.006).'),
          style: TextStyle(fontSize: 12, color: t.textTertiary),
        ),
      ]),
    );
  }

  Future<void> _verify() async {
    final model = context.readModel;
    setState(() => status = 'verifying');
    final key = _key.text.trim();
    try {
      final CloudChatEngine engine = provider == EngineKind.gemini ? GeminiEngine(key) : ClaudeEngine(key);
      await engine.verifyKey();
      await model.secureStore.set(key, SecretKey.apiKeyFor(provider)!);
      model.updateSettings((s) => s.engine = provider);
      _key.clear();
      if (mounted) setState(() => status = 'ok');
    } on LLMError catch (e) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = tr('키를 저장하지 못했어요.');
        });
      }
    }
  }
}
