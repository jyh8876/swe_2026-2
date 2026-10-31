import 'dart:convert';

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
    final groups = VyniloServerEngine.stanzas(lines);
    expect(groups.map((g) => g.map((l) => l.index).toList()).toList(), [
      [0, 1, 2],
      [4, 5, 6, 7, 8, 9, 10],
    ]);
  });

  test('Vynilo server: stanza translated in one call, lines matched back', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      expect(req.url.path, '/v1/translate');
      expect(req.headers['authorization'], 'Bearer vyk_test');
      final text = (jsonDecode(req.body) as Map)['text'] as String;
      final out = text.split('\n').map((l) => '번역:$l').join('\n');
      return http.Response(jsonEncode({'translation': out}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final engine = VyniloServerEngine('https://srv', 'vyk_test', client: client);
    final results = await engine.translateSong(sampleLines(['The kettle sings at dawn', 'We count the passing trains']), ko).toList();
    expect(calls, 1);
    expect(results.whereType<Translated>().map((r) => r.text), ['번역:The kettle sings at dawn', '번역:We count the passing trains']);
  });

  test('Vynilo server: line-count mismatch falls back to one line at a time', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      final text = (jsonDecode(req.body) as Map)['text'] as String;
      final out = text.contains('\n') ? 'merged into one line' : '한 줄:$text';
      return http.Response(jsonEncode({'translation': out}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final engine = VyniloServerEngine('https://srv', 'k', client: client);
    final results = await engine.translateSong(sampleLines(['Paper boats on the river', 'Lanterns over the bridge']), ko).toList();
    expect(calls, 3);
    expect(results.whereType<Translated>().length, 2);
  });

  test('Vynilo server: 401 maps to invalid key, explain is unavailable', () async {
    final engine = VyniloServerEngine('https://srv', 'bad', client: MockClient((_) async => http.Response('{}', 401)));
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

  test('On-device llama: Gemma prompt, chunks of 8, copies lines already in the target', () async {
    final prompts = <String>[];
    Future<String> runner(String prompt, int maxTokens) async {
      prompts.add(prompt);
      final user = prompt.split('<|turn>user\n')[1].split('<turn|>')[0];
      final entries = [
        for (final row in user.split('\n'))
          {'i': int.parse(row.split('\t')[0]), 't': '번역 ${row.split('\t')[0]}'}
      ];
      return jsonEncode({'lines': entries});
    }

    final engine = LocalLlamaEngine(runner);
    final lines = sampleLines([...List.generate(10, (i) => 'Window light number $i'), '이미 한국어 문장이에요']);
    final results = await engine.translateSong(lines, ko).toList();
    expect(prompts.length, 2);
    expect(prompts.first, startsWith('<|turn>system\n'));
    expect(prompts.first, endsWith('<|turn>model\n'));
    expect(results.whereType<Translated>().length, 10);
    expect(results.whereType<Copied>().single.index, 10);
  });
}
