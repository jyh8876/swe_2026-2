import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppModel> model({bool onboarded = false, CollectionSnapshot? snap}) async {
    SharedPreferences.setMockInitialValues({});
    return AppModel.test(
        collection: snap ?? CollectionSnapshot(),
        settings: AppSettings()..hasOnboarded = onboarded,
        prefs: await SharedPreferences.getInstance(),
        baseDir: Directory.systemTemp.createTempSync());
  }

  testWidgets('first run walks start → AI intro → later, then shows the tabs', (tester) async {
    final m = await model();
    await tester.pumpWidget(LyricsTranslatorApp(model: m));
    expect(find.text('SPIN IT. READ IT. KEEP IT.'), findsOneWidget);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    expect(find.text('가사 속 표현을\nAI가 알려줘요'), findsOneWidget);
    await tester.tap(find.text('API 키 연결하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이미 키가 있어요'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini API 키'), findsOneWidget);
    // Back to the intro and skip the key for now.
    await tester.tap(find.byTooltip('뒤로').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('뒤로').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('나중에 할게요'));
    await tester.pumpAndSettle();
    expect(m.settings.hasOnboarded, isTrue);
    expect(m.settings.engine, EngineKind.onDevice);
    expect(find.byType(MainTabView), findsOneWidget);
  });

  test('song edit keeps unchanged lines and their saved state, retranslates the rest', () async {
    final snap = CollectionSnapshot();
    final song = Song(title: 'T', artist: 'A', lyricsType: LyricsType.plain, sourceProvider: 'manual', status: SongStatus.done);
    snap.addSong(song, LRCParser.parse('one\ntwo\nthree'));
    for (final l in snap.linesFor(song.id)) {
      snap.commit(Translated(l.index, 'k${l.index}'), songID: song.id, target: 'ko', engineID: 'demo');
    }
    snap.toggleSaved(song.id, 0);
    snap.toggleSaved(song.id, 1);
    final m = await model(onboarded: true, snap: snap);
    m.editSong(song.id, title: 'T2', artist: 'A', lyrics: 'one\nTWO\nthree');
    expect(m.collection.song(song.id)!.title, 'T2');
    expect(m.collection.linesFor(song.id).map((l) => l.text), ['one', 'TWO', 'three']);
    expect(m.collection.translationText(song.id, 0, 'ko'), 'k0');
    expect(m.collection.translationText(song.id, 1, 'ko'), isNull);
    expect(m.collection.isSaved(song.id, 0), isTrue);
    expect(m.collection.isSaved(song.id, 1), isFalse);
  });

  test('LRC lines are written back with their time tags', () {
    final doc = LRCParser.parse('[00:05.50]a\n[01:02.25]b');
    expect(LRCParser.format(doc.lyricLines('s')), '[00:05.50]a\n[01:02.25]b');
  });
}
