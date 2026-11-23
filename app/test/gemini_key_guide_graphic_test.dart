import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/ui/gemini_key_guide_graphic.dart';

// 00-2 온보딩 · 키 발급 안내 그래픽: 단계별 장면이 라이트·다크 모두 오류 없이 그려지는지.
void main() {
  Widget host(double t, Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: SizedBox(width: 375, child: ApiKeyGuideGraphic(playing: false, seekTo: t)),
        ),
      );

  // (시점, 그 시점에 보여야 하는 글자)
  const scenes = [
    (0.5, 'Get started'), // 1단계 · AI Studio 첫 화면
    (2.5, '계정을 선택하세요.'), // 1단계 · 구글 계정 선택
    (5.0, 'API 키 복사'), // 2단계 · 복사 버튼 툴팁
    (9.0, 'API 키 연결하기'), // 3단계 · 붙여넣기 후
  ];

  for (final brightness in Brightness.values) {
    for (final (t, text) in scenes) {
      testWidgets('${brightness.name} · ${t}s · $text', (tester) async {
        await tester.pumpWidget(host(t, brightness));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        expect(find.text(text), findsOneWidget);
      });
    }
  }

  testWidgets('keeps the 375:248 design ratio at any width', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 300, child: ApiKeyGuideGraphic(playing: false)))),
    ));
    final size = tester.getSize(find.byType(ApiKeyGuideGraphic));
    expect(size.width, 300);
    expect(size.height, closeTo(300 * 248 / 375, 0.5));
  });
}
