import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/account.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppModel> model(AccountInfo? account) async {
    SharedPreferences.setMockInitialValues({});
    return AppModel.test(
      collection: CollectionSnapshot(),
      settings: AppSettings()
        ..hasOnboarded = true
        ..account = account,
      prefs: await SharedPreferences.getInstance(),
      baseDir: Directory.systemTemp.createTempSync(),
    );
  }

  Future<void> openMyPage(WidgetTester t, AppModel m) async {
    await t.pumpWidget(LyricsTranslatorApp(model: m));
    await t.pumpAndSettle();
    m.selectTab(AppTab.my);
    await t.pumpAndSettle();
  }

  testWidgets('My page shows the signed-in name and e-mail', (t) async {
    final m = await model(const AccountInfo(provider: 'google', id: '1', email: 'sample@example.com', name: '홍길동'));
    await openMyPage(t, m);
    expect(find.text('홍길동'), findsOneWidget);
    expect(find.text('sample@example.com'), findsOneWidget);
  });

  testWidgets('without a name it falls back to the e-mail, then to the provider', (t) async {
    var m = await model(const AccountInfo(provider: 'apple', id: '2', email: 'kim@example.com'));
    await openMyPage(t, m);
    expect(find.text('kim'), findsOneWidget);
    m = await model(const AccountInfo(provider: 'apple', id: '3'));
    await openMyPage(t, m);
    expect(find.text('Apple 계정'), findsWidgets);
  });

  testWidgets('signed out: no profile header', (t) async {
    await openMyPage(t, await model(null));
    expect(find.text('홍길동'), findsNothing);
  });
}
