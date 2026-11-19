import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppModel model;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    model = AppModel.test(
        collection: CollectionSnapshot(), settings: AppSettings()..hasOnboarded = true, prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
  });

  test('vinylo://open/search opens the add screen with the query as the title (no search step)', () {
    model.selectTab(AppTab.my);
    expect(model.openLink(Uri.parse('vinylo://open/search?q=Coldplay%20Yellow')), isTrue);
    expect(model.selectedTab, AppTab.library);
    expect((model.libraryPath.single as AddRoute).draft.title, 'Coldplay Yellow');
  });

  test('vinylo://open/add and /my open the add screen and My page', () {
    model.openLink(Uri.parse('vinylo://open/add'));
    expect(model.libraryPath.single, isA<AddRoute>());
    model.openLink(Uri.parse('vinylo://open/my'));
    expect(model.selectedTab, AppTab.my);
  });

  test('unknown screens go home; other links are left to their handlers', () {
    model.push(const SearchRoute());
    expect(model.openLink(Uri.parse('vinylo://open/nowhere')), isTrue);
    expect(model.selectedTab, AppTab.library);
    expect(model.libraryPath, isEmpty);
    expect(model.openLink(Uri.parse('vinylo://spotify-callback?code=x')), isFalse);
    expect(model.openLink(Uri.parse('https://example.com/open/my')), isFalse);
  });
}
