import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'models.dart';

/// User-facing engine choice (FG-00, FG-09).
enum EngineKind {
  onDevice,
  vynilo,
  gateway,
  claude,
  gemini;

  /// The engines the app offers (Notion 11/19: on-device, Gemini, gateway). Vynilo server and
  /// Claude are no longer offered; saved settings that used them move to Gemini.
  static const offered = [EngineKind.onDevice, EngineKind.gemini, EngineKind.gateway];
  bool get isOffered => offered.contains(this);

  /// Engines whose key is entered on the API key screen (Claude, Gemini).
  /// The Vynilo server and gateways have their own settings screens.
  bool get requiresAPIKey => this == EngineKind.claude || this == EngineKind.gemini;

  /// Sends lyrics off the device, so the one-time cloud notice applies (SIR-3).
  bool get isCloud => this != EngineKind.onDevice;

  /// Badge label shown on FG-04/FG-06 (SIR-3).
  String get badgeLabel => switch (this) {
        EngineKind.onDevice => 'On-device',
        EngineKind.vynilo => 'Vynilo',
        EngineKind.gateway => 'Gateway',
        EngineKind.claude => 'Claude',
        EngineKind.gemini => 'Gemini',
      };
}

/// Per-line outcome of a song translation.
sealed class LineResult {
  final int index;
  const LineResult(this.index);
}

class Translated extends LineResult {
  final String text;

  /// 독음 of the original line in the reader's script, when the engine gives one.
  final String? reading;
  const Translated(super.index, this.text, {this.reading});
}

/// Line already in the target language; copied, not translated (RQ-7).
class Copied extends LineResult {
  const Copied(super.index);
}

class Failed extends LineResult {
  final String reason;
  const Failed(super.index, this.reason);
}

extension LineResults on LineResult {
  /// The same result for another line with identical text.
  static LineResult reindex(LineResult r, int index) => switch (r) {
        Translated() => Translated(index, r.text, reading: r.reading),
        Copied() => Copied(index),
        Failed() => Failed(index, r.reason),
      };
}

/// SSRD A.III `Translator` + `Explainer`.
/// id: `llama:<model>@<quant>` | `claude:<model>` | `gemini:<model>` | `demo@<prompt>`
abstract class TranslationEngine {
  String get id;
  bool get isAvailable;
  EngineKind get kind;

  /// Yields one result per line, in any order.
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target);
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target);
}

enum LLMErrorKind { missingAPIKey, invalidKey, outOfCredit, rateLimited, server, network, malformedOutput, refused, unavailable }

class LLMError implements Exception {
  final LLMErrorKind kind;
  final int? status;
  final String? detail;
  const LLMError(this.kind, {this.status, this.detail});

  static const missingAPIKey = LLMError(LLMErrorKind.missingAPIKey);
  static const invalidKey = LLMError(LLMErrorKind.invalidKey);
  static const outOfCredit = LLMError(LLMErrorKind.outOfCredit);
  static const rateLimited = LLMError(LLMErrorKind.rateLimited);
  static const network = LLMError(LLMErrorKind.network);
  static const refused = LLMError(LLMErrorKind.refused);

  /// Plain-language message for the UI (Korean, matching the Figma copy).
  String get userMessage => switch (kind) {
        LLMErrorKind.missingAPIKey => 'API 키를 먼저 입력해 주세요.',
        LLMErrorKind.invalidKey => 'API 키가 올바르지 않아요. 키를 다시 확인해 주세요.',
        LLMErrorKind.outOfCredit => 'API 계정의 크레딧이 부족해요.',
        LLMErrorKind.rateLimited => '요청이 많아 잠시 후 다시 시도해요.',
        LLMErrorKind.server => status == 503 || status == 504
            ? 'AI 서버가 지금 붐벼요. 잠시 후 다시 시도해 주세요 ($status).'
            : '일시적인 오류예요. 잠시 후 다시 시도해 주세요 ($status).',
        LLMErrorKind.network => '인터넷에 연결되어 있지 않아요.',
        LLMErrorKind.malformedOutput => '번역 결과를 확인하지 못했어요. 다시 시도해 주세요.',
        LLMErrorKind.refused => '현재 엔진에서는 이 해설을 제공할 수 없어요.',
        LLMErrorKind.unavailable => detail ?? '사용할 수 없어요.',
      };

  bool get isRetryable => kind == LLMErrorKind.rateLimited || kind == LLMErrorKind.server;

  @override
  String toString() => 'LLMError($kind, $status, $detail)';
}

/// Retry with exponential backoff, up to 3 attempts (ONRQ-10).
Future<T> withBackoff<T>(Future<T> Function() op, {int attempts = 3, double baseDelay = 0.5}) async {
  LLMError? last;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await op();
    } on LLMError catch (e) {
      if (!e.isRetryable) rethrow;
      last = e;
      if (attempt < attempts - 1) {
        await Future.delayed(Duration(milliseconds: (baseDelay * pow(2, attempt) * 1000).round()));
      }
    }
  }
  throw last ?? LLMError.network;
}

/// Prompt templates. Versioned: translations and explanations are keyed by prompt version,
/// so changing a prompt never overwrites earlier results (A.III data model).
class Prompts {
  /// p2 adds the reading ("r") of each translated line; p3 softens profanity; p4 keeps "t" (meaning)
  /// and "r" (sound) apart and stops copying lines in other scripts.
  static const version = 'p4';

  /// The script a reader of [target] uses to read how a foreign line sounds (독음).
  static String readingScript(Language target) => switch (target.code) {
        'ko' => 'Hangul letters that spell the sound (독음)',
        'ja' => 'Katakana',
        'zh' => 'Pinyin with tone marks for Chinese lines, otherwise Latin letters',
        _ => 'Latin letters (romanization)',
      };

