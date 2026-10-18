import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import '../core/playback.dart';
import 'components.dart';
import 'settings.dart';

/// FG-00 Onboarding (RQ-1, RQ-2, DCR-1).
/// At most 3 intro cards; engine choice; "Connect your music" with an equally sized "Later".
class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key});
  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  int page = 0;
  EngineKind engine = EngineKind.onDevice;

  static const cards = [
    ('노래로 공부하고,\nLP로 모으자', '팝송 가사를 AI로 해석하고 나만의 컬렉션으로 모아요'),
    ('한 줄씩,\n음악에 맞춰서', '지금 듣는 노래의 가사가 박자에 맞춰 흐르고, 해석이 바로 아래에 보여요'),
    ('모르는 표현은\n탭 한 번으로', '슬랭과 관용구를 쉽게 풀어주고, 좋은 문장은 저장함에 담아요'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('${page + 1} / ${cards.length}', style: TextStyle(fontSize: 12, color: t.textSecondary)),
            ),
          ),
          Expanded(
            child: PageView.builder(
              itemCount: cards.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (_, i) => _introCard(cards[i]),
            ),
          ),
          _dots(t),
          const SizedBox(height: 24),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _enginePicker(t)),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(children: [
              PrimaryButton('음악 앱 연결하기', onPressed: _showConnectOptions),
              const SizedBox(height: 12),
              SecondaryButton('나중에 하기', onPressed: _finish),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _introCard((String, String) card) {
    final t = context.theme;
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: Column(children: [
          SizedBox(height: c.maxHeight > 360 ? 24 : 8),
          SizedBox(width: c.maxHeight > 360 ? 180 : 120, child: const VinylRecord(grooves: 4)),
          const SizedBox(height: 28),
          Text(card.$1,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: t.textPrimary, height: 1.3)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(card.$2, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: t.textSecondary)),
          ),
        ]),
      ),
    );
  }

  Widget _dots(AppTheme t) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < cards.length; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(shape: BoxShape.circle, color: i == page ? t.textPrimary : t.stroke),
            ),
        ],
      );

  Widget _enginePicker(AppTheme t) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionLabel('번역 엔진'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _engineCard(EngineKind.onDevice, '온디바이스', '기본 · 무료')),
          const SizedBox(width: 10),
          Expanded(child: _engineCard(EngineKind.claude, '내 API 키', 'Claude · Gemini')),
        ]),
        if (engine == EngineKind.onDevice) ...[
          const SizedBox(height: 10),
          Text('처음 한 번 Wi-Fi에서 약 1–2GB 모델을 내려받아요. 그 전에는 데모 엔진으로 동작해요.',
              style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ],
      ]);

  Widget _engineCard(EngineKind kind, String title, String subtitle) {
    final t = context.theme;
    final selected = kind == EngineKind.onDevice ? engine == EngineKind.onDevice : engine != EngineKind.onDevice;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          setState(() => engine = kind);
          if (kind != EngineKind.onDevice) {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const APIKeyEntryView(showDone: true)));
          }
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? t.textPrimary : t.stroke, width: selected ? 1.5 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(fontSize: 12, color: t.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Future<void> _showConnectOptions() async {
    final id = await showActionSheet<SourceID?>(
      context,
      title: '음악 앱 연결',
      message: 'Spotify와 Apple Music을 연결할 수 있어요. 다른 앱은 가사 공부 모드로 쓸 수 있어요.',
      actions: const [
        SheetAction('Spotify', SourceID.spotify, icon: Icons.music_note),
        SheetAction('Apple Music', SourceID.appleMusic, icon: Icons.music_note_outlined),
        SheetAction('나중에', null),
      ],
    );
    if (id == null || !mounted) return;
    await context.readModel.connect(id);
    _finish();
  }

  void _finish() {
    final model = context.readModel;
    // If the user picked "my API key", use whichever key engine they set up.
    var chosen = engine;
    if (chosen != EngineKind.onDevice) {
      final settingsEngine = model.settings.engine;
      if (settingsEngine != EngineKind.onDevice && model.apiKey(settingsEngine) != null) {
        chosen = settingsEngine;
      } else if (model.apiKey(EngineKind.claude) == null && model.apiKey(EngineKind.gemini) != null) {
        chosen = EngineKind.gemini;
      }
    }
    model.updateSettings((s) {
      s.engine = chosen;
      s.hasOnboarded = true;
    });
  }
}
