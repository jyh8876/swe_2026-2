import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/core/llm.dart';

void main() {
  http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);
  Map models(List<String> names) => {
        'models': [
          for (final n in names)
            {
              'name': 'models/$n',
              'supportedGenerationMethods': ['generateContent'],
            },
        ],
      };
  Map answer(String text, [String finish = 'STOP']) => {
        'candidates': [
          {
            'finishReason': finish,
            'content': {
              'parts': [
                {'text': text},
              ],
            },
          },
        ],
      };

  test('picks the newest stable Flash, before Flash-Lite, previews and special models', () {
    expect(
        GeminiEngine.pickModel(['gemini-2.5-flash', 'gemini-3.5-flash-lite', 'gemini-3.5-flash', 'gemini-3.8-flash-preview-09-2026', 'gemini-2.5-flash-image', 'gemini-2.5-pro']),
        'gemini-3.5-flash');
    expect(GeminiEngine.rankModels(['gemini-2.5-flash-lite', 'gemini-3.5-flash-lite', 'gemini-3.8-flash', 'gemini-2.5-flash']),
        ['gemini-3.8-flash', 'gemini-2.5-flash', 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite']);
    expect(GeminiEngine.pickModel(['gemini-flash-latest', 'gemini-2.5-pro']), 'gemini-flash-latest');
    expect(GeminiEngine.pickModel(['gemini-2.5-pro']), isNull);
  });

  test('a key check reads the model list (no generation) and a wrong key is reported as such', () async {
    final seen = <String>[];
    final ok = GeminiEngine('key-ok', client: MockClient((r) async {
      seen.add('${r.method} ${r.url.path}');
      expect(r.headers['x-goog-api-key'], 'key-ok');
      return json(models(['gemini-2.5-flash', 'gemini-3.5-flash']));
    }));
    await ok.verifyKey();
    expect(seen, ['GET /v1beta/models']);
    expect(ok.currentModel, 'gemini-3.5-flash');

    final bad = GeminiEngine('key-bad', client: MockClient((r) async => json({
          'error': {
            'code': 400,
            'status': 'INVALID_ARGUMENT',
            'details': [
              {'reason': 'API_KEY_INVALID'},
            ],
          },
        }, 400)));
    await expectLater(bad.verifyKey(), throwsA(predicate((e) => e is LLMError && e.kind == LLMErrorKind.invalidKey)));
  });

  test('2.5 Flash gets thinking switched off so the JSON is not cut short', () async {
    Map? sent;
    final e = GeminiEngine('k25', client: MockClient((r) async {
      if (r.method == 'GET') return json(models(['gemini-2.5-flash']));
      sent = jsonDecode(r.body) as Map;
      return json(answer('{"ok":true}'));
    }));
    expect(await e.complete(system: 's', user: 'u', maxTokens: 100), '{"ok":true}');
    expect(sent!['generationConfig']['thinkingConfig'], {'thinkingBudget': 0});
    expect(sent!['generationConfig']['maxOutputTokens'], 100);
  });

  test('a newer model that rejects the thinking setting is asked again without it, with room', () async {
    final bodies = <Map>[];
    final e = GeminiEngine('k3', client: MockClient((r) async {
      if (r.method == 'GET') return json(models(['gemini-3.5-flash']));
      final b = jsonDecode(r.body) as Map;
      bodies.add(b);
      if (b['generationConfig']['thinkingConfig'] != null) {
        return json({
          'error': {'code': 400, 'message': 'Unknown name "thinkingLevel"'},
        }, 400);
      }
      return json(answer('{"lines":[]}'));
    }));
    expect(await e.complete(system: 's', user: 'u', maxTokens: 100), '{"lines":[]}');
    expect(bodies.length, 2);
    expect(bodies.last['generationConfig']['maxOutputTokens'], 4196);
  });

  test('closed (404) and overloaded (503) models are skipped; the one that answers is kept', () async {
    final asked = <String>[];
    final e = GeminiEngine('k404', client: MockClient((r) async {
      if (r.method == 'GET') return json(models(['gemini-2.5-flash', 'gemini-3.8-flash', 'gemini-3.5-flash-lite']));
      final model = r.url.pathSegments.last.split(':').first;
      asked.add(model);
      if (model == 'gemini-3.8-flash') return json({'error': {'code': 503, 'status': 'UNAVAILABLE'}}, 503);
      if (model == 'gemini-2.5-flash') return json({'error': {'code': 404, 'message': 'no longer available to new users'}}, 404);
      return json(answer('{"x":1}'));
    }));
    expect(await e.complete(system: 's', user: 'u', maxTokens: 50), '{"x":1}');
    expect(asked, ['gemini-3.8-flash', 'gemini-2.5-flash', 'gemini-3.5-flash-lite']);
    expect(e.currentModel, 'gemini-3.5-flash-lite');
    asked.clear();
    await e.complete(system: 's', user: 'u', maxTokens: 50);
    expect(asked, ['gemini-3.5-flash-lite']);
  });

  test('a cut-off answer with no text is an error, not an empty success', () async {
    final e = GeminiEngine('kmax', model: 'gemini-2.5-flash', client: MockClient((r) async => json({
          'candidates': [
            {'finishReason': 'MAX_TOKENS', 'content': {'role': 'model'}},
          ],
        })));
    await expectLater(e.complete(system: 's', user: 'u', maxTokens: 5), throwsA(predicate((x) => x is LLMError && x.kind == LLMErrorKind.malformedOutput)));
  });
}