  static String translationSystem(Language target) => '''You translate song lyrics for language learners.
Translate each numbered line into natural, idiomatic ${target.englishName} (${target.code}).
Rules:
- Keep the meaning, tone and register of the song; prefer natural phrasing over literal word order.
- Use the surrounding lines as context for pronouns, tense and slang.
- Return exactly one entry per input index. Never merge or split lines.
- "t" is always the MEANING of the line written in ${target.englishName}. Never put a transcription of the sound in "t".
- Use "copy": true only when the line's words are already ${target.englishName}. A line in any other language or script (Japanese, Chinese, English…) must be translated, even when it is short.
- For every translated line also give "r": how the ORIGINAL line sounds when sung, written in ${readingScript(target)}. "r" is the sound only, never the meaning. Leave "r" out when the original is already written in that script.
${target.code == 'ko' ? '- Example for the Japanese line 君の名前を呼んだ: {"i":0,"t":"너의 이름을 불렀어","r":"키미노 나마에오 욘다"}\n' : ''}- Profanity, slurs and crude sexual words: keep what the line means and how strong the feeling is, but write it in milder words a general audience can read (e.g. "fucking" used as an intensifier → "really"; a slur → a neutral word for the person). Never use asterisks or blanks; never leave a line untranslated because of its words.
Respond only with JSON: {"lines":[{"i":0,"t":"...","r":"..."},{"i":1,"copy":true}]}''';

  static String translationUser(List<LyricLine> lines) => lines.map((l) => '${l.index}\t${l.text}').join('\n');

  static String explanationSystem(Language target) =>
      '''You explain one line of song lyrics to a learner whose native language is ${target.englishName}.
Write every field in ${target.englishName}. Quote original expressions as they appear in the lyric.
Pick at most 3 key expressions, ranked by learning value (slang and idioms first).
When an expression is profane or a slur, say so plainly and give a mild equivalent; do not repeat it in the example sentence.
Respond only with JSON:
{"expressions":[{"phrase":"...","meaning":"..."}],"structure":"one line","usage":"when to use it","example":"an example sentence"}''';

  static String explanationUser(LyricLine line, List<LyricLine> context) {
    final ctx = context.map((l) => (l.index == line.index ? '> ' : '  ') + l.text).join('\n');
    return 'Stanza:\n$ctx\n\nExplain the line marked with >:\n${line.text}';
  }

  /// Stanza-sized context window around a line (RQ-7).
  static List<LyricLine> context(LyricLine line, List<LyricLine> lines, {int radius = 3}) {
    final lo = max(0, line.index - radius);
    final hi = min(lines.length - 1, line.index + radius);
    if (lo > hi) return [line];
    return lines.sublist(lo, hi + 1);
  }
}

/// Picks complete line entries out of a translation response while it is still being generated, so
/// each line can be shown as soon as the model has written it.
class StreamingLineParser {
  final Set<int> wanted;
  final _text = StringBuffer();
  int _pos = 0;
  final _seen = <int>{};
  static final _entryStart = RegExp(r'\{\s*"(i|t|r|copy)"\s*:');

  StreamingLineParser(this.wanted);

  /// Adds a piece of model text; returns the entries completed by it. Failed entries are left for
  /// the final validation and retry.
  List<LineResult> feed(String piece) {
    _text.write(piece);
    final s = _text.toString();
    final out = <LineResult>[];
    while (true) {
      final m = _entryStart.firstMatch(s.substring(_pos));
      if (m == null) break;
      final start = _pos + m.start;
      final end = _closing(s, start);
      if (end < 0) break; // the entry is not finished yet
      _pos = end + 1;
      try {
        final e = jsonDecode(s.substring(start, end + 1));
        if (e is! Map || e['i'] is! num) continue;
        final i = (e['i'] as num).toInt();
        if (!wanted.contains(i) || !_seen.add(i)) continue;
        final r = OutputValidator.entryResult(i, e);
        if (r is Failed) {
          _seen.remove(i);
        } else {
          out.add(r);
        }
      } catch (_) {}
    }
    return out;
  }

  String get text => _text.toString();

  /// Index of the brace closing the object that starts at [start], or -1. Braces inside strings
  /// (and escaped quotes) are ignored.
  static int _closing(String s, int start) {
    var depth = 0;
    var inString = false;
    for (var k = start; k < s.length; k++) {
      final c = s[k];
      if (inString) {
        if (c == '\\') {
          k++;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return k;
      }
    }
    return -1;
  }
}

/// Decoding and validation of model output (ONRQ-12).
class OutputValidator {
  /// Extracts the first JSON object from model text (models sometimes wrap it in prose or fences).
  static String? extractJSON(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end < 0 || start >= end) return null;
    return text.substring(start, end + 1);
  }

  /// Maps raw model output to per-line results. Every input index is accounted for:
  /// missing, empty, or repeated-garbage lines become failed so they can be retried (LOS-2).
  static List<LineResult> translationResults(String text, List<LyricLine> lines) {
    final byIndex = <int, Map>{};
    final json = extractJSON(text);
    if (json != null) {
      try {
        final payload = jsonDecode(json);
        for (final e in (payload['lines'] as List)) {
          final i = (e['i'] as num).toInt();
          byIndex.putIfAbsent(i, () => e as Map);
        }
      } catch (_) {}
    }
    return lines.map<LineResult>((line) {
      final entry = byIndex[line.index];
      if (entry == null) return Failed(line.index, 'missing');
      return entryResult(line.index, entry);
    }).toList();
  }

  /// One `{"i":…,"t":…}` / `{"i":…,"copy":true}` entry → result, with the same checks for whole and
  /// streamed output.
  static LineResult entryResult(int index, Map entry) {
    if (entry['copy'] == true) return Copied(index);
    final t = '${entry['t'] ?? ''}'.trim();
    if (t.isEmpty) return Failed(index, 'empty');
    if (isDegenerate(t)) return Failed(index, 'repetition');
    final r = '${entry['r'] ?? ''}'.trim();
    // A bad reading never fails the line; it is just left out.
    return Translated(index, t, reading: r.isEmpty || isDegenerate(r) ? null : r);
  }

