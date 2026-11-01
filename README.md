# swe_2026-2: Vynilo (formerly DAY-OFF / LyricsTranslator)

Learn a language with the songs you already listen to. You log in with Spotify and add songs; Vynilo translates the lyrics line by line with an LLM. Songs play through the Spotify app while the current line follows the music. Tap a line to jump there, open an explanation of slang and idioms, save lines, and take lyric quizzes.

This is the 2026-2 Software Engineering team project. The app was called DAY-OFF up to version 0.7.0.

## Repository layout

| Path | What it is | Build on |
|---|---|---|
| [`app/`](app/) | **Vynilo app (Flutter)**, Android package `com.vynilo.lyrics`. See [`app/README.md`](app/README.md). | Linux / macOS / Windows (Android APK) |
| [`ios/`](ios/) | Native SwiftUI prototype with the `LyricsCore` Swift package. Reference implementation of SSRD v1.2. | macOS + Xcode |
| [`docs/ssad_diagrams/`](docs/ssad_diagrams/) | PlantUML sources for the SSAD figures | any PlantUML |

`app/lib/core` started as a port of `ios/Packages/LyricsCore`. The collection export format is still shared (RQ-18): a collection exported on one platform imports on the other.

## Quick start (Android)

```bash
cd app
flutter test test/core_test.dart test/engines_test.dart test/features_test.dart test/spotify_test.dart \
  test/spotify_remote_test.dart test/streaming_test.dart test/i18n_test.dart test/performance_test.dart
flutter build apk --release --target-platform android-arm64 --dart-define=SPOTIFY_CLIENT_ID=<your client id>
```

**Requirements to run the app**
- A Spotify app registered in the Spotify Developer Dashboard with:
  - the redirect URI `vynilo://spotify-callback`
  - the Android package `com.vynilo.lyrics` and your signing certificate's SHA-1
- On the phone, the Spotify app logged in with a Premium account. In Development mode, that account must be listed under User Management.
- A translation engine, chosen in the app: the on-device model (downloaded in the app), the Vynilo server, an OpenAI-compatible LLM gateway, Claude or Gemini.

Planning documents (SSRD, SSAD, PLAN) are shared on Notion/Drive.
