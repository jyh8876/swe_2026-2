import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// The signed-in account as the app keeps it on the device: provider, account id, email and
/// name. Tokens are used once (sign-in, deletion) and never stored.
class AccountInfo {
  /// `google` or `apple`.
  final String provider;
  final String id;
  final String? email;
  final String? name;
  final String? photoUrl;

  const AccountInfo({required this.provider, required this.id, this.email, this.name, this.photoUrl});

  bool get isApple => provider == 'apple';

  Map<String, dynamic> toJson() => {'provider': provider, 'id': id, 'email': email, 'name': name, 'photoUrl': photoUrl};

  /// Reads a stored account. Saves from 0.14 had no provider: those were Google accounts.
  static AccountInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final provider = raw['provider'] ?? 'google';
    if (id is! String || id.isEmpty || provider is! String) return null;
    final email = raw['email'];
    // A Google account always has an email; Apple may hide it.
    if (provider == 'google' && (email is! String || email.isEmpty)) return null;
    return AccountInfo(
      provider: provider,
      id: id,
      email: email is String && email.isNotEmpty ? email : null,
      name: raw['name'] as String?,
      photoUrl: raw['photoUrl'] as String?,
    );
  }
}

/// What a sign-in gives back: the profile to keep, plus the one-time tokens for the server.
class SignInResult {
  final AccountInfo account;

  /// OpenID Connect ID token (Google ID token or Apple identity token), for the server.
  final String? idToken;

  /// Apple only: a one-time code the server exchanges to revoke Apple tokens on deletion.
  final String? authorizationCode;

  const SignInResult(this.account, {this.idToken, this.authorizationCode});
}

class AccountApiException implements Exception {
  final int? status;
  final String message;
  const AccountApiException(this.message, [this.status]);
  @override
  String toString() => status == null ? message : '$message ($status)';
}

/// A Vinylo session from the server (30 days), so later calls need no fresh Google/Apple token.
class AccountSession {
  final String token;
  final DateTime expiresAt;
  const AccountSession(this.token, this.expiresAt);

  bool get isValid => DateTime.now().isBefore(expiresAt.subtract(const Duration(hours: 1)));

  String encode() => jsonEncode({'token': token, 'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000});
  static AccountSession? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return AccountSession(j['token'] as String, DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt() * 1000));
    } catch (_) {
      return null;
    }
  }
}

/// Why a user reports an AI translation (server: REPORT_REASONS).
enum ReportReason { wrong, awkward, offensive, reading, other }

/// The Vinylo server (server/aws). It keeps users, song metadata, quiz scores, conquered songs,
/// coins and purchases; never lyrics, translations or quiz questions.
///   --dart-define=VINYLO_API_URL=https://…lambda-url….on.aws
/// Release builds use the deployed server when it is not given, so every build path (the iOS
/// build bot, CI, a local `flutter build`) talks to it without extra flags. Debug runs and tests
/// keep it off unless it is given; then the account stays on the device only.
class AccountApi {
  /// The deployed server (server/aws, Seoul). Not a secret: it is in every release build.
  static const productionUrl = 'https://pruzssudez6nz6w4cb6qmbpvei0msrrh.lambda-url.ap-northeast-2.on.aws';
  static const baseUrl = String.fromEnvironment(
    'VINYLO_API_URL',
    defaultValue: bool.fromEnvironment('dart.vm.product') ? productionUrl : '',
  );

  final String base;
  final http.Client _client;
  AccountApi({String? base, http.Client? client})
      : base = (base ?? baseUrl).replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  bool get isConfigured => base.isNotEmpty;

  Future<Map<String, dynamic>?> _send(String method, String path, String token, [Map<String, Object?>? body]) async {
    final req = http.Request(method, Uri.parse('$base$path'))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
    } catch (_) {
      throw const AccountApiException('network');
    }
    if (r.statusCode == 204) return null;
    if (r.statusCode < 200 || r.statusCode >= 300) {
      String message = 'server';
      try {
        message = '${(jsonDecode(r.body) as Map)['error'] ?? message}';
      } catch (_) {}
      throw AccountApiException(message, r.statusCode);
    }
    if (r.body.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (_) {
      return null;
    }
  }