  static Explanation explanation(String text) {
    final json = extractJSON(text);
    if (json == null) throw const LLMError(LLMErrorKind.malformedOutput, detail: 'no JSON');
    Explanation e;
    try {
      final m = jsonDecode(json) as Map;
      if (m['expressions'] is! List || m['structure'] is! String || m['usage'] is! String || m['example'] is! String) {
        throw const FormatException();
      }
      e = Explanation.fromJson(Map<String, dynamic>.from(m));
    } catch (_) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'schema');
    }
    if (e.structure.isEmpty && e.expressions.isEmpty) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'empty');
    }
    return e;
  }

  /// Detects runaway repetition such as "la la la la la la la la" produced by small models.
  static bool isDegenerate(String s) {
    final words = s.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < 8) return false;
    return words.toSet().length * 4 < words.length;
  }
}

/// Cheap script-based guess used by the demo engine and on-device language detection (RQ-15).
class LanguageGuess {
  static final _letter = RegExp(r'\p{L}', unicode: true);

  static bool isLikely(String text, String code) {
    final letters = text.runes.where((r) => _letter.hasMatch(String.fromCharCode(r))).toList();
    if (letters.isEmpty) return true;
    final hangul = letters.where((r) => (r >= 0xAC00 && r <= 0xD7A3) || (r >= 0x1100 && r <= 0x11FF)).length;
    final latin = letters.where((r) => r < 128).length;
    final kana = letters.where((r) => r >= 0x3040 && r <= 0x30FF).length;
    final han = letters.where((r) => r >= 0x4E00 && r <= 0x9FFF).length;
    return switch (code) {
      'ko' => hangul / letters.length > 0.5,
      'en' => latin / letters.length > 0.9,
      'ja' => kana / letters.length > 0.2,
      'zh' => kana == 0 && han / letters.length > 0.5,
      _ => false, // German, French…: the model decides whether a line is already translated
    };
  }

  static const _stopwords = {
    'en': {'the', 'and', 'you', 'i', 'is', 'are', 'to', 'of', 'in', 'my', 'me', 'it', 'that', 'your', 'on', 'for', 'with', 'be', 'all', 'love'},
    'de': {'der', 'die', 'das', 'und', 'ist', 'nicht', 'ich', 'du', 'wir', 'ein', 'eine', 'mit', 'mich', 'dich', 'auf', 'zu', 'es', 'sie', 'mein', 'dein'},
    'fr': {'le', 'la', 'les', 'et', 'est', 'je', 'tu', 'nous', 'vous', 'pas', 'une', 'des', 'que', 'qui', 'mon', 'ma', 'dans', 'pour', 'avec', 'moi'},
    'es': {'el', 'los', 'las', 'y', 'es', 'yo', 'tú', 'que', 'no', 'una', 'con', 'mi', 'por', 'para', 'pero', 'como', 'te', 'se', 'lo', 'amor'},
  };

  /// Main language of a whole song, or null when mixed or unsure. Scripts decide for Korean,
  /// Japanese and Chinese; common words decide between English, German, French and Spanish.
  /// Used to skip translating a song that is already in the target language.
  static String? songLanguage(Iterable<String> lines, {double share = 0.7}) {
    final text = lines.join('\n');
    final letters = text.runes.where((r) => _letter.hasMatch(String.fromCharCode(r))).toList();
    if (letters.length < 20) return null;
    int count(bool Function(int) f) => letters.where(f).length;
    final n = letters.length;
    final hangul = count((r) => r >= 0xAC00 && r <= 0xD7A3) / n;
    final kana = count((r) => r >= 0x3040 && r <= 0x30FF) / n;
    final han = count((r) => r >= 0x4E00 && r <= 0x9FFF) / n;
    final latin = count((r) => r < 0x250) / n;
    if (hangul >= share) return 'ko';
    if (kana >= 0.15 && kana + han >= share) return 'ja';
    if (han >= share && kana == 0) return 'zh';
    if (latin < share + 0.2) return null;
    final words = RegExp(r"[\p{L}']+", unicode: true).allMatches(text.toLowerCase()).map((m) => m[0]!).toList();
    if (words.length < 8) return null;
    final hits = {for (final e in _stopwords.entries) e.key: words.where(e.value.contains).length};
    final ranked = hits.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first, second = ranked[1];
    // Clearly ahead of the next language, and frequent enough to be the song's language.
    if (best.value >= words.length * 0.12 && best.value >= second.value * 2) return best.key;
    return null;
  }

  /// Best-effort BCP-47 code for a line, or null when unsure.
  static String? detect(String text) {
    final letters = text.runes.where((r) => _letter.hasMatch(String.fromCharCode(r))).toList();
    if (letters.length < 3) return null;
    int count(bool Function(int) f) => letters.where(f).length;
    final n = letters.length;
    if (count((r) => r >= 0xAC00 && r <= 0xD7A3) / n >= 0.5) return 'ko';
    if (count((r) => (r >= 0x3040 && r <= 0x30FF)) / n >= 0.2) return 'ja';
    if (count((r) => r >= 0x4E00 && r <= 0x9FFF) / n >= 0.5) return 'zh';
    if (count((r) => r < 128) / n >= 0.9) return RegExp(r'[ñ¿¡]').hasMatch(text) ? 'es' : 'en';
    return null;
  }
}

// ─────────────────────────────── Demo engine ───────────────────────────────

/// Deterministic stand-in engine. It lets the full add → translate → study loop run before
/// spike S1 picks the real on-device engine (llama.cpp vs. platform models, Win-AGRE-4).
/// An engine that cannot run yet (for example the on-device model is not downloaded). Every request
/// fails with [reason] instead of producing placeholder text.
class UnavailableEngine implements TranslationEngine {
  @override
  final EngineKind kind;
  final String reason;
  const UnavailableEngine(this.kind, this.reason);

  @override
  String get id => '${kind.name}:unavailable';
  @override
  bool get isAvailable => false;
  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) => Stream.error(LLMError(LLMErrorKind.unavailable, detail: reason));
  @override
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target) async =>
      throw LLMError(LLMErrorKind.unavailable, detail: reason);
}

/// Test double with canned output. Not used by the app.
class DemoEngine implements TranslationEngine {
  /// Simulated per-line latency so progress UI (FG-04) can be exercised.
  final Duration lineDelay;
  final Map<String, String> glossary;

