import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/core/llm.dart';

void main() {
  test('only on-device, Gemini and gateway are offered', () {
    expect(EngineKind.offered, [EngineKind.onDevice, EngineKind.gemini, EngineKind.gateway]);
  });

  test('saved Vinylo server or Claude settings move to Gemini', () {
    for (final old in ['vinylo', 'vynilo', 'claude']) {
      expect(AppSettings.fromJson({'engine': old}).engine, EngineKind.gemini, reason: old);
    }
    expect(AppSettings.fromJson({'engine': 'gateway'}).engine, EngineKind.gateway);
    expect(AppSettings.fromJson({}).engine, EngineKind.onDevice);
  });

  test('server settings saved under the old spelling are kept', () {
    final s = AppSettings.fromJson({'vyniloURL': 'https://old', 'vyniloModel': 'm'});
    expect(s.vinyloURL, 'https://old');
    expect(s.vinyloModel, 'm');
  });
}
