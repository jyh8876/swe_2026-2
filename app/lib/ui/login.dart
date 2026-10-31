import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../app/i18n.dart';
import '../app/theme.dart';
import '../core/playback.dart';
import 'translating_record.dart';

/// First screen: Vynilo plays music through Spotify, so the app starts with the Spotify login.
/// The button follows Spotify's branding (Spotify green, the official icon, black text).
class SpotifyLoginView extends StatefulWidget {
  const SpotifyLoginView({super.key});
  @override
  State<SpotifyLoginView> createState() => _SpotifyLoginViewState();
}

class _SpotifyLoginViewState extends State<SpotifyLoginView> with WidgetsBindingObserver {
  static const spotifyGreen = Color(0xFF1ED760);
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the browser without finishing the login re-enables the button.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _waiting = false);
      });
    }
  }

  Future<void> _login() async {
    setState(() => _waiting = true);
    await context.readModel.connect(SourceID.spotify);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final t = context.theme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(flex: 2),
            const Center(child: SizedBox(width: 200, height: 200, child: TranslatingRecord(progress: 0.72, pulse: 0))),
            const SizedBox(height: 32),
            Text('Vynilo', textAlign: TextAlign.center, style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: t.textPrimary)),
            const SizedBox(height: 10),
            Text(tr('좋아하는 노래로 외국어를 배워요.\n가사가 음악에 맞춰 흐르고, 한 줄씩 번역돼요.'),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 15, height: 1.5, color: t.textSecondary)),
            const Spacer(flex: 3),
            Semantics(
              button: true,
              label: tr('Spotify로 계속하기'),
              excludeSemantics: true,
              child: SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: _waiting || !model.spotifyAuth.isConfigured ? null : _login,
                  style: FilledButton.styleFrom(
                    backgroundColor: spotifyGreen,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: spotifyGreen.withValues(alpha: 0.5),
                    disabledForegroundColor: Colors.black54,
                    shape: const StadiumBorder(),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (_waiting)
                      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black))
                    else
                      Image.asset('assets/brand/spotify_icon_black.png', width: 26, height: 26),
                    const SizedBox(width: 12),
                    Text(tr('Spotify로 계속하기'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(tr('Spotify Premium 계정과 이 휴대폰의 Spotify 앱이 필요해요.'),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: t.textTertiary)),
            const SizedBox(height: 6),
            Text(tr('컬렉션은 이 기기에만 저장되고, 가사는 선택한 번역 엔진으로만 전송돼요.'),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: t.textTertiary)),
            if (!model.spotifyAuth.isConfigured) ...[
              const SizedBox(height: 12),
              Text(tr('이 빌드에는 Spotify 앱 정보가 없어요.'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFFE57373))),
            ],
          ]),
        ),
      ),
    );
  }
}