  const DemoEngine({this.lineDelay = const Duration(milliseconds: 150), this.glossary = sampleGlossary});

  @override
  String get id => 'demo@${Prompts.version}';
  @override
  bool get isAvailable => true;
  @override
  EngineKind get kind => EngineKind.onDevice;

  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    for (final line in lines) {
      if (lineDelay > Duration.zero) await Future.delayed(lineDelay);
      if (LanguageGuess.isLikely(line.text, target.code)) {
        yield Copied(line.index);
      } else if (glossary[line.text] case final known?) {
        yield Translated(line.index, known);
      } else {
        yield Translated(line.index, '(${target.nativeName}) ${line.text}');
      }
    }
  }

  @override
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target) async {
    if (lineDelay > Duration.zero) await Future.delayed(lineDelay * 4);
    final words = line.text.split(' ').where((w) => w.isNotEmpty).toList();
    final phrase = words.take(min(3, words.length)).join(' ');
    return Explanation(
      expressions: [Expression(phrase: phrase, meaning: '‘$phrase’의 뜻 설명 (데모 엔진)')],
      structure: '문장 구조를 한 줄로 설명합니다.',
      usage: '어떤 상황에서 쓰는 표현인지 설명합니다.',
      example: 'Example sentence using “$phrase”.',
    );
  }

  /// Matches the bundled demo song in `DemoContent` (original text written for this prototype).
  static const sampleGlossary = {
    "Wake up, the city's humming low": '일어나, 도시가 낮게 웅웅거려',
    "I've been running on empty since the summer show": '여름 공연 이후로 난 계속 바닥난 채로 달려왔어',
    'But you said take it easy, let it go': '근데 넌 말했지, 편하게 생각해, 그냥 흘려보내',
    "So I'm calling it a day-off, nowhere to go": '그래서 오늘은 쉬는 날로 할래, 갈 데도 없이',
  };
}

// ─────────────────────────────── Cloud engines ───────────────────────────────

/// Shared shape of the BYOK engines: one request per song, never one per line (SIR-9).
abstract class CloudChatEngine implements TranslationEngine {
  final String apiKey;
  final String model;
  final http.Client client;

  CloudChatEngine(this.apiKey, this.model, http.Client? client) : client = client ?? http.Client();

  Future<String> complete({required String system, required String user, required int maxTokens});

  @override
  bool get isAvailable => apiKey.isNotEmpty;

  Future<http.Response> post(Uri url, Map<String, String> headers, Map<String, dynamic> body) async {
    try {
      return await client.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 90));
    } catch (_) {
      throw LLMError.network;
    }
  }

  /// The model's text as it is generated. Engines without streaming deliver it in one piece.
  Stream<String> completeStream({required String system, required String user, required int maxTokens}) async* {
    yield await complete(system: system, user: user, maxTokens: maxTokens);
  }

  /// POST with server-sent events. [delta] reads the text of one event; [whole] reads a plain JSON
  /// body, for gateways that ignore `stream: true`.
  Stream<String> postStream(Uri url, Map<String, String> headers, Map<String, dynamic> body,
      {required String? Function(Map event) delta, required String Function(String body) whole}) async* {
    final req = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);
    http.StreamedResponse r;
    try {
      r = await client.send(req).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw LLMError.network;
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      ClaudeEngine.check(r.statusCode, await r.stream.bytesToString());
    }
    if (!(r.headers['content-type'] ?? '').contains('event-stream')) {
      yield whole(await r.stream.bytesToString());
      return;
    }
    try {
      await for (final line in r.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(seconds: 60))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final t = delta(jsonDecode(data) as Map);
          if (t != null && t.isNotEmpty) yield t;
        } on LLMError {
          rethrow;
        } catch (_) {}
      }
    } on LLMError {
      rethrow;
    } catch (_) {
      throw LLMError.network;
    }
  }

  /// Lines are handed on as soon as the model has written them (streamed responses), so the song
  /// fills in line by line. Lines the stream did not deliver are validated from the full text and
  /// retried individually, as before.
  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    final toTranslate = lines.where((l) => l.text.isNotEmpty).toList();
    final parser = StreamingLineParser({for (final l in toTranslate) l.index});
    final delivered = <int>{};
    for (var attempt = 0;; attempt++) {
      try {
        await for (final piece in completeStream(
            system: Prompts.translationSystem(target), user: Prompts.translationUser(toTranslate), maxTokens: 4096)) {
          for (final r in parser.feed(piece)) {
            delivered.add(r.index);
            yield r;
          }
        }
        break;
      } on LLMError catch (e) {
        // Retry only while nothing has arrived; a partial answer is completed line by line below.
        if (delivered.isNotEmpty) break;
        if (!e.isRetryable || attempt >= 2) rethrow;
        await Future.delayed(Duration(milliseconds: (500 * pow(2, attempt)).round()));
      }
    }
    final rest = toTranslate.where((l) => !delivered.contains(l.index)).toList();
    if (rest.isEmpty) return;
    final results = OutputValidator.translationResults(parser.text, rest);

    // Failed lines are retried individually once with a stricter prompt (ONRQ-12).
    for (var pos = 0; pos < results.length; pos++) {
      final r = results[pos];
      if (r is! Failed) continue;
      final line = lines.firstWhere((l) => l.index == r.index);
      final ctx = Prompts.context(line, lines);
      try {
        final retry = await complete(
          system: '${Prompts.translationSystem(target)}\nReturn exactly one entry, for the index given.',
          user: '${Prompts.translationUser([line])}\n\nContext:\n${ctx.map((l) => l.text).join('\n')}',
          maxTokens: 512,
        );
        results[pos] = OutputValidator.translationResults(retry, [line]).first;
      } catch (_) {}
    }
    for (final r in results) {
      yield r;
    }
  }

  // Streaming is used for translations; explanations stay single requests.

  @override
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target) async {
    final system = Prompts.explanationSystem(target);
    final user = Prompts.explanationUser(line, context);
    final text = await withBackoff(() => complete(system: system, user: user, maxTokens: 1024));
    try {
      return OutputValidator.explanation(text);
    } on LLMError {
      // Invalid output is retried once, then surfaced as unavailable (RQ-11).
      final retry = await complete(system: '$system\nOutput valid JSON only.', user: user, maxTokens: 1024);
      return OutputValidator.explanation(retry);
    }
  }

  /// One minimal request for "Verify key" (RQ-14).
  Future<void> verifyKey() => complete(system: 'Reply with OK.', user: 'ping', maxTokens: 5);
}

