import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/i18n.dart';
import 'package:lyrics_translator/app/i18n_strings.dart';
import 'package:lyrics_translator/core/models.dart';

void main() {
  tearDown(() => I18n.lang = 'ko');

  test('every tr() string in lib has en, zh and ja with the same placeholders', () {
    final keys = <String>{};
    final lit = RegExp(r"\btr\('((?:[^'\\\n]|\\.)*)'");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in lit.allMatches(f.readAsStringSync())) {
        keys.add(m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1) == 'n' ? '\n' : x.group(1)!));
      }
    }
    expect(keys.length, greaterThan(250));
    final holes = RegExp(r'\{\d\}');
    for (final lang in ['en', 'zh', 'ja']) {
      for (final k in keys) {
        final v = uiStrings[lang]![k];
        expect(v, isNotNull, reason: '$lang missing: $k');
        expect(holes.allMatches(v!).map((m) => m[0]).toSet(), holes.allMatches(k).map((m) => m[0]).toSet(), reason: '$lang placeholders: $k');
      }
    }
  });

  test('tr fills placeholders and falls back to Korean', () {
    I18n.lang = 'en';
    expect(tr('{0}곡 · 정복 {1}곡', [5, 2]), '5 songs · 2 conquered');
    expect(tr('번역에 없는 문장'), '번역에 없는 문장');
    I18n.lang = 'ja';
    expect(tr('라이브러리'), 'ライブラリ');
    I18n.lang = 'ko';
    expect(tr('{0}곡', [3]), '3곡');
  });

  test('languages: UI ko/en/zh/ja, targets ko/en/zh/ja/de/fr, saved in settings', () {
    expect(Language.uiLanguages.map((l) => l.code), ['ko', 'en', 'zh', 'ja']);
    expect(Language.supported.map((l) => l.code), ['ko', 'en', 'zh', 'ja', 'de', 'fr']);
    expect(Language.named('es').englishName, 'Spanish'); // older saved target still resolves
    final s = AppSettings()
      ..uiLanguage = 'zh'
      ..targetLanguage = 'fr';
    final back = AppSettings.fromJson(s.toJson());
    expect(back.uiLanguage, 'zh');
    expect(back.target.englishName, 'French');
    expect(AppSettings().uiLanguage, 'ko');
  });
}
