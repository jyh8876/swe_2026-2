import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

import 'account.dart';

/// Google sign-in with the google_sign_in 7.x API (initialize, then authenticate).
///
/// OAuth client IDs (Google Cloud project vinylo-515813). They are not secrets: every build carries
/// them, as the server URL. The web client's secret is never used by the app, and is not needed
/// by the server either (it checks ID tokens against Google's public keys).
///   GOOGLE_SERVER_CLIENT_ID: the web client. ID tokens are issued for it on Android and iOS, and
///     the server accepts it as the audience (GOOGLE_CLIENT_IDS in server/aws/deploy.env).
///   GOOGLE_IOS_CLIENT_ID: the iOS client (bundle com.vinylo.ios); iOS also needs its reversed ID
///     as GOOGLE_REVERSED_CLIENT_ID in ios/Flutter/Secrets.xcconfig.
/// Android needs no ID in the app: an Android client for com.vinylo.app with the signing
/// certificates' SHA-1 must exist in the same project. Either can be overridden with --dart-define.
/// Without a client ID the sign-in row is not shown, so no control pretends to work.
class GoogleAuth {
  static const webClientId = '280632397596-q4bf88oek80kpst2843t6qgrf9cf59sf.apps.googleusercontent.com';
  static const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID', defaultValue: webClientId);
  static const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// Tests override this; null means "decide from the platform and the client IDs".
  static bool? debugSupported;

  static bool get isConfigured {
    final forced = debugSupported;
    if (forced != null) return forced;
    if (Platform.isIOS) {
      return iosClientId.isNotEmpty && serverClientId.isNotEmpty;
    }
    if (Platform.isAndroid) return serverClientId.isNotEmpty;
    return false;
  }

  static Future<void>? _init;

  static Future<void> _ensureInitialized() {
    return _init ??= GoogleSignIn.instance.initialize(
      clientId: Platform.isIOS && iosClientId.isNotEmpty ? iosClientId : null,
      serverClientId: serverClientId.isNotEmpty ? serverClientId : null,
    );
  }

  /// Opens the Google account chooser. Returns null when the user cancels.
  /// Other failures are rethrown as [GoogleSignInException] for the caller to show.
  static Future<SignInResult?> signIn() async {
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return SignInResult(
        AccountInfo(
          provider: 'google',
          id: account.id,
          email: account.email,
          name: account.displayName,
          photoUrl: account.photoUrl,
        ),
        idToken: account.authentication.idToken,
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Account deletion: revokes Vinylo's access to the Google account, so the next sign-in asks for
  /// consent again and Google lists no connection to Vinylo.
  static Future<void> disconnect() async {
    try {
      await _ensureInitialized();
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      // The server data is already gone; a grant that cannot be revoked now is not a reason to
      // keep the user signed in.
      await signOut();
    }
  }

  static Future<void> signOut() async {
    try {
      await _ensureInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Signing out locally must work even if the Google session is already gone.
    }
  }
}
