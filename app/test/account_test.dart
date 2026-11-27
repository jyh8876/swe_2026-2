import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

    test('the Google web client is built in; the server stays off in tests', () {
      expect(GoogleAuth.serverClientId, GoogleAuth.webClientId);
      expect(GoogleAuth.serverClientId, endsWith('.apps.googleusercontent.com'));
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

    test('register sends the ID token, the Apple name and the country, and returns a session', () async {
      final s = await api(200, '{"user":{"userId":"apple:1"},"session":{"token":"sess","expiresAt":4102444800}}').register('tok', name: 'Kim', country: 'KR');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.toString(), 'https://api.example.com/v1/me');
      expect(sent.single.headers['authorization'], 'Bearer tok');
      expect(jsonDecode(sent.single.body), {'name': 'Kim', 'country': 'KR'});
      expect(s.token, 'sess');
      expect(AccountSession.decode(s.encode())!.expiresAt, s.expiresAt);
      await expectLater(api(200, '{}').register('tok'), throwsA(isA<AccountApiException>()));
    });

    test('song, quiz and conquered calls carry metadata only', () async {
      final a = api(200);
      await a.putSong('sess', songID: 's 1', title: 'T', artist: 'A', addedAt: DateTime.utc(2026, 11, 20));
      await a.putQuiz('sess', 's1', 3, score: 80);
      await a.setConquered('sess', 's1', null);
      expect(sent.map((r) => '${r.method} ${r.url.path}'), ['PUT /v1/songs/s%201', 'PUT /v1/quiz/s1/3', 'DELETE /v1/conquered/s1']);
      expect(jsonDecode(sent.first.body), {'title': 'T', 'artist': 'A', 'addedAt': '2026-11-20T00:00:00.000Z'});
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
    const session = '{"user":{},"session":{"token":"sess","expiresAt":4102444800}}';
    http.Client server() => MockClient((r) async {
          sent.add(r);
          return http.Response(r.url.path == '/v1/me' && r.method == 'POST' ? session : '{}', 200);
        });
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      model = AppModel.test(
          collection: CollectionSnapshot(), settings: AppSettings(), prefs: await SharedPreferences.getInstance(), baseDir: Directory.systemTemp.createTempSync());
      sent = [];
    });

    test('sign-in registers on the server first, then keeps the account', () async {
      model.accountApi = AccountApi(base: 'https://api.example.com', client: server());
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '001.x', name: 'Kim'), idToken: 'tok', authorizationCode: 'c'));
      expect(sent.single.headers['authorization'], 'Bearer tok');
      expect(model.account?.provider, 'apple');
    });

    test('after sign-in, songs and progress go to the server with the session, lyrics never', () async {
      final id = model.addSong(AddSongDraft()
        ..title = 'Day Off'
        ..artist = 'Band'
        ..lyrics = 'secret lyric line');
      model.accountApi = AccountApi(base: 'https://api.example.com', client: server());
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '1'), idToken: 'tok'));
      // Full sync of the song added before sign-in.
      expect(sent.map((r) => '${r.method} ${r.url.path}'), ['POST /v1/me', 'PUT /v1/songs/$id']);
      model.setConquered(id, true);
      model.passQuizLevel(id, 1, score: 90);
      model.editSong(id, title: 'Day Off (Live)', artist: 'Band');
      await model.reportTranslation(id, reason: ReportReason.offensive, lineIndex: 0, comment: 'too strong');
      await pumpEventQueue();
      expect(sent.skip(2).map((r) => '${r.method} ${r.url.path}'),
          containsAll(['PUT /v1/conquered/$id', 'PUT /v1/quiz/$id/1', 'PUT /v1/songs/$id', 'POST /v1/reports']));
      expect(sent.skip(1).every((r) => r.headers['authorization'] == 'Bearer sess'), isTrue);
      expect(sent.any((r) => r.body.contains('secret lyric')), isFalse);
      final report = jsonDecode(sent.firstWhere((r) => r.url.path == '/v1/reports').body) as Map;
      expect([report['reason'], report['lineIndex'], report['title']], ['offensive', 0, 'Day Off (Live)']);
      expect(model.wasReported(id, 0), isTrue);
    });

    test('a report needs the server and a sign-in', () async {
      final id = model.addSong(AddSongDraft()
        ..title = 'T'
        ..artist = 'A'
        ..lyrics = 'x');
      await expectLater(model.reportTranslation(id, reason: ReportReason.wrong), throwsA(isA<AccountApiException>().having((e) => e.message, 'm', 'not configured')));
      model.accountApi = AccountApi(base: 'https://api.example.com', client: server());
      await expectLater(model.reportTranslation(id, reason: ReportReason.wrong), throwsA(isA<AccountApiException>().having((e) => e.status, 's', 401)));
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

    test('deleting a Google account revokes its grant to Vinylo; an Apple one does not touch Google', () async {
      var revoked = 0;
      model.googleDisconnect = () async => revoked++;
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'apple', id: '1')));
      expect(await model.deleteAccount(), isTrue);
      expect(revoked, 0);
      await model.completeSignIn(const SignInResult(AccountInfo(provider: 'google', id: '2', email: 'a@b.c')));
      expect(await model.deleteAccount(), isTrue);
      expect(revoked, 1);
      expect(model.account, isNull);
    });
  });
}
