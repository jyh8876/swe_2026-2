import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import 'components.dart';

/// Settings for the engines reached by URL: the self-hosted Vynilo server and any
/// OpenAI-compatible LLM gateway. Same flow as the API key screen (RQ-14): enter, check, save.
/// Keys go to secure storage only; URLs and model names are ordinary settings.
class EndpointSettingsView extends StatefulWidget {
  final EngineKind kind;
  const EndpointSettingsView({super.key, required this.kind}) : assert(kind == EngineKind.vynilo || kind == EngineKind.gateway);

  @override
  State<EndpointSettingsView> createState() => _EndpointSettingsViewState();
}

class _EndpointSettingsViewState extends State<EndpointSettingsView> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  List<String> models = [];
  String model = '';
  final _filter = TextEditingController();
  String status = 'idle';
  String? failure;

  bool get isServer => widget.kind == EngineKind.vynilo;

  @override
  void initState() {
    super.initState();
    final s = context.readModel.settings;
    // The gateway starts blank: the user brings their own gateway URL and key.
    _url.text = isServer ? s.vyniloURL : s.gatewayURL;
    model = isServer ? s.vyniloModel : s.gatewayModel;
    // With a saved URL and key, load the model list right away so the model can be changed.
    if (_url.text.trim().isNotEmpty && (_savedKey ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check(select: false));
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _filter.dispose();
    super.dispose();
  }

  String? get _savedKey => context.readModel.apiKey(widget.kind);
  String get _keyForRequest => _key.text.trim().isNotEmpty ? _key.text.trim() : (_savedKey ?? '');

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final saved = model.apiKey(widget.kind);
    final canCheck = _url.text.trim().isNotEmpty && _keyForRequest.isNotEmpty && status != 'checking';
    return Scaffold(
      appBar: AppBar(title: Text(isServer ? tr('Vynilo 서버') : tr('LLM 게이트웨이'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        _label(isServer ? tr('서버 주소') : tr('게이트웨이 주소')),
        OutlinedField(controller: _url, hint: isServer ? VyniloServerEngine.defaultURL : 'https://…/v1', onChanged: (_) => setState(() {})),
        const SizedBox(height: 16),
        _label(tr('API 키')),
        if (saved != null && _key.text.isEmpty) ...[
          Row(children: [
            Text(tr('저장된 키'), style: TextStyle(color: t.textSecondary)),
            const Spacer(),
            Text(maskSecret(saved), style: TextStyle(color: t.textPrimary, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 8),
        ],
        OutlinedField(controller: _key, hint: isServer ? 'vyk_…' : tr('API 키 입력'), obscure: true, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        PrimaryButton(tr('연결 확인'), onPressed: canCheck ? _check : null),
        const SizedBox(height: 12),
        if (status == 'checking') const Center(child: CircularProgressIndicator()),
        if (status == 'ok')
          Row(children: [
            const Icon(Icons.check_circle_outline, color: Colors.green),
            const SizedBox(width: 8),
            Text(tr('연결됐어요 · 모델 {0}개', [models.length]), style: const TextStyle(color: Colors.green)),
          ]),
        if (status == 'failed')
          Row(children: [
            const Icon(Icons.highlight_off, color: Color(0xFFE57373)),
            const SizedBox(width: 8),
            Expanded(child: Text(failure ?? '', style: const TextStyle(color: Color(0xFFE57373)))),
          ]),
        const SizedBox(height: 20),
        _label(tr('모델')),
        // The chosen model, always visible and changeable.
        Container(
          decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            title: Text(this.model.isEmpty ? (isServer ? tr('서버 기본 모델') : tr('모델 선택 필요')) : this.model, style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
            subtitle: Text(tr('선택한 모델'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
            trailing: TextButton(onPressed: _customModel, child: Text(tr('직접 입력'), style: TextStyle(color: t.textPrimary))),
          ),
        ),
        if (models.isNotEmpty) ...[
          const SizedBox(height: 12),
          if (models.length > 8) ...[
            OutlinedField(controller: _filter, hint: tr('모델 검색'), onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
          ],
          Container(
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: Column(children: [
                if (isServer) _modelTile(tr('서버 기본 모델'), ''),
                for (final m in models.where((m) => m.toLowerCase().contains(_filter.text.trim().toLowerCase()))) _modelTile(m, m),
              ]),
            ),
          ),
        ] else if (status != 'checking') ...[
          const SizedBox(height: 8),
          Text(tr('연결 확인을 누르면 모델 목록을 불러와요.'), style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ],
        const SizedBox(height: 16),
        Text(
          isServer
              ? tr('Vynilo 웹앱의 API keys 페이지에서 키를 만들 수 있어요. 서버는 Tailscale 안에서만 열려 있어서, 이 휴대폰도 Tailscale에 연결되어 있어야 해요. 가사는 내 서버로만 전송돼요.')
              : tr('OpenAI 호환 /chat/completions 게이트웨이(예: Baze, OpenRouter)를 쓸 수 있어요. 가사는 게이트웨이와 선택한 모델 제공자로 전송되고, 사용량은 게이트웨이 계정에 청구돼요.'),
          style: TextStyle(fontSize: 12, color: t.textTertiary),
        ),
      ]),
    );
  }

  Widget _label(String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: SectionLabel(text));

  Widget _modelTile(String label, String value) {
    final t = context.theme;
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(color: t.textPrimary)),
      trailing: model == value ? Icon(Icons.check, color: t.brandInk) : null,
      onTap: () => _choose(value),
    );
  }

  void _choose(String value) {
    setState(() => model = value);
    context.readModel.updateSettings((s) => isServer ? s.vyniloModel = value : s.gatewayModel = value);
    showMessage(context, tr('모델을 {0}(으)로 바꿨어요. 다음 번역부터 적용돼요.', [value.isEmpty ? tr('서버 기본 모델') : value]));
  }

  /// A model id the list does not show (gateways sometimes hide aliases).
  Future<void> _customModel() async {
    final t = context.theme;
    final field = TextEditingController(text: model);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('모델 직접 입력'), style: TextStyle(color: t.textPrimary, fontSize: 18)),
        content: OutlinedField(controller: field, hint: 'gpt-5.4-mini'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'), style: TextStyle(color: t.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(ctx, field.text.trim()), child: Text(tr('저장'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    field.dispose();
    if (value != null && (value.isNotEmpty || isServer)) _choose(value);
  }

  /// Tests the connection and loads the models. [select] also makes this the active engine (the
  /// button); the automatic load on opening only refreshes the list.
  Future<void> _check({bool select = true}) async {
    final app = context.readModel;
    final url = _url.text.trim();
    final key = _keyForRequest;
    setState(() => status = 'checking');
    try {
      final list = isServer ? await VyniloServerEngine.listModels(url, key) : await GatewayEngine.listModels(url, key);
      if (_key.text.trim().isNotEmpty) await app.secureStore.set(key, SecretKey.apiKeyFor(widget.kind)!);
      app.updateSettings((s) {
        if (isServer) {
          s.vyniloURL = url;
        } else {
          s.gatewayURL = url;
          if (s.gatewayModel.isEmpty && list.isNotEmpty) s.gatewayModel = list.first;
        }
        if (select) s.engine = widget.kind;
      });
      _key.clear();
      if (mounted) {
        setState(() {
          models = list;
          model = isServer ? app.settings.vyniloModel : app.settings.gatewayModel;
          status = 'ok';
        });
      }
    } on LLMError catch (e) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = e.kind == LLMErrorKind.network ? tr('서버에 연결하지 못했어요. 주소와 네트워크를 확인해 주세요.') : e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          status = 'failed';
          failure = tr('응답을 읽지 못했어요. 주소를 확인해 주세요.');
        });
      }
    }
  }
}
