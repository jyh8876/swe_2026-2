import 'dart:math';

import 'models.dart';

/// One fill-in-the-blank question built from a lyric line.
class QuizQuestion {
  final int lineIndex;
  final String before;
  final String answer;
  final String after;

  /// The line's translation, shown as the hint (Duolingo-style "문장해석 주고, 빈칸 넣기").
  final String? translation;

  /// Answer plus distractors in random order. Empty for typed questions.
  final List<String> choices;

  const QuizQuestion({
    required this.lineIndex,
    required this.before,
    required this.answer,
    required this.after,
    this.translation,
    this.choices = const [],
  });

  bool get typed => choices.isEmpty;

  bool isCorrect(String guess) => QuizBuilder.clean(guess) == QuizBuilder.clean(answer);
}

/// Builds lyric quizzes on the device, so they work offline and appear instantly.
/// Level 1: short common words, 4 choices. Level 2: longer words, 4 choices.
/// Level 3: type the word with only the first letter shown. Passing all levels conquers the song.
class QuizBuilder {
  static const levels = 3;
  static const perLevel = 5;
  static const passMark = 4;

  static const levelTitles = ['레벨 1 · 쉬운 단어', '레벨 2 · 핵심 단어', '레벨 3 · 직접 쓰기'];

  static const _stop = {
    'the', 'and', 'but', 'for', 'nor', 'yet', 'you', 'your', 'are', 'was', 'were', 'his', 'her', 'its', 'our',
    'they', 'them', 'this', 'that', 'with', 'from', 'into', 'have', 'has', 'had', 'not', 'all', 'can', 'just',
    'what', 'when', 'who', 'how', 'she', 'him', 'too', 'got', 'get', 'out', 'off', 'yeah', 'ooh', 'oh', 'uh',
    'la', 'na', 'hey', 'woah', 'whoa', 'mmm', 'ahh', 'ayy', 'gonna', 'wanna', 'gotta', 'there', 'then', 'than',
  };

  static final _word = RegExp(r"[\p{L}][\p{L}']*", unicode: true);

  /// Lower-case letters only, for comparing answers.
  static String clean(String s) => s.toLowerCase().replaceAll(RegExp(r"[^\p{L}]", unicode: true), '');

  static bool _usable(String w, int level) {
    final c = clean(w);
    if (_stop.contains(c) || c.length < 3) return false;
    return switch (level) { 1 => c.length <= 6, 2 => c.length >= 5, _ => c.length >= 4 };
  }

  /// Lines that can produce a question at [level]: unique texts (repeated choruses count once)
  /// with at least three words.
  static List<LyricLine> eligibleLines(List<LyricLine> lines, int level) {
    final seen = <String>{};
    return [
      for (final l in lines)
        if (l.text.trim().split(RegExp(r'\s+')).length >= 3 &&
            seen.add(clean(l.text)) &&
            _word.allMatches(l.text).any((m) => _usable(m[0]!, level)))
          l,
    ];
  }

  static bool canQuiz(List<LyricLine> lines) => eligibleLines(lines, 1).length >= 3;

  static List<QuizQuestion> build({required List<LyricLine> lines, required Map<int, String> translations, required int level, Random? rng}) {
    final r = rng ?? Random();
    final pool = eligibleLines(lines, level)..shuffle(r);
    // Distractors come from the same song, so they sound plausible.
    final vocab = <String>{
      for (final l in lines)
        for (final m in _word.allMatches(l.text))
          if (clean(m[0]!).length >= 3 && !_stop.contains(clean(m[0]!))) m[0]!.toLowerCase(),
    }.toList();

    final out = <QuizQuestion>[];
    for (final line in pool.take(perLevel)) {
      final words = _word.allMatches(line.text).where((m) => _usable(m[0]!, level)).toList();
      // Prefer the longest word on harder levels, any usable word on level 1.
      words.sort((a, b) => b[0]!.length.compareTo(a[0]!.length));
      final m = level == 1 ? words[r.nextInt(words.length)] : words.first;
      final answer = m[0]!;
      var choices = <String>[];
      if (level < 3) {
        final others = vocab.where((v) => clean(v) != clean(answer)).toList()..shuffle(r);
        // Similar length first, so the blank's width does not give it away.
        others.sort((a, b) => (a.length - answer.length).abs().compareTo((b.length - answer.length).abs()));
        final picked = others.take(6).toList()..shuffle(r);
        choices = [answer, ...picked.take(3)];
        for (final f in const ['heart', 'night', 'dream', 'light', 'time', 'love']) {
          if (choices.length >= 4) break;
          if (!choices.any((c) => clean(c) == f)) choices.add(f);
        }
        choices.shuffle(r);
      }
      out.add(QuizQuestion(
        lineIndex: line.index,
        before: line.text.substring(0, m.start),
        answer: answer,
        after: line.text.substring(m.end),
        translation: translations[line.index],
        choices: choices,
      ));
    }
    return out;
  }
}
