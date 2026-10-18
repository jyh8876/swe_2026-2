import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_model.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/collection.dart';
import '../core/llm.dart';
import '../core/models.dart';
import '../core/playback.dart';
import 'components.dart';

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
        title: Text(widget.asTab ? '마이페이지' : '설정'),
        automaticallyImplyLeading: false,
        actions: [
          if (!widget.asTab)
            TextButton(onPressed: () => Navigator.pop(context), child: Text('완료', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        _section('번역 엔진', [
          for (final (kind, label) in [
            (EngineKind.onDevice, '온디바이스 (기본)'),
            (EngineKind.claude, 'Claude API'),
            (EngineKind.gemini, 'Gemini API'),
          ])
            _radio(label, s.engine == kind, () => model.updateSettings((x) => x.engine = kind)),
          if (s.engine == EngineKind.onDevice) ...[
            _row('사용 중', trailing: EngineFactory.label(EngineKind.onDevice)),
            _modelDownloadRow(model),
          ] else
            _nav('API 키 입력', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const APIKeyEntryView()))),
        ]),
        _section('언어', [
          ListTile(
            title: Text('번역할 언어의 기본값', style: TextStyle(color: t.textPrimary)),
            trailing: DropdownButton<String>(
              value: s.targetLanguage,
              underline: const SizedBox(),
              dropdownColor: t.surfaceRaised,
              style: TextStyle(color: t.textSecondary, fontSize: 15),
              items: [for (final l in Language.supported) DropdownMenuItem(value: l.code, child: Text(l.nativeName))],
              onChanged: (v) => v == null ? null : model.updateSettings((x) => x.targetLanguage = v),
            ),
          ),
        ]),
        _section('가사 기본 설정', [
          SwitchListTile(
            title: Text('해석 표시', style: TextStyle(color: t.textPrimary)),
            value: s.showTranslation,
            onChanged: (v) => model.updateSettings((x) => x.showTranslation = v),
          ),
        ]),
        _section('음악 앱 연결', [
          _connectionRow(model, 'Spotify', SourceID.spotify),
          _connectionRow(model, 'Apple Music', SourceID.appleMusic),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('이 빌드에서는 시뮬레이션된 연결이에요. 그 밖의 음악 앱은 가사 공부 모드로 사용할 수 있어요.',
                style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ),
        ]),
        _section('데이터', [
          _row('저장 공간 사용량', trailing: StorageMeter.format(model.storageUsedBytes)),
          _nav('컬렉션 내보내기', _export),
          _nav('컬렉션 가져오기', _import),
          if (ModelManager.isInstalled)
            _destructive('온디바이스 모델 삭제', () {
              ModelManager.deleteModel();
              setState(() {});
            }),
          _destructive('전체 삭제', _deleteAll),
        ]),
        _section(null, [
          _row('버전', trailing: '0.1.0 (${Platform.isIOS ? 'iOS' : 'Android'})'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('가사는 LRCLIB에서 가져와요. 팀이 운영하는 서버는 없고, 데이터는 이 기기에만 저장돼요.',
                style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ),
        ]),
      ]),
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
          Text('모델 다운로드 중… ${(p * 100).round()}%', style: TextStyle(color: t.textPrimary)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: p),
        ]),
      );
    }
    if (ModelManager.isInstalled) return _row('온디바이스 모델', trailing: '설치됨');
    return ListTile(
      title: Text('온디바이스 모델 다운로드 (${StorageMeter.format(ModelManager.approximateBytes)})', style: TextStyle(color: t.accent)),
      onTap: () async {
        setState(() => downloadProgress = 0);
        try {
          await ModelManager.download((p) {
            if (mounted) setState(() => downloadProgress = p);
          });
        } catch (_) {
          if (mounted) showMessage(context, '모델을 내려받지 못했어요. 다시 시도해 주세요.');
        }
        if (mounted) setState(() => downloadProgress = null);
      },
    );
  }

  Widget _connectionRow(AppModel model, String title, SourceID id) {
    final t = context.theme;
    final connected = model.settings.connectedSources.contains(id);
    return ListTile(
      title: Text(title, style: TextStyle(color: t.textPrimary)),
      trailing: TextButton(
        onPressed: () => connected ? model.disconnect(id) : model.connect(id),
        child: Text(connected ? '연결됨 · 해제' : '연결', style: TextStyle(color: connected ? t.textSecondary : t.accent)),
      ),
    );
  }

  Future<void> _export() async {
    final model = context.readModel;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/LyricsTranslator-collection.json');
      await f.writeAsString(model.exportData(), flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: 'DAY-OFF 컬렉션'));
    } catch (_) {
      if (mounted) showMessage(context, '내보내지 못했어요.');
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
      message = '노래 ${report.songsAdded}곡, 문장 ${report.phrasesAdded}개를 가져왔어요.';
    } on ImportError catch (e) {
      message = e.newerSchema != null ? '더 새로운 버전의 앱에서 만든 파일이에요. 앱을 업데이트해 주세요.' : '파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.';
    } catch (_) {
      message = '파일을 읽을 수 없어요. 아무것도 변경되지 않았어요.';
    }
    if (mounted) showMessage(context, message);
  }

  Future<void> _deleteAll() async {
    final ok = await confirmDialog(context,
        title: '모든 데이터를 삭제할까요?',
        message: '컬렉션, 번역, 저장한 문장, 커버, 모델 파일, API 키가 모두 삭제돼요. 되돌릴 수 없어요.',
        confirm: '전체 삭제',
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
        title: const Text('API 키'),
        actions: [
          if (widget.showDone)
            TextButton(onPressed: () => Navigator.pop(context), child: Text('완료', style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
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
            Text('저장된 키', style: TextStyle(color: t.textSecondary)),
            const Spacer(),
            Text(maskSecret(saved), style: TextStyle(color: t.textPrimary, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 12),
        ],
        OutlinedField(controller: _key, hint: 'API 키 입력', obscure: true, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        PrimaryButton('키 확인', onPressed: _key.text.isEmpty || status == 'verifying' ? null : _verify),
        const SizedBox(height: 12),
        if (status == 'verifying') const Center(child: CircularProgressIndicator()),
        if (status == 'ok')
          const Row(children: [Icon(Icons.check_circle_outline, color: Colors.green), SizedBox(width: 8), Text('키가 확인됐어요', style: TextStyle(color: Colors.green))]),
        if (status == 'failed')
          Row(children: [
            const Icon(Icons.highlight_off, color: Color(0xFFE57373)),
            const SizedBox(width: 8),
            Expanded(child: Text(failure ?? '', style: const TextStyle(color: Color(0xFFE57373)))),
          ]),
        const SizedBox(height: 16),
        Text(
          provider == EngineKind.gemini
              ? 'Google AI Studio(aistudio.google.com)에서 API 키를 만들 수 있어요. Gemini 앱 구독은 API 키가 아니에요. 가사는 Google로 전송되고 사용량은 내 계정에 청구돼요.'
              : 'Claude Console(console.anthropic.com)에서 API 키를 만들 수 있어요. Claude Pro/Max 구독은 API 키가 아니에요. 가사는 Anthropic으로 전송되고 사용량은 내 계정에 청구돼요 (한 곡에 약 \$0.006).',
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
          failure = '키를 저장하지 못했어요.';
        });
      }
    }
  }
}
