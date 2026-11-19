import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/models.dart';

/// Records the lines it is asked to translate; answers `T:text` with the reading `R:text`.
class _RecordingEngine implements TranslationEngine {
  final asked = <int>[];
  final Set<int> drop;
  _RecordingEngine({this.drop = const {}});

  @override
  String get id => 'test';
  @override
  bool get isAvailable => true;
  @override
  EngineKind get kind => EngineKind.onDevice;

  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    for (final l in lines) {
      asked.add(l.index);
      if (drop.contains(l.index)) continue;
      yield Translated(l.index, 'T:${l.text}', reading: 'R:${l.text}');
    }
  }

  @override
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target) => throw UnimplementedError();
}

List<LyricLine> _lines(List<String> texts) => [for (var i = 0; i < texts.length; i++) LyricLine(songID: 's', index: i, text: texts[i])];

void main() {
  group('발음 (reading)', () {
    test('an entry\'s "r" becomes the reading; a missing or blank one is left out', () {
      final r = OutputValidator.entryResult(0, {'i': 0, 't': '너의 이름은', 'r': '키미노 나와'}) as Translated;
      expect(r.text, '너의 이름은');
      expect(r.reading, '키미노 나와');
      expect((OutputValidator.entryResult(1, {'i': 1, 't': 'x'}) as Translated).reading, isNull);
      expect((OutputValidator.entryResult(2, {'i': 2, 't': 'x', 'r': '  '}) as Translated).reading, isNull);
      expect(OutputValidator.entryResult(3, {'i': 3, 'copy': true}), isA<Copied>());
    });

    test('streamed entries carry the reading', () {
      final p = StreamingLineParser({0, 1});
      final out = [...p.feed('{"lines":[{"i":0,"t":"안녕","r":"하로"},'), ...p.feed('{"r":"바이","i":1,"t":"잘 가"}]}')];
      expect(out.map((e) => (e as Translated).reading), ['하로', '바이']);
    });

    test('the reading is stored with the translation and old saves still load', () {
      final c = CollectionSnapshot();
      c.commit(const Translated(0, '너의 이름은', reading: '키미노 나와'), songID: 's', target: 'ko', engineID: 'e');
      expect(c.readingText('s', 0, 'ko'), '키미노 나와');
      final back = Translation.fromJson(c.translations.single.toJson(DateCodec.local), DateCodec.local);
      expect(back.reading, '키미노 나와');
      final old = c.translations.single.toJson(DateCodec.local)..remove('reading');
      expect(Translation.fromJson(old, DateCodec.local).reading, isNull);
    });

    test('the prompt asks for Hangul readings for Korean readers', () {
      expect(Prompts.translationSystem(Language.korean), contains('"r"'));
      expect(Prompts.translationSystem(Language.korean), contains('Hangul'));
      expect(Prompts.translationSystem(Language.japanese), contains('Katakana'));
    });
  });

  group('repeated lines are translated once', () {
    test('only the first of each identical line goes to the engine; repeats get the same result', () async {
      final lines = _lines(['A', 'B', 'A', 'C', 'B ', 'A']);
      final engine = _RecordingEngine();
      final committed = <LineResult>[];
      TranslationProgress? last;
      await TranslationJob(songID: 's', lines: lines, target: Language.korean, engine: engine)
          .run(alreadyDone: {}, commit: committed.add, progress: (p) => last = p, token: CancelToken());
      expect(engine.asked, [0, 1, 3]);
      final byIndex = {for (final r in committed) r.index: r as Translated};
      expect(byIndex.keys.toSet(), {0, 1, 2, 3, 4, 5});
      expect(byIndex[2]!.text, 'T:A');
      expect(byIndex[5]!.reading, 'R:A');
      expect(byIndex[4]!.text, 'T:B');
      expect(last!.done, 6);
      expect(last!.total, 6);
    });

    test('a line the engine skipped fails together with its repeats', () async {
      final committed = <LineResult>[];
      await TranslationJob(songID: 's', lines: _lines(['A', 'B', 'A']), target: Language.korean, engine: _RecordingEngine(drop: {0}))
          .run(alreadyDone: {}, commit: committed.add, progress: (_) {}, token: CancelToken());
      expect(committed.whereType<Failed>().map((r) => r.index).toSet(), {0, 2});
      expect(committed.whereType<Translated>().single.index, 1);
    });
  });
}
