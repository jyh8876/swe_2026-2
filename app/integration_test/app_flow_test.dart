// End-to-end flow on a real device or emulator, using the real AppModel and storage:
//   flutter drive --driver test_driver/integration_test.dart --target integration_test/app_flow_test.dart
// Onboarding → search the bundled demo song → save → translate → player → line sheet → star
// → mini player → likes tab → my page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/main.dart' as app;
import 'package:lyrics_translator/ui/line_detail.dart';
import 'package:lyrics_translator/ui/mini_player.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;

  // The player animates forever, so pumpAndSettle never returns; pump real frames instead.
  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, Finder f, {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (f.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $f');
      await wait(tester, const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (!converted) {
      await binding.convertFlutterSurfaceToImage();
      converted = true;
    }
    await wait(tester, const Duration(milliseconds: 300));
    await binding.takeScreenshot(name);
  }

  testWidgets('demo song: add, study, save a line, browse tabs', (tester) async {
    await app.main();
    await wait(tester, const Duration(seconds: 1));

    // FG-00: skip music linking on a fresh install.
    final later = find.text('나중에 하기');
    if (later.evaluate().isNotEmpty) {
      await shot(tester, '00_onboarding');
      await tester.tap(later);
      await wait(tester, const Duration(milliseconds: 800));
    }
    await until(tester, find.text('내 컬렉션'));
    await shot(tester, '01_home');

    // FG-02: search the bundled demo song (works offline).
    await tester.tap(find.text('노래 추가').first);
    await until(tester, find.text('노래 검색'));
    await tester.enterText(find.byType(TextField), 'day off');
    await until(tester, find.text(DemoContent.songTitle));
    await shot(tester, '02_search');
    await tester.tap(find.text(DemoContent.songTitle).first);

    // FG-03 → FG-04 → FG-05.
    await until(tester, find.text('컬렉션에 추가'));
    await tester.tap(find.text('저장'));
    await until(tester, find.text('컬렉션에 추가됐어요!'), timeout: const Duration(seconds: 40));
    await wait(tester, const Duration(milliseconds: 1500)); // LP drop animation
    await shot(tester, '03_saved');
    await tester.tap(find.text('바로 공부하기'));

    // FG-06: dark player; play the demo and wait for the third line.
    const line = 'But you said take it easy, let it go';
    await until(tester, find.text(line));
    await tester.tap(find.bySemanticsLabel('재생'));
    await wait(tester, const Duration(seconds: 15));
    expect(find.bySemanticsLabel('일시정지'), findsOneWidget);
    await shot(tester, '04_player');

    // FG-07: explanation sheet, then save the line.
    await tester.tap(find.text(line).first);
    await until(tester, find.byType(LineDetailView));
    await until(tester, find.text('문장 구조'), timeout: const Duration(seconds: 30));
    await shot(tester, '05_line_sheet');
    await tester.tap(find.byTooltip('문장 담기'));
    await wait(tester, const Duration(milliseconds: 400));
    expect(find.byTooltip('담은 문장에서 빼기'), findsOneWidget);
    Navigator.of(tester.element(find.byType(LineDetailView))).pop();
    await wait(tester, const Duration(milliseconds: 600));

    // Back home: the mini player keeps playing.
    await tester.tap(find.byTooltip('홈으로 돌아가기'));
    await until(tester, find.byType(MiniPlayer));
    await wait(tester, const Duration(milliseconds: 1500)); // page pop transition
    expect(find.text('내 컬렉션'), findsOneWidget);
    await shot(tester, '06_home_mini_player');

    // Likes tab lists the saved line.
    await tester.tap(find.bySemanticsLabel('좋아요'));
    await until(tester, find.text('문장 저장함'));
    expect(find.text(line), findsWidgets);
    await shot(tester, '07_likes');

    // My page.
    await tester.tap(find.bySemanticsLabel('마이페이지'));
    await until(tester, find.text('마이페이지'));
    await shot(tester, '08_my');

    await tester.tap(find.bySemanticsLabel('홈'));
    await wait(tester, const Duration(milliseconds: 500));
    expect(find.text('1곡'), findsOneWidget);
  });
}
