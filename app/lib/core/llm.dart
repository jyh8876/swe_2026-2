import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'models.dart';

/// User-facing engine choice (FG-00, FG-09).
enum EngineKind {
  onDevice,
  claude,
  gemini;

  bool get requiresAPIKey => this != EngineKind.onDevice;

  /// Badge label shown on FG-04/FG-06 (SIR-3).
  String get badgeLabel => switch (this) {
        EngineKind.onDevice => 'On-device',
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
  const Translated(super.index, this.text);
}

/// Line already in the target language; copied, not translated (RQ-7).
class Copied extends LineResult {
  const Copied(super.index);
}

class Failed extends LineResult {
  final String reason;
  const Failed(super.index, this.reason);
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
        LLMErrorKind.invalidKey => 'API 키가 올바르지 않아요. 설정에서 확인해 주세요.',
        LLMErrorKind.outOfCredit => 'API 계정의 크레딧이 부족해요.',
        LLMErrorKind.rateLimited => '요청이 많아 잠시 후 다시 시도해요.',
        LLMErrorKind.server => '서버 오류가 발생했어요 ($status).',
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
  static const version = 'p1';

  static String translationSystem(Language target) => '''You translate song lyrics for language learners.
Translate each numbered line into natural, idiomatic ${target.englishName} (${target.code}).
Rules:
- Keep the meaning, tone and register of the song; prefer natural phrasing over literal word order.
- Use the surrounding lines as context for pronouns, tense and slang.
- Return exactly one entry per input index. Never merge or split lines.
- If a line is already in ${target.englishName}, return it with "copy": true and no translation.
- Do not censor the original meaning.
Respond only with JSON: {"lines":[{"i":0,"t":"..."},{"i":1,"copy":true}]}''';

  static String translationUser(List<LyricLine> lines) => lines.map((l) => '${l.index}\t${l.text}').join('\n');

  static String explanationSystem(Language target) =>
      '''You explain one line of song lyrics to a learner whose native language is ${target.englishName}.
Write every field in ${target.englishName}. Quote original expressions as they appear in the lyric.
Pick at most 3 key expressions, ranked by learning value (slang and idioms first).
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
      if (entry['copy'] == true) return Copied(line.index);
      final t = '${entry['t'] ?? ''}'.trim();
      if (t.isEmpty) return Failed(line.index, 'empty');
      if (isDegenerate(t)) return Failed(line.index, 'repetition');
      return Translated(line.index, t);
    }).toList();
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
    return switch (code) {
      'ko' => hangul / letters.length > 0.5,
      'en' => latin / letters.length > 0.9,
      _ => false,
    };
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

  @override
  Stream<LineResult> translateSong(List<LyricLine> lines, Language target) async* {
    final toTranslate = lines.where((l) => l.text.isNotEmpty).toList();
    final text = await withBackoff(() => complete(
        system: Prompts.translationSystem(target), user: Prompts.translationUser(toTranslate), maxTokens: 4096));
    final results = OutputValidator.translationResults(text, toTranslate);

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
  static const defaultModel = 'claude-haiku-4-5';
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
  static const defaultModel = 'gemini-2.5-flash';

  GeminiEngine(String apiKey, {String model = defaultModel, http.Client? client}) : super(apiKey, model, client);

  @override
  String get id => 'gemini:$model';
  @override
  EngineKind get kind => EngineKind.gemini;

  @override
  Future<String> complete({required String system, required String user, required int maxTokens}) async {
    if (apiKey.isEmpty) throw LLMError.missingAPIKey;
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
    // Header, not query string, so the key never lands in URL logs (LOS-10).
    final r = await post(url, {'x-goog-api-key': apiKey, 'content-type': 'application/json'}, {
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
      'generationConfig': {'maxOutputTokens': maxTokens, 'responseMimeType': 'application/json'},
    });
    final s = r.statusCode;
    if (s == 400 || s == 401 || s == 403) throw LLMError.invalidKey;
    if (s == 429) throw LLMError.rateLimited;
    if (s < 200 || s >= 300) throw LLMError(LLMErrorKind.server, status: s);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final c = (j['candidates'] as List).first as Map;
      if (c['finishReason'] == 'SAFETY') throw LLMError.refused;
      final parts = (c['content']?['parts'] as List?) ?? const [];
      return parts.map((p) => p['text']).whereType<String>().join();
    } on LLMError {
      rethrow;
    } catch (_) {
      throw const LLMError(LLMErrorKind.malformedOutput, detail: 'response');
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

    final seen = <int>{};
    await for (final result in engine.translateSong(pending, target)) {
      if (token.isCancelled) break;
      if (!seen.add(result.index)) continue;
      commit(result);
      done += 1;
      if (firstPreview == null && result is Translated) firstPreview = result.text;
      final processed = seen.length;
      final perLine = DateTime.now().difference(started).inMilliseconds / 1000 / processed;
      final eta = perLine * (pending.length - processed);
      progress(TranslationProgress(done: done, total: total, stage: Stage.translate, eta: eta, firstLinePreview: firstPreview));
    }

    // A cancelled job (app backgrounded, ONRQ-9) resumes later; it must not mark lines failed.
    if (token.isCancelled) throw const CancelledException();

    // Every line must be accounted for (LOS-2): anything the engine skipped is marked failed.
    for (final line in pending) {
      if (!seen.contains(line.index)) commit(Failed(line.index, 'missing'));
    }
    progress(TranslationProgress(done: total, total: total, stage: Stage.save, eta: 0, firstLinePreview: firstPreview));
  }
}