/// Claude Messages API adapter (SIR-9).
class ClaudeEngine extends CloudChatEngine {
  static const defaultModel = 'claude-haiku-5-5';
  static final endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  ClaudeEngine(String apiKey, {String model = defaultModel, http.Client? client}) : super(apiKey, model, client);

  @override
  String get id => 'claude:$model';
  @override
  EngineKind get kind => EngineKind.claude;

  @override
  Future<String> complete({required String system, required String user, required int maxTokens}) async {
    if (apiKey.isEmpty) throw LLMError.missingAPIKey;
    final r = await post(endpoint, {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    }, {
      'model': model,
      'max_tokens': maxTokens,
      'system': system,
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    check(r.statusCode, r.body);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      if (j['stop_reason'] == 'refusal') throw LLMError.refused;
      return (j['content'] as List).map((b) => b['text']).whereType<String>().join();
    } on LLMError {
      rethrow;
    } catch (_) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'response');
    }
  }

  @override
  Stream<String> completeStream({required String system, required String user, required int maxTokens}) {
    if (apiKey.isEmpty) throw LLMError.missingAPIKey;
    return postStream(endpoint, {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    }, {
      'model': model,
      'max_tokens': maxTokens,
      'system': system,
      'stream': true,
      'messages': [
        {'role': 'user', 'content': user},
      ],
    }, delta: (e) {
      if (e['type'] == 'message_delta' && (e['delta'] as Map?)?['stop_reason'] == 'refusal') throw LLMError.refused;
      if (e['type'] != 'content_block_delta') return null;
      final text = (e['delta'] as Map?)?['text'];
      return text is String ? text : null;
    }, whole: (body) {
      final j = jsonDecode(body) as Map;
      return (j['content'] as List).map((b) => b['text']).whereType<String>().join();
    });
  }

  static void check(int status, String body) {
    if (status >= 200 && status < 300) return;
    switch (status) {
      case 401 || 403:
        throw LLMError.invalidKey;
      case 400:
        if (body.contains('credit')) throw LLMError.outOfCredit;
        throw const LLMError(LLMErrorKind.malformedOutput, detail: 'bad request');
      case 429:
        throw LLMError.rateLimited;
      default:
        throw LLMError(LLMErrorKind.server, status: status);
    }
  }
}

/// Gemini API adapter (SIR-10). Same contract as Claude behind the same engine interface.
class GeminiEngine extends CloudChatEngine {
  /// Used only when the model list cannot be read. Google closes older models to new keys
  /// (2.5 Flash answers 404 "no longer available to new users"), so models normally come from the
  /// key's own model list.
  static const defaultModel = 'gemini-3.5-flash-lite';
  static const _api = 'https://generativelanguage.googleapis.com/v1beta';

  /// Models to try for each key, best first, and the one that last answered.
  static final _candidates = <String, List<String>>{};
  static final _working = <String, String>{};

  /// Models that just failed for a key, until when to skip them: a 404 (closed to this key) for a
  /// day, an overloaded or hanging model for a few minutes.
  static final _resting = <String, Map<String, DateTime>>{};
  static DateTime Function() now = DateTime.now;

  /// Pause before the second round when every model was busy.
  static Duration retryDelay = const Duration(seconds: 3);

  final String? _fixedModel;

  GeminiEngine(String apiKey, {String? model, http.Client? client})
      : _fixedModel = model,
        super(apiKey, model ?? defaultModel, client);

  /// The model in use: the one given, else the one that last answered for this key, else the best
  /// candidate, else [defaultModel].
  String get currentModel => _fixedModel ?? _working[apiKey] ?? _candidates[apiKey]?.firstOrNull ?? defaultModel;

  @override
  String get id => 'gemini:$currentModel';
  @override
  EngineKind get kind => EngineKind.gemini;

  Map<String, String> get _headers => {'x-goog-api-key': apiKey, 'content-type': 'application/json'};

  /// Stable Flash and Flash-Lite models from [names], best first: Flash-Lite before Flash (Flash
  /// models answer 503 or hang for most free keys, while Flash-Lite answers), then the higher
  /// version. Previews, experiments, aliases and special-purpose models (image, audio,
  /// live, TTS) are left out.
  static List<String> rankModels(Iterable<String> names) {
    final re = RegExp(r'^gemini-(\d+(?:\.\d+)?)-flash(-lite)?(?:-(\d{3}))?$');
    final found = <(double, int, int, String)>[];
    for (final n in names) {
      final m = re.firstMatch(n);
      if (m != null) found.add((double.parse(m.group(1)!), m.group(2) == null ? 0 : 1, m.group(3) == null ? 1 : 0, n));
    }
    found.sort((a, b) => a.$2 != b.$2 ? b.$2 - a.$2 : (a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$3 - a.$3));
    return [for (final f in found) f.$4];
  }

  /// The first model [rankModels] would try (aliases only when nothing else fits).
  static String? pickModel(Iterable<String> names) {
    final ranked = rankModels(names);
    if (ranked.isNotEmpty) return ranked.first;
    return names.contains('gemini-flash-latest') ? 'gemini-flash-latest' : null;
  }

