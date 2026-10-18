# DAY-OFF (LyricsTranslator), cross-platform app: Android + iOS

This is a Flutter port of the SwiftUI prototype in `../ios`. One Dart codebase builds both the Android APK and the iOS app. It has the same features and flows (FG-00 to FG-09), the same Korean copy, and the same requirement IDs in the comments.

The visual design follows the UI prototype [swe-2026_2_UI@898667e](https://github.com/jyh8876/swe-2026_2_UI/commit/898667e687cc962b3ce14737baed32f0673bf61d): a light home screen with a 3D album carousel / grid toggle and a **노래 추가** pill, a home / likes / my-page tab bar, a mini player, a dark player whose seek bar marks saved lines, and a white explanation sheet. Only the design was taken from the prototype. Its sample lyrics and album covers are not part of this repo.

## Layout

```
app/
├── lib/core/        platform-free logic, ported 1:1 from ios/Packages/LyricsCore
│   ├── models.dart       Song, LyricLine, Translation, Explanation, Phrase, ListenSession, Language
│   ├── lyrics.dart       LRC parser, title normaliser and track matcher, LRCLIB client, demo song
│   ├── playback.dart     NowPlayingSource, SimulatedSource, SyncEngine
│   ├── llm.dart          engine interface, prompts, output validator, Demo/Claude/Gemini engines, TranslationJob
│   └── collection.dart   CollectionSnapshot, JSON repository, export/import merge, mastery rules, shelves
├── lib/app/         AppModel (state and orchestration), settings, design tokens (theme.dart), secure store, engine factory
├── lib/ui/          one file per screen (library, player, line_detail, mini_player, …)
├── assets/          curated_shelves.json (the same file the iOS app bundles)
├── test/core_test.dart   26 unit tests ported from the LyricsCore XCTests
└── test/screens/         renders the main screens to PNG for design review (needs a Korean system font)
```

## Build

```bash
export PATH=$HOME/sdk/flutter/bin:$PATH ANDROID_HOME=$HOME/sdk/android
flutter test                    # core tests
flutter build apk --release     # → build/app/outputs/flutter-apk/app-release.apk
```

iOS needs a Mac with Xcode: run `flutter build ios`, or open `ios/Runner.xcworkspace`. The bundle ID is `com.team9.lyricstranslator`, the same as the native prototype.

## Same as the SwiftUI prototype

- Search on LRCLIB (with Synced / Plain / No-lyrics badges), manual add with LRC auto-detection, and a duplicate check.
- Whole-song pre-translation with a commit after each line and resume on relaunch. On-device jobs pause in the background.
- A synced lyrics player with auto-scroll that pauses for 5 s after a manual scroll, a ±0.5 s offset, seek, and the gold-LP "conquered" flow.
- Line explanations (cached) and the phrase box (likes tab) with undo.
- Claude and Gemini BYOK with key verification. Keys go to the Keychain on iOS and Keystore-backed storage on Android.
- Export and import use the **same JSON schema as iOS**, so a collection can move between an iPhone and an Android phone.

## Still stubbed

These are the same stubs as in the iOS prototype:

| Item | Status |
|---|---|
| Spotify / Apple Music | Mock link that "plays" the newest synced song on a timer |
| On-device LLM (llama.cpp) | DemoEngine placeholder. The model download is simulated. |
| Spotify playlists tab | Built from the curated shelves |
| Language detection | Script-based heuristic instead of Apple NaturalLanguage |
