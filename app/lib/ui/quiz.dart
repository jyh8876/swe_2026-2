import 'package:flutter/material.dart' hide Route;

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/platform_services.dart';
import '../app/theme.dart';
import '../core/models.dart';
import '../core/quiz.dart';
import 'components.dart';
import 'covers.dart';

/// Quiz tab (Notion b/d): fill-in-the-blank questions from the user's own songs, in three levels.
/// Clearing every level conquers the song.
class QuizHomeView extends StatelessWidget {
  const QuizHomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final songs = model.collection.songsNewestFirst.where((s) => model.canQuiz(s.id)).toList();
    final conquered = model.collection.songs.where((s) => s.isConquered).length;
    return Scaffold(
      appBar: AppBar(title: Text(tr('퀴즈'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            _stat(t, tr('{0}일', [model.quiz.streak]), tr('연속 공부')),
            _stat(t, tr('{0}곡', [conquered]), tr('정복한 노래')),
            _stat(t, tr('{0}곡', [songs.length]), tr('풀 수 있는 노래')),
          ]),
        ),
        const SizedBox(height: 12),
        Text(tr('가사 빈칸을 채우면 다음 레벨이 열려요. 레벨 3까지 깨면 노래를 정복해요.'), style: TextStyle(fontSize: 13, color: t.textTertiary)),
        const SizedBox(height: 16),
        if (songs.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Column(children: [
              Icon(Icons.quiz_outlined, size: 40, color: t.textTertiary),
              const SizedBox(height: 12),
              Text(tr('노래를 추가하면 그 가사로 퀴즈를 풀 수 있어요'), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: t.textSecondary)),
              const SizedBox(height: 20),
              SecondaryButton(tr('노래 추가하기'), icon: Icons.add, onPressed: () {
                model.selectTab(AppTab.library);
                model.push(const SearchRoute());
              }),
            ]),
          )
        else
          for (final s in songs) Padding(padding: const EdgeInsets.only(bottom: 10), child: _SongQuizRow(song: s)),
      ]),
    );
  }

  Widget _stat(AppTheme t, String value, String label) => Expanded(
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: t.textTertiary)),
        ]),
      );
}

class _SongQuizRow extends StatelessWidget {
  final Song song;
  const _SongQuizRow({required this.song});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final level = model.quiz.level(song.id);
    final done = level >= QuizBuilder.levels;
    final next = done ? QuizBuilder.levels : level + 1;
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openQuiz(context, song.id, next),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            SizedBox(
              width: 52,
              height: 52,
              child: song.coverPath != null ? CoverArt(path: song.coverPath, radius: 2) : GeneratedCover(seed: song.id, label: song.title),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.textPrimary)),
                Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.textTertiary)),
                const SizedBox(height: 6),
                Row(children: [
                  for (var i = 1; i <= QuizBuilder.levels; i++)
                    Container(
                      width: 28,
                      height: 6,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(color: i <= level ? t.brand : t.surfaceRaised, borderRadius: BorderRadius.circular(3)),
                    ),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: done ? t.gold.withValues(alpha: 0.2) : t.accent, borderRadius: BorderRadius.circular(99)),
              child: Text(done ? tr('정복 👑') : tr('레벨 {0}', [next]),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: done ? t.gold : t.onAccent)),
            ),
          ]),
        ),
      ),
    );
  }
}

void openQuiz(BuildContext context, String songID, int level) =>
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => QuizSessionView(songID: songID, level: level)));

/// One level: five questions, Duolingo-style check / feedback / continue.
class QuizSessionView extends StatefulWidget {
  final String songID;
  final int level;
  const QuizSessionView({super.key, required this.songID, required this.level});
  @override
  State<QuizSessionView> createState() => _QuizSessionViewState();
}

class _QuizSessionViewState extends State<QuizSessionView> {
  late int level = widget.level;
  List<QuizQuestion> questions = [];
  int index = 0, correct = 0;
  String? picked;
  bool? checked; // null = not checked yet, else whether the answer was right
  bool finished = false, conqueredNow = false;
  final _typed = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (questions.isEmpty && !finished) _start();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _start() {
    final model = context.readModel;
    questions = QuizBuilder.build(lines: model.collection.linesFor(widget.songID), translations: model.translationsFor(widget.songID), level: level);
    index = 0;
    correct = 0;
    picked = null;
    checked = null;
    finished = false;
    conqueredNow = false;
    _typed.clear();
  }

  QuizQuestion get q => questions[index];

  void _check() {
    final guess = q.typed ? _typed.text : picked;
    if (guess == null || guess.trim().isEmpty) return;
    final ok = q.isCorrect(guess);
    if (ok) {
      correct++;
      Haptics.success();
    } else {
      Haptics.light();
    }
    setState(() => checked = ok);
  }

