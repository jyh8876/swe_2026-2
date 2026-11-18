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

/// The Vinylo account server (server/aws): it stores users only, never lyrics or songs.
///   --dart-define=VINYLO_API_URL=https://…lambda-url….on.aws
/// Without it the account stays on the device only.
class AccountApi {
  static const baseUrl = String.fromEnvironment('VINYLO_API_URL');

  final String base;
  final http.Client _client;
  AccountApi({String? base, http.Client? client})
      : base = (base ?? baseUrl).replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  bool get isConfigured => base.isNotEmpty;

  Future<Map<String, dynamic>?> _send(String method, String idToken, [Map<String, Object?>? body]) async {
    final req = http.Request(method, Uri.parse('$base/v1/me'))
      ..headers['authorization'] = 'Bearer $idToken'
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
    return r.body.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  /// Creates or updates the user. [name] is sent when Apple gave one (only on the first sign-in).
  Future<Map<String, dynamic>?> register(String idToken, {String? name}) => _send('POST', idToken, {'name': ?name});

  /// Deletes the user on the server. For Apple, [authorizationCode] lets the server revoke the
  /// Apple tokens as App Store guideline 5.1.1(v) requires.
  Future<void> delete(String idToken, {String? authorizationCode}) =>
      _send('DELETE', idToken, {'authorizationCode': ?authorizationCode});
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
