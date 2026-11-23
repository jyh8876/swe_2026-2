import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/models.dart';

// Original sample lines written for these tests.
List<LyricLine> sampleLines(List<String> texts) =>
    [for (var i = 0; i < texts.length; i++) LyricLine(songID: 's', index: i, text: texts[i])];

void main() {
  final ko = Language.named('ko');

  test('stanzas split at index gaps and at 8 lines', () {
    final lines = sampleLines(List.generate(11, (i) => 'line $i'))..removeAt(3);
    final groups = VinyloServerEngine.stanzas(lines);
    expect(groups.map((g) => g.map((l) => l.index).toList()).toList(), [
      [0, 1, 2],
      [4, 5, 6, 7, 8, 9, 10],
    ]);
  });

  test('Vinylo server: stanza translated in one call, lines matched back', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      expect(req.url.path, '/v1/translate');
      expect(req.headers['authorization'], 'Bearer vyk_test');
      final text = (jsonDecode(req.body) as Map)['text'] as String;
      final out = text.split('\n').map((l) => '번역:$l').join('\n');
      return http.Response(jsonEncode({'translation': out}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final engine = VinyloServerEngine('https://srv', 'vyk_test', client: client);
    final results = await engine.translateSong(sampleLines(['The kettle sings at dawn', 'We count the passing trains']), ko).toList();
    expect(calls, 1);
    expect(results.whereType<Translated>().map((r) => r.text), ['번역:The kettle sings at dawn', '번역:We count the passing trains']);
  });

  test('Vinylo server: line-count mismatch falls back to one line at a time', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      final text = (jsonDecode(req.body) as Map)['text'] as String;
      final out = text.contains('\n') ? 'merged into one line' : '한 줄:$text';
      return http.Response(jsonEncode({'translation': out}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final engine = VinyloServerEngine('https://srv', 'k', client: client);
    final results = await engine.translateSong(sampleLines(['Paper boats on the river', 'Lanterns over the bridge']), ko).toList();
    expect(calls, 3);
    expect(results.whereType<Translated>().length, 2);
  });

  test('Vinylo server: 401 maps to invalid key, explain is unavailable', () async {
    final engine = VinyloServerEngine('https://srv', 'bad', client: MockClient((_) async => http.Response('{}', 401)));
    expect(engine.translate('hello', ko), throwsA(isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.invalidKey)));
    final line = sampleLines(['hello']).first;
    expect(engine.explain(line, [line], ko), throwsA(isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.unavailable)));
  });

  test('Gateway: OpenAI-compatible request and JSON line results', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://gw.example/v1/chat/completions');
      final body = jsonDecode(req.body) as Map;
      expect(body['model'], 'claude-haiku-5-5');
      expect((body['messages'] as List).first['role'], 'system');
      final content = jsonEncode({
        'lines': [
          {'i': 0, 't': '아침이 창문을 두드려'},
          {'i': 1, 't': '우린 천천히 걸어'},
        ]
      });
      return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'content': content}}
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final engine = GatewayEngine('https://gw.example/v1/', 'key', 'claude-haiku-5-5', client: client);
    expect(engine.isAvailable, isTrue);
    final results = await engine.translateSong(sampleLines(['Morning knocks on the window', 'We walk slowly']), ko).toList();
    expect(results.whereType<Translated>().map((r) => r.text), ['아침이 창문을 두드려', '우린 천천히 걸어']);
  });

  test('Gateway: blank settings are not available', () {
    expect(GatewayEngine('', '', '').isAvailable, isFalse);
    expect(GatewayEngine('https://gw', 'k', '').isAvailable, isFalse);
  });

  test('Gateway: model list keeps chat models only', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'data': [
            {'id': 'chat-a', 'type': 'llm', 'endpoints': ['/v1/gateway/chat/completions/']},
            {'id': 'image-b', 'type': 'image'},
            {'id': 'resp-only', 'type': 'llm', 'endpoints': ['/v1/gateway/responses/']},
            {'id': 'plain'},
          ]
        }),
        200));
    expect(await GatewayEngine.listModels('https://gw/v1', 'k', client: client), ['chat-a', 'plain']);
  });

  test('On-device: the prompt is the exact text the model was trained on (p2)', () {
    // sha256 of translation_system(code) in the training code (lyrics-distill data/p2/prompts_p2.py).
    const trained = {
      'ko': '156531e1d2fc42f0f01f848549f9fdfbb9448ff881efc2d1a1b5b83d4f561571',
      'zh': '6bd05a3dd5f1046de6334f14662de9c8ed99784d52ae8007961d48f1d1a6bf87',
      'en': 'ed7e4ce6000030b2dfdef30d7b902a06699768852efe35214bcbb635069465a2',
      'ja': '8bb5f5aac5c6da53cedd3181c9b62981a5f8283a81c3196a64a73c05b1f5de32',
    };
    for (final lang in [Language.korean, Language.chinese, Language.english, Language.japanese]) {
      expect('${sha256.convert(utf8.encode(LocalLlamaEngine.translationSystem(lang)))}', trained[lang.code],
          reason: lang.code);
    }
  });

  test('On-device: one request per line, answer opened in the prompt, copies skipped', () async {
    final calls = <(String, int)>[];
    Future<String> runner(String prompt, int maxTokens, {int closeDepth = 0}) async {
      calls.add((prompt, closeDepth));
      final i = prompt.split('<|turn>user\n')[1].split('\t')[0];
      return '$i,"t":"번역 $i","r":"읽기 $i"}';
    }

    final engine = LocalLlamaEngine(runner);
    final lines = sampleLines(['Window light', '이미 한국어 문장이에요', 'Second window']);
    final results = await engine.translateSong(lines, ko).toList();
    expect(calls.length, 2);
    for (final (prompt, depth) in calls) {
      expect(prompt, endsWith('<|turn>model\n{"lines":[{"i":'));
      expect(depth, 1);
    }
    // Everything up to the user turn is shared, so llama.cpp reuses it from the KV cache.
    final head = calls[0].$1.substring(0, calls[0].$1.indexOf('<|turn>user'));
    expect(calls[1].$1, startsWith(head));
    expect(calls[1].$1, contains('<|turn>user\n2\tSecond window<turn|>'));
    expect(results[0], isA<Translated>().having((t) => t.text, 'text', '번역 0').having((t) => t.reading, 'reading', '읽기 0'));
    expect(results[1], isA<Copied>());
    expect((results[2] as Translated).text, '번역 2');
  });

  test('On-device: a broken answer is asked again without the opened answer', () async {
    final prompts = <String>[];
    Future<String> runner(String prompt, int maxTokens, {int closeDepth = 0}) async {
      prompts.add(prompt);
      return prompts.length == 1 ? '0,"t":"' : '{"lines":[{"i":0,"t":"다시 한 번"}]}';
    }

    final results = await LocalLlamaEngine(runner).translateSong(sampleLines(['One more time']), ko).toList();
    expect(prompts.length, 2);
    expect(prompts[1], endsWith('<|turn>model\n'));
    expect((results.single as Translated).text, '다시 한 번');
  });
}
