import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/google_auth.dart';

void main() {
  tearDown(() => GoogleAuth.debugSupported = null);

  test('account profile survives a JSON round trip', () {
    const account = GoogleAccountInfo(id: '1234', email: 'user@example.com', name: 'Test User', photoUrl: 'https://example.com/p.png');
    final back = GoogleAccountInfo.fromJson(jsonDecode(jsonEncode(account.toJson())));
    expect(back?.id, '1234');
    expect(back?.email, 'user@example.com');
    expect(back?.name, 'Test User');
    expect(back?.photoUrl, 'https://example.com/p.png');
  });

  test('a broken or partial stored account is ignored, not thrown', () {
    expect(GoogleAccountInfo.fromJson(null), isNull);
    expect(GoogleAccountInfo.fromJson('not a map'), isNull);
    expect(GoogleAccountInfo.fromJson({'id': '', 'email': 'a@b.c'}), isNull);
    expect(GoogleAccountInfo.fromJson({'id': '1', 'email': null}), isNull);
    final ok = GoogleAccountInfo.fromJson({'id': '1', 'email': 'a@b.c'});
    expect(ok?.name, isNull);
    expect(ok?.photoUrl, isNull);
  });

  test('settings keep the signed-in account and clear it on sign-out', () {
    final s = AppSettings()..googleAccount = const GoogleAccountInfo(id: '7', email: 'x@y.z');
    final restored = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map);
    expect(restored.googleAccount?.email, 'x@y.z');

    final signedOut = AppSettings.fromJson(jsonDecode(jsonEncode((AppSettings()..googleAccount = null).toJson())) as Map);
    expect(signedOut.googleAccount, isNull);
  });

  test('the Google row is offered only when the build has client IDs', () {
    GoogleAuth.debugSupported = false;
    expect(GoogleAuth.isConfigured, isFalse);
    GoogleAuth.debugSupported = true;
    expect(GoogleAuth.isConfigured, isTrue);
  });

  test('without build-time client IDs nothing is configured in tests', () {
    // Tests run without --dart-define, so the built-in default must be "not configured".
    expect(GoogleAuth.serverClientId, isEmpty);
    expect(GoogleAuth.iosClientId, isEmpty);
  });
}
