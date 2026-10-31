import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../app/platform_services.dart';
import '../core/llm.dart';
import '../core/models.dart';
import 'components.dart';
import 'covers.dart';
import 'translating_record.dart';

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

  /// Lines revealed so far. Lines are revealed one at a time (about 0.14 s apart) even when an
  /// engine delivers several at once, so the song visibly fills in line by line.
  int _shown = 0;
  Timer? _reveal;

  @override
  void initState() {
    super.initState();
    _reveal = Timer.periodic(const Duration(milliseconds: 140), (_) => _step());
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  List<LyricLine> _translated(AppModel model) {
    final target = model.target.code;
    return [
      for (final l in model.collection.linesFor(widget.songID))
        if (model.collection.translation(widget.songID, l.index, target)?.outcome case final o? when o != Outcome.failed) l,
    ];
  }

  void _step() {
    if (!mounted) return;
    final model = context.readModel;
    final available = _translated(model).length;
    if (_shown < available) {
      setState(() => _shown++);
    } else if (!model.isTranslating(widget.songID) && !_finished) {
      // Everything is revealed: let the record finish its flourish, then move on (RQ-8).
      _finished = true;
      setState(() {});
      Future.delayed(const Duration(milliseconds: 700), () => _finish(model));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final id = widget.songID;
    final p = model.progress[id];
    final lines = model.collection.linesFor(id);
    final total = max(1, p?.total ?? lines.length);
    final translated = _translated(model);
    final shown = min(_shown, translated.length);
    final target = model.target.code;

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
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                height: 220,
                child: TranslatingRecord(progress: shown / total, pulse: shown, done: _finished),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: c)),
                child: Text(tr('번역 중 ({0}/{1}줄)', [shown, total]),
                    key: ValueKey(shown), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: t.textPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              const SizedBox(height: 16),
              _stages(p?.stage ?? Stage.fetchLyrics),
              const SizedBox(height: 8),
              Text(p?.eta == null ? tr('예상 시간 약 20초') : tr('예상 시간 약 {0}초', [p!.eta!.round().clamp(1, 1 << 30)]),
                  style: TextStyle(fontSize: 12, color: t.textSecondary)),
              const SizedBox(height: 20),
              // Live feed: the newest lines, each sliding in as it is translated.
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 164),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
                child: shown == 0
                    ? Column(children: [
                        const SizedBox(height: 20),
                        Text(lines.isEmpty ? '' : lines.first.text, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: t.textPrimary)),
                        const SizedBox(height: 6),
                        Text(tr('가사 첫 줄 해석이 미리 떠오릅니다'), textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: t.textTertiary)),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final l in translated.sublist(max(0, shown - 3), shown))
                          _FeedLine(
                            key: ValueKey(l.index),
                            original: l.text,
                            translation: model.translationSkipped(id) ? '' : (model.collection.translationText(id, l.index, target) ?? ''),
                            fresh: l == translated[shown - 1],
                          ),
                      ]),
              ),
              const SizedBox(height: 16),
              CoverPicker(songID: id),
              const SizedBox(height: 24),
              SecondaryButton(tr('백그라운드로 보내기'), onPressed: () => model.setPath([])),
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
      stage(tr('가사 불러오기'), current == Stage.fetchLyrics),
      chevron,
      stage(tr('번역'), current == Stage.translate),
      chevron,
      stage(tr('저장'), current == Stage.save),
    ]);
  }
}

/// One line of the live feed: slides up and fades in when it arrives; the newest one is accented.
class _FeedLine extends StatelessWidget {
  final String original, translation;
  final bool fresh;
  const _FeedLine({super.key, required this.original, required this.translation, required this.fresh});

  @override
  Widget build(BuildContext context) {
    final t = context.theme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 3,
            height: 34,
            margin: const EdgeInsets.only(right: 10, top: 2),
            decoration: BoxDecoration(color: fresh ? t.brand : t.stroke, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(original, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fresh ? t.textPrimary : t.textSecondary)),
              const SizedBox(height: 2),
              Text(translation, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: fresh ? t.brandInk : t.textTertiary)),
            ]),
          ),
        ]),
      ),
    );
  }
}
