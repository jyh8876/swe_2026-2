import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/llm.dart';
import '../core/models.dart';
import 'player_controls.dart';

/// Opens FG-07 as the prototype's sheet: opens at about two thirds (06-1), drag up for full (06-2).
/// The player controls and the replay/save buttons stay fixed at the bottom.
/// Resolves to true when the user taps "이 줄 다시 듣기".
Future<bool?> showLineDetail(BuildContext context, {required String songID, required int index, required bool canReplay}) {
  final h = MediaQuery.of(context).size.height;
  return showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    backgroundColor: context.theme.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    clipBehavior: Clip.antiAlias,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      // Tall enough at first for the line, part of the explanation and the fixed controls.
      initialChildSize: (540 / h).clamp(0.5, 0.75),
      minChildSize: (300 / h).clamp(0.3, 0.45),
      maxChildSize: (760 / h).clamp(0.75, 0.95),
      snap: true,
      snapSizes: [(540 / h).clamp(0.5, 0.75)],
      builder: (_, scroll) => LineDetailView(songID: songID, index: index, canReplay: canReplay, scroll: scroll),
    ),
  );
}

/// FG-07 Line detail (RQ-11, ONRQ-5, ONRQ-12, ONRQ-13).
/// Generated on first tap with a skeleton loader, cached permanently afterwards.
class LineDetailView extends StatefulWidget {
  final String songID;
  final int index;
  final bool canReplay;
  final ScrollController? scroll;
  const LineDetailView({super.key, required this.songID, required this.index, required this.canReplay, this.scroll});

  @override
  State<LineDetailView> createState() => _LineDetailViewState();
}

