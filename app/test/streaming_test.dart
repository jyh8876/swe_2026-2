import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/models.dart';

// Original sample lines written for these tests.
List<LyricLine> _lines(int n) => [for (var i = 0; i < n; i++) LyricLine(songID: 's', index: i, text: 'line $i')];

void main() {
  test('parser hands out each entry as soon as it is complete, across any chunking', () {
    const body = '```json\n{"lines":[{"i":0,"t":"첫 줄 {괄호}"},{"i":1,"copy":true},{"i":2,"t":"따옴표 \\"인용\\" 끝"},{"i":9,"t":"없는 줄"},{"i":3,"t":""}]}\n```';
    for (final size in [1, 3, 7, 50]) {
      final p = StreamingLineParser({0, 1, 2, 3});
      final got = <LineResult>[];
      final when = <int>[];
      for (var k = 0; k < body.length; k += size) {
        final out = p.feed(body.substring(k, (k + size).clamp(0, body.length)));
        got.addAll(out);
        when.addAll(out.map((_) => k));
      }
      expect(got.map((r) => r.index), [0, 1, 2], reason: 'chunk $size'); // 9 is unknown, 3 is empty → left for retry
      expect((got[0] as Translated).text, '첫 줄 {괄호}');
      expect(got[1], isA<Copied>());
      expect((got[2] as Translated).text, '따옴표 "인용" 끝');
      expect(when.first, lessThan(body.indexOf('{"i":1')), reason: 'line 0 arrives before line 1 is written');
    }
  });

  test('gateway engine streams SSE: lines are yielded before the response ends', () async {
    final events = StreamController<List<int>>();
    final client = MockClient.streaming((req, body) async {
      expect(jsonDecode(await body.bytesToString())['stream'], isTrue);
      return http.StreamedResponse(events.stream, 200, headers: {'content-type': 'text/event-stream'});
    });
    final engine = GatewayEngine('https://gw.example/v1', 'k', 'm', client: client);
    String sse(String t) => 'data: ${jsonEncode({'choices': [{'delta': {'content': t}}]})}\n\n';

    final seen = <int>[];
    final done = engine.translateSong(_lines(3), Language.korean).forEach((r) => seen.add(r.index));
    events.add(utf8.encode(sse('{"lines":[{"i":0,"t":"하나"}')));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, [0], reason: 'the first line is out while the stream is still open');
    events.add(utf8.encode(sse(',{"i":1,"t":"둘"},{"i":2,"t":"셋"}]}')));
    events.add(utf8.encode('data: [DONE]\n\n'));
    await events.close();
    await done;
    expect(seen, [0, 1, 2]);
  });

  test('a gateway that ignores stream:true still works (plain JSON body)', () async {
    final client = MockClient((req) async => http.Response(
        jsonEncode({'choices': [{'message': {'content': '{"lines":[{"i":0,"t":"하나"},{"i":1,"t":"둘"}]}'}}]}), 200,
        headers: {'content-type': 'application/json'}));
    final engine = GatewayEngine('https://gw.example/v1', 'k', 'm', client: client);
    final out = await engine.translateSong(_lines(2), Language.korean).toList();
    expect(out.map((r) => (r as Translated).text), ['하나', '둘']);
  });
}
