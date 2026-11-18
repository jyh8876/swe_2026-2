import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyrics_translator/app/account.dart';
import 'package:lyrics_translator/app/app_model.dart';
import 'package:lyrics_translator/app/google_auth.dart';
import 'package:lyrics_translator/core/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() {
    GoogleAuth.debugSupported = null;
    AppleAuth.debugSupported = null;
  });

  group('stored account', () {
    test('Google and Apple accounts survive a JSON round trip', () {
      for (final a in const [
        AccountInfo(provider: 'google', id: '1234', email: 'user@example.com', name: 'Test User', photoUrl: 'https://example.com/p.png'),
        AccountInfo(provider: 'apple', id: '001.abc', email: null, name: null),
      ]) {
        final back = AccountInfo.fromJson(jsonDecode(jsonEncode(a.toJson())))!;
        expect([back.provider, back.id, back.email, back.name, back.photoUrl], [a.provider, a.id, a.email, a.name, a.photoUrl]);
      }
    });

    test('a 0.14 save (Google account without provider) still loads', () {
      final s = AppSettings.fromJson({'googleAccount': {'id': '7', 'email': 'x@y.z', 'name': 'X'}});
      expect(s.account?.provider, 'google');
      expect(s.account?.email, 'x@y.z');
      expect(AppSettings.fromJson(s.toJson()).account?.id, '7');
    });

    test('broken or partial stored accounts are ignored, not thrown', () {
      expect(AccountInfo.fromJson(null), isNull);
      expect(AccountInfo.fromJson('not a map'), isNull);
      expect(AccountInfo.fromJson({'id': '', 'email': 'a@b.c'}), isNull);
      expect(AccountInfo.fromJson({'id': '1', 'email': null}), isNull); // Google needs an email
      expect(AccountInfo.fromJson({'provider': 'apple', 'id': '1'})?.email, isNull); // Apple may hide it
    });

    test('sign-in rows are offered only where they can work', () {
      GoogleAuth.debugSupported = false;
      AppleAuth.debugSupported = false;
      expect(GoogleAuth.isConfigured, isFalse);
      expect(AppleAuth.isSupported, isFalse);
      AppleAuth.debugSupported = true;
      expect(AppleAuth.isSupported, isTrue);
    });

    test('without build-time settings nothing is configured in tests', () {
      expect(GoogleAuth.serverClientId, isEmpty);
      expect(AccountApi.baseUrl, isEmpty);
      expect(AccountApi().isConfigured, isFalse);
    });
  });

  group('account server', () {
    late List<http.Request> sent;
    AccountApi api(int status, [String body = '{}']) => AccountApi(
        base: 'https://api.example.com/',
        client: MockClient((r) async {
          sent.add(r);
          return http.Response(body, status);
        }));
    setUp(() => sent = []);

    test('register sends the ID token and the Apple name', () async {
      await api(200, '{"userId":"apple:1"}').register('tok', name: 'Kim');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.toString(), 'https://api.example.com/v1/me');
      expect(sent.single.headers['authorization'], 'Bearer tok');
      expect(jsonDecode(sent.single.body), {'name': 'Kim'});
    });

    test('delete sends the Apple authorization code', () async {
      await api(204, '').delete('tok', authorizationCode: 'code1');
      expect(sent.single.method, 'DELETE');
      expect(jsonDecode(sent.single.body), {'authorizationCode': 'code1'});
    });

    test('server errors carry the status and message', () async {
      await expectLater(api(401, '{"error":"wrong audience"}').register('tok'),
          throwsA(isA<AccountApiException>().having((e) => e.status, 'status', 401).having((e) => e.message, 'message', 'wrong audience')));
    });
  });

  group('model', () {
    late AppModel model;
    late List<http.Request> sent;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      model = AppModel.test(
          collection: CollectionSnapshot(), settings: AppSettings(), prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
      sent = [];
    });

    test('sign-in registers on the server first, then keeps the account', () async {
      model.accountApi = AccountApi(base: 'https://api.example.com', client: MockClient((r) async => (sent..add(r)).isEmpty ? http.Response('', 500) : http.Response('{}', 200)));
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '001.x', name: 'Kim'), idToken: 'tok', authorizationCode: 'c'));
      expect(sent.single.headers['authorization'], 'Bearer tok');
      expect(model.account?.provider, 'apple');
    });

    test('a server failure leaves the app signed out', () async {
      model.accountApi = AccountApi(base: 'https://api.example.com', client: MockClient((r) async => http.Response('{"error":"down"}', 503)));
      await expectLater(model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '1'), idToken: 'tok')), throwsA(isA<AccountApiException>()));
      expect(model.account, isNull);
    });

    test('without a server the account stays on the device, and deletion clears it', () async {
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '1')));
      expect(model.account?.id, '1');
      expect(await model.deleteAccount(), isTrue);
      expect(model.account, isNull);
    });
  });
}