  /// Signs in with a Google ID token or Apple identity token: creates or updates the user and
  /// returns a session. [name] is sent when Apple gave one (only on the first sign-in);
  /// [country] is the device region (2 letters).
  Future<AccountSession> register(String idToken, {String? name, String? country}) async {
    final j = await _send('POST', '/v1/me', idToken, {'name': ?name, 'country': ?country});
    final s = j?['session'];
    if (s is! Map || s['token'] is! String || s['expiresAt'] is! num) throw const AccountApiException('no session');
    return AccountSession(s['token'] as String, DateTime.fromMillisecondsSinceEpoch((s['expiresAt'] as num).toInt() * 1000));
  }

  /// Deletes everything of the user on the server. For Apple, [authorizationCode] lets the server
  /// revoke the Apple tokens as App Store guideline 5.1.1(v) requires.
  Future<void> delete(String token, {String? authorizationCode}) =>
      _send('DELETE', '/v1/me', token, {'authorizationCode': ?authorizationCode});

  /// Song metadata only: title and artist (no lyrics, no picked covers).
  Future<void> putSong(String token, {required String songID, required String title, required String artist, DateTime? addedAt}) =>
      _send('PUT', '/v1/songs/${Uri.encodeComponent(songID)}', token,
          {'title': title, 'artist': artist, 'addedAt': addedAt?.toUtc().toIso8601String()});

  Future<void> deleteSong(String token, String songID) => _send('DELETE', '/v1/songs/${Uri.encodeComponent(songID)}', token);

  Future<void> putQuiz(String token, String songID, int level, {required int score, DateTime? completedAt}) =>
      _send('PUT', '/v1/quiz/${Uri.encodeComponent(songID)}/$level', token,
          {'score': score, 'completedAt': completedAt?.toUtc().toIso8601String()});

  Future<void> setConquered(String token, String songID, DateTime? at) => at == null
      ? _send('DELETE', '/v1/conquered/${Uri.encodeComponent(songID)}', token)
      : _send('PUT', '/v1/conquered/${Uri.encodeComponent(songID)}', token, {'conqueredAt': at.toUtc().toIso8601String()});

  /// Reports an AI translation: which song and line, why, and which engine made it. The lyric
  /// line and its translation stay on the phone.
  Future<void> report(String token,
          {required ReportReason reason,
          required String title,
          required String artist,
          int? lineIndex,
          String? comment,
          required String engine,
          String? model,
          String? promptVersion,
          String? targetLanguage,
          String? appVersion}) =>
      _send('POST', '/v1/reports', token, {
        'reason': reason.name,
        'title': title,
        'artist': artist,
        'lineIndex': ?lineIndex,
        if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
        'engine': engine,
        'model': ?model,
        'promptVersion': ?promptVersion,
        'targetLanguage': ?targetLanguage,
        'appVersion': ?appVersion,
      });
}

/// Sign in with Apple (iOS; required by App Store guideline 4.8 next to Google sign-in).
class AppleAuth {
  /// Tests override this.
  static bool? debugSupported;
  static bool get isSupported => debugSupported ?? Platform.isIOS;

  /// Shows the Apple sheet. Returns null when the user cancels.
  static Future<SignInResult?> signIn() async {
    try {
      final c = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName]);
      final id = c.userIdentifier;
      if (id == null || id.isEmpty) throw const AccountApiException('no Apple user id');
      final name = [c.givenName, c.familyName].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
      return SignInResult(
        AccountInfo(provider: 'apple', id: id, email: c.email, name: name.isEmpty ? null : name),
        idToken: c.identityToken,
        authorizationCode: c.authorizationCode,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
  }
}