class _LineDetailViewState extends State<LineDetailView> {
  Explanation? explanation;
  LLMError? error;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({TranslationEngine? engine}) async {
    final model = context.readModel;
    if (engine == null) {
      final cached = model.cachedExplanation(widget.songID, widget.index);
      if (cached != null) {
        setState(() => explanation = cached);
        return;
      }
    }
    setState(() {
      isLoading = true;
      error = null;
      if (engine != null) explanation = null;
    });
    try {
      final e = await model.explain(widget.songID, widget.index, engine: engine);
      if (mounted) setState(() => explanation = e);
    } on LLMError catch (e) {
      if (mounted) setState(() => error = e);
    } catch (_) {
      if (mounted) setState(() => error = LLMError(LLMErrorKind.unavailable, detail: tr('해설을 불러오지 못했어요.')));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  EngineKind? get _availableCloudEngine {
    final model = context.readModel;
    // The Vynilo server only translates, so it is not offered for explanations.
    for (final k in [EngineKind.claude, EngineKind.gemini, EngineKind.gateway]) {
      if (EngineFactory.make(k, model.apiKey(k), model.settings.engineConfig).isAvailable) return k;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final line = model.collection.line(widget.songID, widget.index);
    final saved = model.collection.isSaved(widget.songID, widget.index);
    final translation = model.translationSkipped(widget.songID) ? null : model.collection.translationText(widget.songID, widget.index, model.target.code);

    // The controls and buttons are a fixed footer, visible at any sheet height; only the
    // explanation above them scrolls.
    return Column(children: [
      Expanded(
        child: CustomScrollView(controller: widget.scroll, slivers: [
      // Header: grab handle, line, translation and the save star (Figma p-sh-head).
      SliverToBoxAdapter(
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.stroke))),
          padding: const EdgeInsets.fromLTRB(20, 0, 10, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: t.stroke, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(height: 4),
                  SelectableText(line?.text ?? '',
                      style: TextStyle(fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w700, letterSpacing: -0.36, color: t.textPrimary)),
                  if (translation != null) ...[
                    const SizedBox(height: 8),
                    Text(translation, style: TextStyle(fontSize: 14, height: 18 / 14, letterSpacing: -0.21, color: t.textSecondary)),
                  ],
                ]),
              ),
              IconButton(
                tooltip: saved ? tr('담은 문장에서 빼기') : tr('문장 담기'),
                onPressed: () => model.toggleSaved(widget.songID, widget.index),
                icon: Icon(saved ? Icons.star_rounded : Icons.star_outline_rounded, size: 28, color: saved ? t.brand : t.textTertiary),
              ),
            ]),
          ]),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 16), sliver: SliverToBoxAdapter(child: _content(model))),
        ]),
      ),
      _footer(model, t, saved),
    ]);
  }

  Widget _footer(AppModel model, AppTheme t, bool saved) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(color: t.background, border: Border(top: BorderSide(color: t.stroke))),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // The player's controls stay at hand while reading (Figma line sheet).
          PlaybackControls(songID: widget.songID, compact: true, colors: ControlColors.of(t)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.canReplay ? () => Navigator.pop(context, true) : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.textPrimary,
                  side: BorderSide(color: t.stroke),
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.replay_rounded, size: 18),
                label: Text(tr('이 줄 다시 듣기'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => model.toggleSaved(widget.songID, widget.index),
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: t.onAccent,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(saved ? Icons.star_rounded : Icons.star_outline_rounded, size: 18),
                label: Text(saved ? tr('담은 문장에서 빼기') : tr('담기'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _content(AppModel model) {
    final t = context.theme;
    final children = <Widget>[];
    if (explanation case final e?) {
      children.add(_explanationBody(e));
    } else if (error case final err?) {
      children.addAll([
        _section(tr('세부 설명'), Text(err.kind == LLMErrorKind.refused ? tr('현재 엔진에서는 이 해설을 제공할 수 없어요.') : tr('해설을 불러오지 못했어요 — {0}', [err.userMessage]), style: _body(t))),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: () => _load(), child: Text(tr('다시 시도'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600))),
          if (model.settings.engine != EngineKind.onDevice)
            TextButton(
              onPressed: () => _load(engine: EngineFactory.make(EngineKind.onDevice, null)),
              child: Text(tr('온디바이스로 시도'), style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600)),
            ),
        ]),
      ]);
    } else {
      children.add(_skeleton(t));
    }

    final cloud = _availableCloudEngine;
    if (model.settings.engine == EngineKind.onDevice && explanation != null && cloud != null) {
      children.add(TextButton.icon(
        onPressed: isLoading ? null : () => _load(engine: EngineFactory.make(cloud, model.apiKey(cloud), model.settings.engineConfig)),
        icon: Icon(Icons.auto_awesome, size: 16, color: t.brandInk),
        label: Text(tr('더 정확한 해설 보기 (내 API 키)'), style: TextStyle(fontSize: 13, color: t.brandInk)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  TextStyle _body(AppTheme t) => TextStyle(fontSize: 16, height: 22 / 16, letterSpacing: -0.24, color: t.textPrimary);

  Widget _section(String? title, Widget child) {
    final t = context.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) ...[
          Text(title, style: TextStyle(fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w500, letterSpacing: -0.28, color: t.textTertiary)),
          const SizedBox(height: 8),
        ],
        child,
      ]),
    );
  }

  Widget _skeleton(AppTheme t) => Semantics(
        label: tr('해설을 불러오는 중'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final f in [0.4, 0.85, 0.6, 0.4, 0.85])
            FractionallySizedBox(
              widthFactor: f,
              child: Container(height: 14, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: BorderRadius.circular(4))),
            ),
        ]),
      );

  Widget _explanationBody(Explanation e) {
    final t = context.theme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (e.expressions.isNotEmpty)
        _section(
          null,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, x) in e.expressions.indexed) ...[
              if (i > 0) const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: t.marker, borderRadius: BorderRadius.circular(4)),
                child: Text(x.phrase, style: TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.24, color: t.brandInk)),
              ),
              const SizedBox(height: 8),
              SelectableText(x.meaning, style: _body(t)),
            ],
          ]),
        ),
      if (e.structure.isNotEmpty) _section(tr('문장 구조'), SelectableText(e.structure, style: _body(t))),
      if (e.usage.isNotEmpty) _section(tr('이럴 때 써요'), SelectableText(e.usage, style: _body(t))),
      if (e.example.isNotEmpty)
        _section(
          tr('예문'),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 9, 6, 0),
              child: Container(width: 4, height: 4, decoration: BoxDecoration(color: t.textSecondary, shape: BoxShape.circle)),
            ),
            Expanded(child: SelectableText(e.example, style: _body(t))),
          ]),
        ),
    ]);
  }
}