  void _next() {
    if (index + 1 < questions.length) {
      setState(() {
        index++;
        picked = null;
        checked = null;
        _typed.clear();
      });
      return;
    }
    final model = context.readModel;
    model.recordQuizActivity();
    final passed = correct >= QuizBuilder.passMark.clamp(1, questions.length);
    if (passed) conqueredNow = model.passQuizLevel(widget.songID, level);
    setState(() => finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    final song = model.collection.song(widget.songID);
    if (song == null || questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(tr('이 노래로는 퀴즈를 만들 수 없어요'), style: TextStyle(color: t.textSecondary))),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: tr('닫기'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        title: Text(tr(QuizBuilder.levelTitles[level - 1]), style: const TextStyle(fontSize: 15)),
      ),
      body: SafeArea(child: finished ? _result(model, t, song) : _question(t, song)),
    );
  }

  Widget _question(AppTheme t, Song song) {
    final q = this.q;
    final answered = checked != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: (index + (answered ? 1 : 0)) / questions.length,
            minHeight: 10,
            color: t.brand,
            backgroundColor: t.surfaceRaised,
          ),
        ),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text(q.typed ? tr('빈칸에 들어갈 단어를 써 보세요') : tr('빈칸에 들어갈 단어를 고르세요'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 6),
          Text('${song.title} · ${song.artist}', style: TextStyle(fontSize: 13, color: t.textTertiary)),
          const SizedBox(height: 20),
          if (q.translation != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.translate, size: 18, color: t.brandInk),
                const SizedBox(width: 10),
                Expanded(child: Text(q.translation!, style: TextStyle(fontSize: 15, color: t.textSecondary))),
              ]),
            ),
          const SizedBox(height: 20),
          Text.rich(
            TextSpan(style: TextStyle(fontSize: 22, height: 1.6, color: t.textPrimary), children: [
              TextSpan(text: q.before),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  constraints: BoxConstraints(minWidth: 18.0 * q.answer.length.clamp(3, 10)),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: answered ? (checked! ? t.brand.withValues(alpha: 0.2) : const Color(0x33E5484D)) : t.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border(bottom: BorderSide(color: answered ? (checked! ? t.brand : const Color(0xFFE5484D)) : t.textTertiary, width: 2)),
                  ),
                  child: Text(
                    answered ? q.answer : (q.typed ? '${q.answer[0]}…' : (picked ?? ' ')),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: t.textPrimary),
                  ),
                ),
              ),
              TextSpan(text: q.after),
            ]),
          ),
          const SizedBox(height: 28),
          if (q.typed)
            OutlinedField(controller: _typed, hint: tr('{0}로 시작하는 단어', [q.answer[0]]), onChanged: (_) => setState(() {}))
          else
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in q.choices)
                ChoiceChip(
                  label: Text(c, style: TextStyle(fontSize: 16, color: picked == c ? t.onAccent : t.textPrimary)),
                  selected: picked == c,
                  showCheckmark: false,
                  selectedColor: t.accent,
                  backgroundColor: t.surface,
                  side: BorderSide(color: t.stroke),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  onSelected: answered ? null : (_) => setState(() => picked = c),
                ),
            ]),
        ]),
      ),
      AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        color: !answered ? Colors.transparent : (checked! ? t.brand.withValues(alpha: 0.16) : const Color(0x26E5484D)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (answered) ...[
            Text(checked! ? tr('정답이에요!') : tr('아쉬워요. 정답: {0}', [q.answer]),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: checked! ? t.brandInk : const Color(0xFFE5484D))),
            const SizedBox(height: 12),
          ],
          PrimaryButton(
            answered ? tr('계속하기') : tr('확인'),
            onPressed: answered ? _next : ((q.typed ? _typed.text.trim().isNotEmpty : picked != null) ? _check : null),
          ),
        ]),
      ),
    ]);
  }

  Widget _result(AppModel model, AppTheme t, Song song) {
    final passed = correct >= QuizBuilder.passMark.clamp(1, questions.length);
    final hasNext = passed && level < QuizBuilder.levels;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        const Spacer(),
        Icon(conqueredNow ? Icons.emoji_events : (passed ? Icons.check_circle : Icons.refresh), size: 72, color: conqueredNow ? t.gold : (passed ? t.brand : t.textTertiary)),
        const SizedBox(height: 16),
        Text(conqueredNow ? tr('이 노래를 정복했어요!') : (passed ? tr('레벨 {0} 통과!', [level]) : tr('조금만 더!')),
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: t.textPrimary)),
        const SizedBox(height: 8),
        Text(tr('{0}문제 중 {1}개 정답', [questions.length, correct]) + (passed ? '' : ' · ${tr('{0}개 이상 맞히면 통과', [QuizBuilder.passMark])}'),
            style: TextStyle(fontSize: 15, color: t.textSecondary)),
        const Spacer(flex: 2),
        if (hasNext)
          PrimaryButton(tr('레벨 {0} 도전', [level + 1]), onPressed: () => setState(() {
                level++;
                _start();
              }))
        else
          PrimaryButton(passed ? tr('완료') : tr('다시 도전'), onPressed: passed ? () => Navigator.pop(context) : () => setState(_start)),
        const SizedBox(height: 12),
        SecondaryButton(tr('닫기'), onPressed: () => Navigator.pop(context)),
      ]),
    );
  }
}
