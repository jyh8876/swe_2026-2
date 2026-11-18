import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

import 'account.dart';

/// Google sign-in with the google_sign_in 7.x API (initialize, then authenticate).
///
/// Client IDs are build-time settings, so no secret is in the repository:
///   --dart-define=GOOGLE_SERVER_CLIENT_ID=`web client ID`   (Android and iOS)
///   --dart-define=GOOGLE_IOS_CLIENT_ID=`iOS client ID`      (iOS only)
/// Without them the sign-in row is not shown, so no control pretends to work.
class GoogleAuth {
  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
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

  static Future<void> signOut() async {
    try {
      await _ensureInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Signing out locally must work even if the Google session is already gone.
    }
  }
}