  /// Reads the models this key can use (no text is generated, so it costs nothing).
  /// Throws [LLMError.invalidKey] for a key Google does not accept.
  Future<List<String>> _models() async {
    final fixed = _fixedModel;
    if (fixed != null) return [fixed];
    final known = _candidates[apiKey];
    if (known != null) return known;
    if (apiKey.isEmpty) throw LLMError.missingAPIKey;
    final names = <String>[];
    String? page;
    for (var n = 0; n < 5; n++) {
      final http.Response r;
      try {
        r = await client
            .get(Uri.parse('$_api/models?pageSize=200${page == null ? '' : '&pageToken=$page'}'), headers: _headers)
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        throw LLMError.network;
      }
      _check(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      for (final m in (j['models'] as List? ?? const [])) {
        final methods = (m['supportedGenerationMethods'] as List?)?.cast<String>() ?? const [];
        if (methods.contains('generateContent')) names.add('${m['name']}'.replaceFirst('models/', ''));
      }
      page = j['nextPageToken'] as String?;
      if (page == null || page.isEmpty) break;
    }
    final ranked = rankModels(names);
    if (ranked.isEmpty) ranked.add(pickModel(names) ?? defaultModel);
    return _candidates[apiKey] = ranked;
  }

  /// Maps Gemini's error answers. 400 is a wrong key only when Google says so (API_KEY_INVALID);
  /// other 400s are bad requests, not the user's key.
  static void _check(http.Response r) {
    final s = r.statusCode;
    if (s >= 200 && s < 300) return;
    final body = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (s == 401 || s == 403 || (s == 400 && body.contains('API_KEY_INVALID'))) throw LLMError.invalidKey;
    if (s == 429) throw LLMError.rateLimited;
    throw LLMError(LLMErrorKind.server, status: s, detail: _message(body));
  }

  static String? _message(String body) {
    try {
      return '${((jsonDecode(body) as Map)['error'] as Map)['message']}';
    } catch (_) {
      return null;
    }
  }

  /// Thinking models count their reasoning against maxOutputTokens, which left translations cut
  /// off mid-JSON. 2.x models switch thinking off with a zero budget; later models get a low
  /// thinking level and extra room.
  static Map<String, dynamic>? _thinking(String model) {
    if (model.startsWith('gemini-2.5-flash')) return {'thinkingBudget': 0};
    if (model.startsWith('gemini-2.')) return null;
    return {'thinkingLevel': 'low'};
  }

  /// A model that cannot answer now: closed to this key (404), overloaded (500, 503, 504) or
  /// too slow. The next model is tried.
  static bool _tryNext(LLMError e) =>
      e.kind == LLMErrorKind.network || (e.kind == LLMErrorKind.server && const {404, 500, 503, 504}.contains(e.status));

  void _rest(String model, LLMError e) {
    final d = e.status == 404 ? const Duration(days: 1) : const Duration(minutes: 5);
    (_resting[apiKey] ??= {})[model] = now().add(d);
  }

  bool _isResting(String model) {
    final until = _resting[apiKey]?[model];
    return until != null && now().isBefore(until);
  }

  @override
  Future<void> verifyKey() async {
    _candidates.remove(apiKey);
    _working.remove(apiKey);
    _resting.remove(apiKey);
    await _models();
  }

  @override
  Future<String> complete({required String system, required String user, required int maxTokens}) async {
    if (apiKey.isEmpty) throw LLMError.missingAPIKey;
    final models = await _models();
    final working = _working[apiKey];
    final all = [?working, ...models.where((m) => m != working)];
    LLMError? last;
    // When every model is busy, wait a moment and go round once more before giving up.
    for (var round = 0; round < 2; round++) {
      if (round > 0) {
        if (last == null || last.status == 404) break;
        await Future<void>.delayed(retryDelay);
      }
      // Resting models go last instead of being dropped, so a key with only busy models still tries.
      final order = [...all.where((m) => !_isResting(m)), ...all.where(_isResting)];
      for (final model in order) {
        try {
          final text = await _ask(model, system, user, maxTokens);
          if (_fixedModel == null) _working[apiKey] = model;
          return text;
        } on LLMError catch (e) {
          if (!_tryNext(e)) rethrow;
          // Report the most telling failure: a busy model (503) over one that is closed (404).
          if (last == null || last.status == 404) last = e;
          if (_fixedModel == null) _rest(model, e);
          if (_working[apiKey] == model) _working.remove(apiKey);
        }
      }
    }
    throw last ?? const LLMError(LLMErrorKind.server);
  }

  Future<String> _ask(String model, String system, String user, int maxTokens) async {
    var thinking = _thinking(model);
    for (var attempt = 0;; attempt++) {
      final http.Response r;
      try {
        r = await client
            .post(Uri.parse('$_api/models/$model:generateContent'),
                headers: _headers,
                body: jsonEncode({
                  'systemInstruction': {
                    'parts': [
                      {'text': system},
                    ],
                  },
                  'contents': [
                    {
                      'role': 'user',
                      'parts': [
                        {'text': user},
                      ],
                    },
                  ],
                  'generationConfig': {
                    // Room for reasoning unless thinking is switched off.
                    'maxOutputTokens': thinking != null && thinking['thinkingBudget'] == 0 ? maxTokens : maxTokens + 4096,
                    'responseMimeType': 'application/json',
                    'thinkingConfig': ?thinking,
                  },
                }))
            // A busy model can hang instead of answering 503; give up and try the next one.
            .timeout(const Duration(seconds: 40));
      } catch (_) {
        throw LLMError.network;
      }
      try {
        _check(r);
      } on LLMError catch (e) {
        if (e.status == 400 && thinking != null && attempt == 0) {
          // A model that does not take this thinking setting: ask again without it.
          thinking = null;
          continue;
        }
        rethrow;
      }
      try {
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        final candidates = j['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) {
          if (j['promptFeedback']?['blockReason'] != null) throw LLMError.refused;
          throw const LLMError(LLMErrorKind.malformedOutput, detail: 'no candidates');
        }
        final c = candidates.first as Map;
        if (c['finishReason'] == 'SAFETY' || c['finishReason'] == 'PROHIBITED_CONTENT') throw LLMError.refused;
        final parts = (c['content']?['parts'] as List?) ?? const [];
        // Thought summaries (thought: true) are not part of the answer.
        final text = parts.where((p) => p['thought'] != true).map((p) => p['text']).whereType<String>().join();
        if (text.isEmpty) throw LLMError(LLMErrorKind.malformedOutput, detail: 'empty (${c['finishReason']})');
        return text;
      } on LLMError {
        rethrow;
      } catch (_) {
        throw const LLMError(LLMErrorKind.malformedOutput, detail: 'response');
      }
    }
  }
}

/// Any OpenAI-compatible `/chat/completions` gateway (Baze, OpenRouter, OpenAI, …).
/// URL, key and model are entered by the user; nothing is pre-filled.
class GatewayEngine extends CloudChatEngine {
  final String baseURL;

