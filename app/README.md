# Vynilo app (Flutter)

Version 0.9.0, Android package `com.vynilo.lyrics`. Named DAY-OFF / LyricsTranslator up to 0.7.0.

## What it does
- **Spotify login first.** The app opens on a "Spotify로 계속하기" screen. Music plays only through the Spotify app, via the Spotify App Remote SDK on Android; the Spotify Web API is used for login, search, your library (playlists, saved albums, liked songs), covers and finding track IDs.
- **Adding songs:**
  - Search lyrics on LRCLIB (retries when it is busy), or pick tracks from your Spotify library; the album art becomes the cover.
  - Manual add with LRC auto-detection, and a duplicate check.
- **Translation engines:**
  - On-device llama.cpp with Gemma 4 E2B (downloaded in the app, Android arm64).
  - The Vynilo server (self-hosted, over Tailscale).
  - Any OpenAI-compatible gateway, Claude, or Gemini.
- **How translation runs:**
  - Gateway and Claude responses stream, so lines appear one by one; the translating screen shows a live feed and an animated record.
  - Songs already in the target language are not translated.
- **Player:**
  - Synced lyrics follow the current line; tap a line to jump the music there.
  - Line explanations open in a sheet that keeps the playback controls.
  - Seek bar with a line preview, line snapping and fine scrubbing; ±0.5 s timing offset.
- **Library and study:**
  - Album slide / grid / list / 3D stack views, plus recommendations.
  - Saved lines, fill-in-the-blank quiz (3 levels, clearing them "conquers" the song), collection calendar and a share card.
- **Look:** dark (default) or white theme with five accent colours.
- **Languages:** the interface comes in Korean, English, Chinese and Japanese; songs can be translated into Korean, English, Chinese, Japanese, German or French.

## Layout

```
app/
├── lib/core/      platform-free logic
│   ├── models.dart        Song, LyricLine, Translation, Explanation, Phrase, ListenSession, Language
│   ├── collection.dart    CollectionSnapshot (indexed lookups), JSON repository, export/import, mastery, shelves
│   ├── lyrics.dart        LRC parser, track normaliser and matcher, LRCLIB client
│   ├── llm.dart           engines (gateway, Claude, Gemini, Vynilo server, on-device), prompts,
│   │                      streaming line parser, output validator, language detection, TranslationJob
│   ├── playback.dart      NowPlayingSource, SyncEngine (SimulatedSource is for tests)
│   ├── quiz.dart          lyric quiz builder
│   └── recommend.dart     recommendations, search result de-duplication
├── lib/app/       AppModel (state, playback position, Spotify connection), platform services
│                  (Spotify auth / App Remote, secure store, model download, covers), Spotify library,
│                  theme tokens, i18n (tr() + i18n_strings.dart)
├── lib/ui/        one file per screen; player_controls.dart is shared by the player and the line sheet
├── android/app/src/main/kotlin/com/vynilo/lyrics/   MainActivity, SpotifyRemoteBridge (App Remote SDK)
├── android/app/src/main/kotlin/com/vynilo/llm/ + src/main/cpp/   llama.cpp JNI bridge
├── android/app/libs/   spotify-app-remote-release-0.8.0.aar
└── test/          unit tests (core, engines, streaming, Spotify, App Remote channels, i18n, features, performance)
```

## Build

```bash
export PATH=$HOME/sdk/flutter/bin:$PATH ANDROID_HOME=$HOME/sdk/android
flutter analyze
flutter test test/core_test.dart test/engines_test.dart test/features_test.dart test/spotify_test.dart \
  test/spotify_remote_test.dart test/streaming_test.dart test/i18n_test.dart test/performance_test.dart
flutter build apk --release --target-platform android-arm64 --dart-define=SPOTIFY_CLIENT_ID=<client id>
```

**Build settings**
- **Release signing:** reads `android/key.properties`, which is gitignored: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. Without it the build falls back to the debug key, whose SHA-1 must then be registered with Spotify instead.
- **On-device engine:** needs a llama.cpp checkout, set as `llamaCppDir=/path/to/llama.cpp` in `~/.gradle/gradle.properties`. Without it, the app builds without that engine.
- **R8 minification:** off on purpose. `shared_preferences_android` and `path_provider_android` reach Kotlin through `package:jni`, and a minified APK hangs on start.

**UI strings:** write them in Korean inside `tr('…')`, then add the English, Chinese and Japanese entries to `lib/app/i18n_strings.dart`. `test/i18n_test.dart` fails on any missing translation.

## Known gaps
- **iOS:** this app's Spotify playback (App Remote) and on-device engine are Android-only. The Flutter iOS target has not been updated for the Spotify login and playback.
- **Integration test:** `integration_test/app_flow_test.dart` and `test/screens/` predate the Spotify login screen and the removal of the demo song. They need a Spotify login step before they can pass again. They were not run for 0.9.0.
