import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../app/theme.dart';
import '../core/models.dart';
import 'components.dart';
import 'line_detail.dart';

/// FG-08 Phrase box (RQ-12, RQ-13 statistics). No share/export in MVP (FG-08 note).
class PhraseBoxView extends StatefulWidget {
  const PhraseBoxView({super.key});
  @override
  State<PhraseBoxView> createState() => _PhraseBoxViewState();
}

enum _Sort { newest, bySong }

class _PhraseBoxViewState extends State<PhraseBoxView> {
  _Sort sort = _Sort.newest;

  List<Phrase> _sorted(AppModel model) {
    final list = [...model.collection.phrases];
    switch (sort) {
      case _Sort.newest:
        list.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      case _Sort.bySong:
        final titles = {for (final s in model.collection.songs) s.id: s.title};
        list.sort((a, b) {
          final ta = titles[a.songID] ?? '', tb = titles[b.songID] ?? '';
          return ta == tb ? a.index.compareTo(b.index) : ta.compareTo(tb);
        });
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final phrases = _sorted(model);
    return Scaffold(
      appBar: AppBar(title: const Text('문장 저장함')),
      body: ListView(padding: EdgeInsets.fromLTRB(20, 20, 20, model.nowPlaying != null ? 104 : 20), children: [
        _statsCard(model),
        const SizedBox(height: 16),
        Row(children: [_chip('최신순', _Sort.newest), const SizedBox(width: 8), _chip('곡별', _Sort.bySong)]),
        const SizedBox(height: 16),
        if (phrases.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text('가사 옆의 ☆를 눌러 마음에 드는 문장을 모아보세요.', style: TextStyle(fontSize: 15, color: t.textSecondary)),
          )
        else
          for (final p in phrases) Padding(padding: const EdgeInsets.only(bottom: 12), child: _card(model, p)),
      ]),
    );
  }

  Widget _statsCard(AppModel model) {
    final t = context.theme;
    final s = model.collection.stats;
    Widget stat(String v, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: t.textPrimary)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: t.textSecondary)),
        ]);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        stat('${s.phrases}', '저장한 문장'),
        stat('${s.songs}', '곡'),
        stat('${s.conquered}', '정복'),
      ]),
    );
  }

  Widget _chip(String title, _Sort value) {
    final t = context.theme;
    final on = sort == value;
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: () => setState(() => sort = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? t.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: on ? Colors.transparent : t.stroke),
        ),
        child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: on ? t.onAccent : t.textSecondary)),
      ),
    );
  }

  Widget _card(AppModel model, Phrase p) {
    final t = context.theme;
    final line = model.collection.line(p.songID, p.index);
    final song = model.collection.song(p.songID);
    final translation = model.collection.translationText(p.songID, p.index, model.target.code);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showLineDetail(context, songID: p.songID, index: p.index, canReplay: false),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: t.stroke), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(line?.text ?? '', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.textPrimary)),
          if (translation != null) ...[
            const SizedBox(height: 8),
            Text(translation, style: TextStyle(fontSize: 15, color: t.textSecondary)),
          ],
          const SizedBox(height: 8),
          Divider(color: t.stroke, height: 1),
          Row(children: [
            SizedBox(width: 22, height: 22, child: CoverArt(path: song?.coverPath, radius: 3)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${song?.title ?? '삭제된 노래'} · ${song?.artist ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textSecondary)),
            ),
            IconButton(
              tooltip: '저장 취소',
              icon: Icon(Icons.star_rounded, color: t.brand),
              onPressed: () {
                model.toggleSaved(p.songID, p.index);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    duration: const Duration(seconds: 5),
                    content: const Text('문장을 삭제했어요'),
                    action: SnackBarAction(
                      label: '실행 취소',
                      onPressed: () {
                        if (!model.collection.isSaved(p.songID, p.index)) model.toggleSaved(p.songID, p.index);
                      },
                    ),
                  ));
              },
            ),
          ]),
        ]),
      ),
    );
  }
}
