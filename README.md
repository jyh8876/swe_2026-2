# swe_2026-2: DAY-OFF (LyricsTranslator)

Learn a language with the songs you already listen to. The app shows synced lyrics line by line with a natural translation under each line, explains slang and idioms on tap, and keeps studied songs as an LP collection.

This is the 2026-2 Software Engineering team project.

## Repository layout

| Path | What it is | Build on |
|---|---|---|
| [`app/`](app/) | **Cross-platform app (Flutter)**, one codebase for Android and iOS. The UI follows the [UI prototype](https://github.com/jyh8876/swe-2026_2_UI/commit/898667e687cc962b3ce14737baed32f0673bf61d) (light home with album carousel/grid, dark player, white explanation sheet). | Linux / macOS / Windows (APK); macOS + Xcode (iOS) |
| [`ios/`](ios/) | Native SwiftUI prototype with the `LyricsCore` Swift package. Reference implementation of SSRD v1.2. | macOS + Xcode |
| [`docs/ssad_diagrams/`](docs/ssad_diagrams/) | PlantUML sources for the SSAD figures (components, states, use cases, sequences, deployment) | any PlantUML |

`app/lib/core` is a 1:1 port of `ios/Packages/LyricsCore`, so both apps follow the same business rules and the same export file format (RQ-18). A collection exported on an iPhone can be imported on Android, and the other way round.

## Quick start

```bash
# Android APK
cd app
flutter test                                  # core unit tests
flutter build apk --release --split-per-abi   # → build/app/outputs/flutter-apk/

# iOS (Mac with Xcode)
cd app && flutter build ios                   # Flutter app
open ios/LyricsTranslator.xcodeproj           # or the native SwiftUI prototype
```

Try it without any account: **노래 추가** → search `day off` → **저장** → open the LP → press play. The bundled demo song has original lyrics written for this project, and it works offline.

Planning documents (SSRD, SSAD, PLAN) are shared on Notion/Drive and are git-ignored on purpose.
