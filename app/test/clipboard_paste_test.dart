import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppModel> openAdd(WidgetTester t, {required bool hasText, String text = 'line one\nline two'}) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': hasText};
      if (call.method == 'Clipboard.getData') return hasText ? {'text': text} : null;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    SharedPreferences.setMockInitialValues({});
    final m = AppModel.test(
      collection: CollectionSnapshot(),
      settings: AppSettings()..hasOnboarded = true,
      prefs: await SharedPreferences.getInstance(),
      baseDir: Directory.systemTemp.createTempSync(),
    );
    await t.pumpWidget(LyricsTranslatorApp(model: m));
    await t.pumpAndSettle();
    m.openAdd();
    await t.pumpAndSettle();
    return m;
  }

  testWidgets('a paste button appears when the clipboard has text and fills the lyrics', (t) async {
    await openAdd(t, hasText: true);
    expect(find.text('클립보드에서 붙여넣기'), findsOneWidget);
    await t.tap(find.text('클립보드에서 붙여넣기'));
    await t.pumpAndSettle();
    expect(find.text('line one\nline two'), findsOneWidget);
  });

  testWidgets('no button when the clipboard is empty', (t) async {
    await openAdd(t, hasText: false);
    expect(find.text('클립보드에서 붙여넣기'), findsNothing);
  });
}