  GatewayEngine(this.baseURL, String apiKey, String model, {http.Client? client}) : super(apiKey, model, client);

  @override
  String get id => 'gateway:$model';
  @override
  EngineKind get kind => EngineKind.gateway;
  @override
  bool get isAvailable => baseURL.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  String get _base => baseURL.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  Future<String> complete({required String system, required String user, required int maxTokens}) async {
    if (!isAvailable) throw LLMError.missingAPIKey;
    final r = await post(Uri.parse('$_base/chat/completions'), {
      'authorization': 'Bearer $apiKey',
      'content-type': 'application/json',
    }, {
      'model': model,
      'max_tokens': maxTokens,
      'temperature': 0,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
    });
    ClaudeEngine.check(r.statusCode, r.body);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      return '${(j['choices'] as List).first['message']['content'] ?? ''}';
    } catch (_) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'response');
    }
  }

  @override
  Stream<String> completeStream({required String system, required String user, required int maxTokens}) {
    if (!isAvailable) throw LLMError.missingAPIKey;
    return postStream(Uri.parse('$_base/chat/completions'), {
      'authorization': 'Bearer $apiKey',
      'content-type': 'application/json',
    }, {
      'model': model,
      'max_tokens': maxTokens,
      'temperature': 0,
      'stream': true,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
    }, delta: (e) {
      final choices = e['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      return ((choices.first as Map)['delta'] as Map?)?['content'] as String?;
    }, whole: (body) => '${((jsonDecode(body) as Map)['choices'] as List).first['message']['content'] ?? ''}');
  }

  /// Chat models listed by the gateway's `/models` endpoint.
  static Future<List<String>> listModels(String baseURL, String apiKey, {http.Client? client}) async {
    final c = client ?? http.Client();
    http.Response r;
    try {
      r = await c
          .get(Uri.parse('${baseURL.trim().replaceAll(RegExp(r'/+$'), '')}/models'), headers: {'authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw LLMError.network;
    }
    ClaudeEngine.check(r.statusCode, r.body);
    final data = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['data'] as List;
    return [
      for (final m in data.cast<Map>())
        if ((m['type'] ?? 'llm') == 'llm' &&
            (m['endpoints'] == null || (m['endpoints'] as List).any((e) => '$e'.contains('chat/completions'))))
          '${m['id']}',
    ];
  }
}

/// The self-hosted Vynilo translation server (`POST /v1/translate`, API key `vyk_…`).
/// The server applies its own prompt, so lyrics go stanza by stanza as plain text and are
/// matched back line by line; a stanza whose line count changes is redone one line at a time.
class VyniloServerEngine implements TranslationEngine {
  final String baseURL;
  final String apiKey;
  final String? model;
  final http.Client client;

  VyniloServerEngine(this.baseURL, this.apiKey, {this.model, http.Client? client}) : client = client ?? http.Client();

  static const defaultURL = 'https://yuribinserver.tailf72010.ts.net:8448';

  String get _base => baseURL.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  String get id => 'vynilo:${model ?? 'default'}';
  @override
  bool get isAvailable => baseURL.isNotEmpty && apiKey.isNotEmpty;
  @override
  EngineKind get kind => EngineKind.vynilo;

  Future<String> translate(String text, Language target) async {
    if (!isAvailable) throw LLMError.missingAPIKey;
    http.Response r;
    try {
      r = await client
          .post(Uri.parse('$_base/v1/translate'),
              headers: {'authorization': 'Bearer $apiKey', 'content-type': 'application/json'},
              body: jsonEncode({'text': text, 'target': target.code, if (model != null && model!.isNotEmpty) 'model': model}))
          .timeout(const Duration(seconds: 180));
    } catch (_) {
      throw LLMError.network;
    }
    ClaudeEngine.check(r.statusCode, r.body);
    try {
      return '${(jsonDecode(utf8.decode(r.bodyBytes)) as Map)['translation']}'.trim();
    } catch (_) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'response');
    }
  }

  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    final cache = <String, String>{};
    for (final stanza in stanzas(lines.where((l) => l.text.isNotEmpty).toList())) {
      final pending = stanza.where((l) => !LanguageGuess.isLikely(l.text, target.code)).toList();
      final missing = pending.map((l) => l.text).where((t) => !cache.containsKey(t)).toSet().toList();
      if (missing.isNotEmpty) {
        final out = (await withBackoff(() => translate(missing.join('\n'), target)))
            .split('\n')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();
        if (out.length == missing.length) {
          for (var i = 0; i < out.length; i++) {
            cache[missing[i]] = out[i];
          }
        } else {
          for (final t in missing) {
            try {
              cache[t] = (await translate(t, target)).split('\n').first.trim();
            } catch (_) {}
          }
        }
      }
      for (final l in stanza) {
        if (!pending.contains(l)) {
          yield Copied(l.index);
        } else if (cache[l.text] case final t? when t.isNotEmpty && !OutputValidator.isDegenerate(t)) {
          yield Translated(l.index, t);
        } else {
          yield Failed(l.index, 'missing');
        }
      }
    }
  }

  /// Splits lyrics into stanzas: consecutive lines, at most 8, broken at gaps in the line index.
  static List<List<LyricLine>> stanzas(List<LyricLine> lines, {int maxLines = 8}) {
    final out = <List<LyricLine>>[];
    var cur = <LyricLine>[];
    for (final l in lines) {
      if (cur.isNotEmpty && (l.index != cur.last.index + 1 || cur.length == maxLines)) {
        out.add(cur);
        cur = [];
      }
      cur.add(l);
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  @override
  Future<Explanation> explain(LyricLine line, List<LyricLine> context, Language target) async => throw const LLMError(
      LLMErrorKind.unavailable,
      detail: 'Vynilo 서버는 번역 전용이에요. 해설은 온디바이스, 게이트웨이, Claude, Gemini 엔진에서 볼 수 있어요.');

  /// `GET /v1/config` with the key: checks the key and lists the server's models.
  static Future<List<String>> listModels(String baseURL, String apiKey, {http.Client? client}) async {
    final c = client ?? http.Client();
    http.Response r;
    try {
      r = await c.get(Uri.parse('${baseURL.trim().replaceAll(RegExp(r'/+$'), '')}/v1/config'),
          headers: {'authorization': 'Bearer $apiKey'}).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw LLMError.network;
    }
    ClaudeEngine.check(r.statusCode, r.body);
    return [for (final m in ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['models'] as List)) '$m'];
  }
}

