import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('swipe right goes back ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      SharedPreferences.setMockInitialValues({});
      final m = AppModel.test(
        collection: CollectionSnapshot(),
        settings: AppSettings()..hasOnboarded = true,
        prefs: await SharedPreferences.getInstance(),
        baseDir: Directory.systemTemp.createTempSync(),
      );
      await tester.pumpWidget(LyricsTranslatorApp(model: m));
      await tester.pumpAndSettle();
      m.push(SearchRoute());
      await tester.pumpAndSettle();
      expect(m.libraryPath.length, 1);
      await tester.fling(find.byType(Scaffold).first, const Offset(300, 0), 1000, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(m.libraryPath.length, 1, reason: 'a swipe from the middle must not go back');
      await tester.timedDragFrom(const Offset(6, 300), const Offset(300, 0), const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(m.libraryPath, isEmpty, reason: 'edge swipe');
      m.selectTab(AppTab.quiz);
      await tester.pumpAndSettle();
      await tester.timedDragFrom(const Offset(6, 300), const Offset(300, 0), const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(m.selectedTab, AppTab.library, reason: 'edge swipe on another tab returns Home');
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
