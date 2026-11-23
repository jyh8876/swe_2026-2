import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:lyrics_translator/core/models.dart';
import 'package:lyrics_translator/ui/covers.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 0.14.0: cover selection (Figma 커버 이미지 선택 / GitHub cover-select-prototype) and the
// per-song translation language of the 노래 추가 form. Lyrics below are invented test lines.
void main() {
  group('default covers', () {
    test('eight Figma presets, picked from the title like the prototype', () {
      expect(DiscCoverStyle.presets, hasLength(8));
      // Same hash as the prototype: h = (h * 31 + code point) >>> 0, then % 8.
      expect(DiscCoverStyle.indexFor('Sample Song'), 3);
      expect(DiscCoverStyle.indexFor('봄날의 노래'), 4);
      expect(DiscCoverStyle.indexFor('Sample Song'), DiscCoverStyle.indexFor('Sample Song'));
    });

    test('renders a PNG for the cover file', () async {
      final png = await DiscCoverPainter(DiscCoverStyle.presets.first).toPng(size: 64);
      expect(png, isNotNull);
      expect(png!.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
    });
  });

  group('per-song translation language', () {
    late AppModel model;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      model = AppModel.test(
          collection: CollectionSnapshot(),
          settings: AppSettings()..hasOnboarded = true,
          prefs: await SharedPreferences.getInstance(),
          baseDir: Directory.systemTemp.createTempSync());
    });

    test('a song added with a language keeps it; others follow the app setting', () {
      final a = model.addSong(AddSongDraft()
        ..title = 'Paper Boats'
        ..artist = 'Test Band'
        ..lyrics = 'We fold the morning into boats\nAnd send them down the street'
        ..targetLanguage = 'ja');
      final b = model.addSong(AddSongDraft()
        ..title = 'Quiet Lamp'
        ..artist = 'Test Band'
        ..lyrics = 'A lamp is on in the window\nNobody is home tonight');
      expect(model.targetFor(a).code, 'ja');
      expect(model.targetFor(b).code, model.target.code);
      model.updateSettings((s) => s.targetLanguage = 'en');
      expect(model.targetFor(a).code, 'ja');
      expect(model.targetFor(b).code, 'en');
    });

    test('the language survives the local and portable JSON', () {
      final s = Song(title: 'T', artist: 'A', lyricsType: LyricsType.plain, sourceProvider: 'manual', targetLanguage: 'de');
      for (final c in [DateCodec.local, DateCodec.portable]) {
        expect(Song.fromJson(s.toJson(c), c).targetLanguage, 'de');
      }
      final old = Song(title: 'T', artist: 'A', lyricsType: LyricsType.plain, sourceProvider: 'manual').toJson(DateCodec.local);
      expect(old.containsKey('targetLanguage'), isFalse);
      expect(Song.fromJson(old, DateCodec.local).targetLanguage, isNull);
    });
  });
}