// ─────────────────────────────── On-device llama.cpp ───────────────────────────────

/// Runs one Gemma prompt on the device and returns the generated text (platform channel).
typedef LocalRunner = Future<String> Function(String prompt, int maxTokens);

/// Gemma 4 E2B (QAT q4_0) through llama.cpp on the phone (SIR-8). Uses the same JSON prompts as
/// the cloud engines, but in small chunks: a 2B model on a phone CPU stays accurate and the
/// progress bar moves while the song is translated.
class LocalLlamaEngine extends CloudChatEngine {
  final LocalRunner runner;
  final String modelName;
  static const chunkLines = 8;

  LocalLlamaEngine(this.runner, {this.modelName = 'gemma-4-e2b'}) : super('local', modelName, null);

  @override
  String get id => 'llama:$modelName@q4_0';
  @override
  EngineKind get kind => EngineKind.onDevice;
  @override
  bool get isAvailable => true;

  /// Gemma 4 chat format; the system prompt goes in its own turn.
  static String gemmaPrompt(String system, String user) =>
      '<|turn>system\n$system<turn|>\n<|turn>user\n$user<turn|>\n<|turn>model\n';

  @override
  Future<String> complete({required String system, required String user, required int maxTokens}) async {
    final out = await runner(gemmaPrompt(system, user), maxTokens);
    // Drop a thinking block if the model emits one.
    final i = out.lastIndexOf('<channel|>');
    return i >= 0 ? out.substring(i + '<channel|>'.length) : out;
  }

  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    final todo = <LyricLine>[];
    for (final l in lines.where((l) => l.text.isNotEmpty)) {
      if (LanguageGuess.isLikely(l.text, target.code)) {
        yield Copied(l.index);
      } else {
        todo.add(l);
      }
    }
    for (var i = 0; i < todo.length; i += chunkLines) {
      yield* super.translateSong(todo.sublist(i, min(i + chunkLines, todo.length)), target);
    }
  }
}

// ─────────────────────────────── Translation job ───────────────────────────────

enum Stage { fetchLyrics, translate, save }

/// Progress of a whole-song pre-translation (FG-04).
class TranslationProgress {
  final int done;
  final int total;
  final Stage stage;

  /// Estimated seconds remaining, null until the first line completes.
  final double? eta;
  final String? firstLinePreview;

  const TranslationProgress({required this.done, required this.total, required this.stage, this.eta, this.firstLinePreview});

  double get fraction => total == 0 ? 1 : done / total;
}

class CancelToken {
  bool isCancelled = false;
  void cancel() => isCancelled = true;
}

class CancelledException implements Exception {
  const CancelledException();
}

/// Runs a full-song pre-translation (RQ-7). Lines that already have a successful translation
/// for this target are skipped, so a restarted job only processes what is left.
class TranslationJob {
  final String songID;
  final List<LyricLine> lines;
  final Language target;
  final TranslationEngine engine;

  const TranslationJob({required this.songID, required this.lines, required this.target, required this.engine});

  Future<void> run({
    required Set<int> alreadyDone,
    required void Function(LineResult) commit,
    required void Function(TranslationProgress) progress,
    required CancelToken token,
  }) async {
    final pending = lines.where((l) => !alreadyDone.contains(l.index)).toList();
    final total = lines.length;
    var done = total - pending.length;
    String? firstPreview;
    final started = DateTime.now();

    progress(TranslationProgress(done: done, total: total, stage: Stage.translate));
    if (pending.isEmpty) {
      progress(TranslationProgress(done: total, total: total, stage: Stage.save, eta: 0));
      return;
    }

    // A repeated line (a chorus) is translated once: only the first line of each identical text
    // goes to the engine, and its result is copied to the repeats.
    final groups = <String, List<LyricLine>>{};
    for (final l in pending) {
      groups.putIfAbsent(l.text.trim(), () => []).add(l);
    }
    final firsts = [for (final g in groups.values) g.first];
    final repeatsOf = {for (final g in groups.values) g.first.index: g};

    final seen = <int>{};
    await for (final result in engine.translateSong(firsts, target)) {
      if (token.isCancelled) break;
      final group = repeatsOf[result.index];
      if (group == null || !seen.add(result.index)) continue;
      for (final l in group) {
        commit(LineResults.reindex(result, l.index));
      }
      done += group.length;
      if (firstPreview == null && result is Translated) firstPreview = result.text;
      final processed = seen.length;
      final perLine = DateTime.now().difference(started).inMilliseconds / 1000 / processed;
      final eta = perLine * (firsts.length - processed);
      progress(TranslationProgress(done: done, total: total, stage: Stage.translate, eta: eta, firstLinePreview: firstPreview));
    }

    // A cancelled job (app backgrounded, ONRQ-9) resumes later; it must not mark lines failed.
    if (token.isCancelled) throw const CancelledException();

    // Every line must be accounted for (LOS-2): anything the engine skipped is marked failed.
    for (final first in firsts) {
      if (seen.contains(first.index)) continue;
      for (final l in repeatsOf[first.index]!) {
        commit(Failed(l.index, 'missing'));
      }
    }
    progress(TranslationProgress(done: total, total: total, stage: Stage.save, eta: 0, firstLinePreview: firstPreview));
  }
}
