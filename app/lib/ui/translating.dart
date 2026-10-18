import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/theme.dart';
import '../app/platform_services.dart';
import '../core/llm.dart';
import '../core/models.dart';
import 'components.dart';

/// FG-04 Translating (RQ-7, SIR-3). "Send to background" means "continue while I use other
/// screens of this app" (ONRQ-9).
class TranslatingView extends StatefulWidget {
  final String songID;
  const TranslatingView({super.key, required this.songID});
  @override
  State<TranslatingView> createState() => _TranslatingViewState();
}

class _TranslatingViewState extends State<TranslatingView> {
  bool _finished = false;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final id = widget.songID;
    final p = model.progress[id];
    final lines = model.collection.linesFor(id);
    final total = p?.total ?? lines.length;
    final done = p?.done ?? model.collection.translatedCount(id, model.target.code);

    // RQ-8: the reward screen is shown only if the job finishes while this screen is visible.
    if (!model.isTranslating(id) && !_finished) {
      _finished = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish(model));
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false, actions: [
          Padding(padding: const EdgeInsets.only(right: 20), child: EngineBadge(EngineFactory.label(model.settings.engine))),
        ]),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(children: [
              const SizedBox(height: 24),
              const SizedBox(width: 200, height: 200, child: SpinningRecord()),
              const SizedBox(height: 24),
              Text('번역 중 ($done/$total줄)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: t.textPrimary)),
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 4),
              ),
              const SizedBox(height: 24),
              _stages(p?.stage ?? Stage.fetchLyrics),
              const SizedBox(height: 24),
              Text(p?.eta == null ? '예상 시간 약 20초' : '예상 시간 약 ${p!.eta!.round().clamp(1, 1 << 30)}초',
                  style: TextStyle(fontSize: 12, color: t.textSecondary)),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text(lines.isEmpty ? '' : lines.first.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: t.textPrimary)),
                  const SizedBox(height: 4),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(p?.firstLinePreview ?? '가사 첫 줄 해석이 미리 떠오릅니다',
                        key: ValueKey(p?.firstLinePreview),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: t.textSecondary)),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              SecondaryButton('백그라운드로 보내기', onPressed: () => model.setPath([])),
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }

  void _finish(AppModel model) {
    if (!mounted) return;
    final song = model.collection.song(widget.songID);
    if (song == null) return;
    if (song.status == SongStatus.done) {
      Haptics.success();
      model.setPath([SavedRoute(widget.songID)]);
    } else {
      model.setPath([PlayerRoute(widget.songID)]);
    }
  }

  Widget _stages(Stage current) {
    final t = context.theme;
    Widget stage(String title, bool active) => Text(title,
        style: TextStyle(
            fontSize: 12, fontWeight: active ? FontWeight.w600 : FontWeight.normal, color: active ? t.textPrimary : t.textTertiary));
    final chevron = Icon(Icons.chevron_right, size: 14, color: t.textTertiary);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      stage('가사 불러오기', current == Stage.fetchLyrics),
      chevron,
      stage('번역', current == Stage.translate),
      chevron,
      stage('저장', current == Stage.save),
    ]);
  }
}
