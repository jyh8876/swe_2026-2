// Renders key screens to PNG for visual review (no device needed):
//   flutter test test/screens --dart-define=SHOTS=<dir>
@Tags(['screens'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/theme.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/main.dart';
import 'package:lyrics_translator/ui/line_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const out = String.fromEnvironment('SHOTS', defaultValue: 'build/screens');
const koreanFont = '/usr/share/fonts/truetype/unfonts-core/UnDotum.ttf';

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 600));
  final ro = tester.firstRenderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  final img = await tester.runAsync(() async {
    final i = await ro.toImage(pixelRatio: 2);
    return (await i.toByteData(format: ui.ImageByteFormat.png))!;
  });
  Directory(out).createSync(recursive: true);
  File('$out/$name.png').writeAsBytesSync(img!.buffer.asUint8List());
}

void main() {
  testWidgets('screens', (tester) async {
    await tester.runAsync(() async {
      final bytes = File(koreanFont).readAsBytesSync();
      final f2 = FontLoader('UnDotum')..addFont(Future.value(ByteData.sublistView(bytes)));
      await f2.load();
      final icons = File('${Platform.environment['HOME']}/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync();
      final f3 = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)));
      await f3.load();
    });
    AppTheme.fontFamilyOverride = 'UnDotum';
    tester.view.physicalSize = const Size(750, 1624);
    tester.view.devicePixelRatio = 2;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final snap = CollectionSnapshot();
    final ko = DemoEngine.sampleGlossary;
    for (final (i, title) in ['Day-Off', 'Quiet Room', 'Morning Train', 'Paper Planes'].indexed) {
      final song = Song(title: title, artist: 'Team 9', duration: 52, lyricsType: LyricsType.synced, sourceProvider: 'demo', status: SongStatus.done,
          addedAt: DateTime(2026, 10, 18 - i), conqueredAt: i == 2 ? DateTime(2026) : null);
      snap.addSong(song, LRCParser.parse(DemoContent.lrc));
      for (final l in snap.linesFor(song.id)) {
        snap.commit(Translated(l.index, ko[l.text] ?? '(한국어) ${l.text}'), songID: song.id, target: 'ko', engineID: 'demo');
      }
      if (i == 0) {
        snap.toggleSaved(song.id, 2);
        snap.toggleSaved(song.id, 6);
        snap.cacheExplanation(ExplanationRecord(songID: song.id, index: 2, targetLanguage: 'ko', engineID: 'demo', promptVersion: Prompts.version,
            explanation: Explanation(expressions: const [
              Expression(phrase: 'take it easy', meaning: '“너무 무리하지 마, 편하게 해”라는 뜻의 관용구예요.'),
              Expression(phrase: 'let it go', meaning: '“그냥 놓아줘, 신경 쓰지 마”라는 뜻이에요.'),
            ], structure: 'But + 주어 + said + 명령문 두 개를 쉼표로 이은 간접 인용이에요.', usage: '걱정하는 친구를 다독일 때 써요.', example: 'Take it easy, the deadline is next week.')));
      }
    }
    final model = AppModel.test(collection: snap, settings: AppSettings()..hasOnboarded = true, prefs: prefs, baseDir: Directory.systemTemp.createTempSync());
    await tester.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: LyricsTranslatorApp(model: model)));
    await shot(tester, '01_home_carousel');
    await tester.tap(find.bySemanticsLabel('격자로 보기'));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '02_home_grid');
    final first = snap.songsNewestFirst.first;
    model.push(PlayerRoute(first.id));
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, '03_player_study');
    model.playDemo(first);
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 14500)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, '04_player_playing');
    await tester.tap(find.text('But you said take it easy, let it go'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, '05_line_sheet');
    Navigator.of(tester.element(find.byType(LineDetailView))).pop();
    await tester.pump(const Duration(milliseconds: 500));
    model.pop();
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, '06_home_mini_player');
    model.selectTab(AppTab.phrases);
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '07_likes');
    model.selectTab(AppTab.my);
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '08_my');
    model.source?.pause();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }, skip: !File(koreanFont).existsSync()); // needs a Korean system font (fonts-unfonts-core)
}
