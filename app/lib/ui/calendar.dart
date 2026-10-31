import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/models.dart';
import 'components.dart';
import 'covers.dart';

/// Collection calendar (Notion idea c, "더 추가하고 싶도록"): each day shows the cover of a song
/// added that day; days with a finished quiz get a dot. Tapping a cover opens the song.
class CollectionCalendar extends StatefulWidget {
  const CollectionCalendar({super.key});
  @override
  State<CollectionCalendar> createState() => _CollectionCalendarState();
}

class _CollectionCalendarState extends State<CollectionCalendar> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final byDay = <String, List<Song>>{};
    for (final s in model.collection.songsNewestFirst) {
      byDay.putIfAbsent(QuizProgress.dayKey(s.addedAt), () => []).add(s);
    }
    final quizDays = model.quiz.days;
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday % 7; // Sunday first
    final today = QuizProgress.dayKey(DateTime.now());
    final added = byDay.entries.where((e) => e.key.startsWith(QuizProgress.dayKey(first).substring(0, 7))).fold(0, (n, e) => n + e.value.length);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Row(children: [
          const SizedBox(width: 4),
          Text('${month.month}', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300, color: t.textPrimary)),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${month.year}', style: TextStyle(fontSize: 11, color: t.textTertiary)),
            Text(tr('이번 달 {0}곡 추가', [added]), style: TextStyle(fontSize: 12, color: t.textSecondary)),
          ]),
          const Spacer(),
          IconButton(tooltip: tr('이전 달'), icon: Icon(Icons.chevron_left, color: t.textSecondary), onPressed: () => setState(() => month = DateTime(month.year, month.month - 1))),
          IconButton(tooltip: tr('다음 달'), icon: Icon(Icons.chevron_right, color: t.textSecondary), onPressed: () => setState(() => month = DateTime(month.year, month.month + 1))),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          for (final d in [tr('일'), tr('월'), tr('화'), tr('수'), tr('목'), tr('금'), tr('토')])
            Expanded(child: Center(child: Text(d, style: TextStyle(fontSize: 11, color: t.textTertiary)))),
        ]),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 4, crossAxisSpacing: 4),
          itemCount: lead + days,
          itemBuilder: (_, i) {
            if (i < lead) return const SizedBox();
            final day = DateTime(month.year, month.month, i - lead + 1);
            final key = QuizProgress.dayKey(day);
            final songs = byDay[key] ?? const [];
            final s = songs.firstOrNull;
            return GestureDetector(
              onTap: s == null
                  ? null
                  : () {
                      model.selectTab(AppTab.library);
                      model.setPath([PlayerRoute(s.id)]);
                    },
              child: Stack(fit: StackFit.expand, children: [
                if (s != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: s.coverPath != null ? CoverArt(path: s.coverPath, radius: 0) : GeneratedCover(seed: s.id, radius: 0),
                  )
                else
                  Container(decoration: BoxDecoration(color: t.background.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3))),
                if (key == today) Container(decoration: BoxDecoration(border: Border.all(color: t.textPrimary, width: 1.5), borderRadius: BorderRadius.circular(3))),
                Positioned(
                  left: 3,
                  top: 1,
                  child: Text('${day.day}',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: s != null ? Colors.white : t.textTertiary,
                          shadows: s != null ? const [Shadow(color: Colors.black54, blurRadius: 3)] : null)),
                ),
                if (songs.length > 1)
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                      child: Text('+${songs.length - 1}', style: const TextStyle(fontSize: 9, color: Colors.white)),
                    ),
                  ),
                if (quizDays.contains(key))
                  Positioned(right: 3, top: 3, child: Container(width: 6, height: 6, decoration: BoxDecoration(color: t.brand, shape: BoxShape.circle))),
              ]),
            );
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 4),
          Container(width: 6, height: 6, decoration: BoxDecoration(color: t.brand, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(tr('퀴즈를 푼 날'), style: TextStyle(fontSize: 11, color: t.textTertiary)),
        ]),
      ]),
    );
  }
}

/// Small stats row for My page.
class MyStats extends StatelessWidget {
  const MyStats({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final songs = model.collection.songs;
    Widget stat(String v, String l) => Expanded(
          child: Column(children: [
            Text(v, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: t.textPrimary)),
            const SizedBox(height: 2),
            Text(l, style: TextStyle(fontSize: 12, color: t.textTertiary)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        stat('${songs.length}', tr('모은 노래')),
        stat('${songs.where((s) => s.isConquered).length}', tr('정복')),
        stat('${model.collection.phrases.length}', tr('저장한 문장')),
        stat(tr('{0}일', [model.quiz.streak]), tr('연속 공부')),
      ]),
    );
  }
}

