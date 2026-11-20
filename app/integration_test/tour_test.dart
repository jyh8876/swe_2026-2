// Screenshot tour of every main screen on a device/simulator, with seeded data.
//   flutter drive --driver test_driver/integration_test.dart --target integration_test/tour_test.dart -d <sim>
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/llm.dart';
import 'package:lyrics_translator/core/lyrics.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/main.dart';
import 'package:lyrics_translator/ui/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;

  Future<void> wait(WidgetTester t, [int ms = 600]) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    if (!converted) {
      await binding.convertFlutterSurfaceToImage();
      converted = true;
    }
    await wait(t, 500);
    await binding.takeScreenshot(name);
  }

  Future<AppModel> model(bool onboarded, {bool songs = false}) async {
    SharedPreferences.setMockInitialValues({});
    final snap = CollectionSnapshot();
    if (songs) {
      final items = [
        ('Day-Off', 'Team 9'),
        ('Quiet Room', 'Team 9'),
        ('Blinding Lights', 'The Weeknd'),
        ('Good 4 U', 'Olivia Rodrigo'),
      ];
      for (final (i, s) in items.indexed) {
        final song = Song(title: s.$1, artist: s.$2, duration: 52, lyricsType: LyricsType.synced, sourceProvider: 'manual', status: SongStatus.done);
        snap.addSong(song, LRCParser.parse(DemoContent.lrc));
        for (final l in snap.linesFor(song.id)) {
          snap.commit(Translated(l.index, '번역 ${l.index + 1}번째 줄이에요'), songID: song.id, target: 'ko', engineID: 'demo');
        }
        if (i == 0) snap.toggleSaved(song.id, 2);
      }
    }
    return AppModel.test(
        collection: snap,
        settings: AppSettings()..hasOnboarded = onboarded,
        prefs: await SharedPreferences.getInstance(),
        baseDir: Directory.systemTemp.createTempSync());
  }

  testWidgets('onboarding', (t) async {
    await t.pumpWidget(LyricsTranslatorApp(model: await model(false)));
    await shot(t, '00_start');
    await t.tap(find.text('로그인 없이 둘러보기'));
    await wait(t, 1200);
    await shot(t, '01_after_start');
  });

  testWidgets('tabs and screens', (t) async {
    final m = await model(true, songs: true);
    await t.pumpWidget(LyricsTranslatorApp(model: m));
    await wait(t, 1000);
    await shot(t, '10_home_carousel');
    final id = m.collection.songsNewestFirst.last.id;
    m.push(PlayerRoute(id));
    await wait(t, 1500);
    await shot(t, '11_player');
    m.setPath([]);
    await wait(t, 800);
    m.openAdd();
    await wait(t, 1000);
    await shot(t, '12_add');
    m.setPath([]);
    m.push(SearchRoute());
    await wait(t, 1000);
    await shot(t, '13_search');
    m.setPath([]);
    m.selectTab(AppTab.quiz);
    await wait(t, 1000);
    await shot(t, '14_quiz');
    m.selectTab(AppTab.phrases);
    await wait(t, 1000);
    await shot(t, '15_phrases');
    m.selectTab(AppTab.my);
    await wait(t, 1000);
    await shot(t, '16_my');
    for (var i = 1; i <= 4; i++) {
      await t.drag(find.descendant(of: find.byType(SettingsView), matching: find.byType(Scrollable)).first, const Offset(0, -520));
      await wait(t, 500);
      await shot(t, '17_my_scroll$i');
    }
    m.selectTab(AppTab.library);
    await wait(t, 600);
    await t.longPressAt(const Offset(195, 330));
    await wait(t, 900);
    await shot(t, '18_song_menu');
  });
}
