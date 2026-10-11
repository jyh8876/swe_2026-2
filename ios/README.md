# LyricsTranslator (working brand: DAY-OFF) — iOS prototype

Learn a language with the songs you already listen to. The app shows synced lyrics line by line with a natural translation under each line, explains slang and idioms on tap, and keeps studied songs as an **LP collection**.

This is the **prototype code and basic structure** for the December 2026 iOS release. It is derived from:

- **SSRD v1.2** (`../LyricsTranslator_SSRD_v1.2.docx`): requirement IDs (RQ-, ONRQ-, SIR-, LOS-, DCR-) are cited in code comments
- **Figma** "LyricsTranslator – UI/UX" (screens FG-00 to FG-09)
- **Technical Plan v2** (`../PLAN.md`) and the concept note (Notion)

## Layout

```
ios/
├── project.yml                     XcodeGen spec (source of truth for the Xcode project)
├── LyricsTranslator.xcodeproj      generated from project.yml
├── Config/
│   ├── App.xcconfig                shared settings (includes Secrets.xcconfig if present)
│   └── Secrets.example.xcconfig    copy → Secrets.xcconfig (git-ignored)
├── Packages/LyricsCore/            platform-free core Swift package (PR-5, Win-AGRE-3)
│   ├── Sources/LyricsCore/
│   │   ├── Models/                 Song, LyricLine, Translation, Explanation, Phrase, ListenSession, Language
│   │   ├── Lyrics/                 LRC parser, LRCLIB client (SIR-7), title normaliser and track matcher
│   │   ├── Sync/                   SyncEngine: extrapolated playhead and current line (LOS-1)
│   │   ├── NowPlaying/             NowPlayingSource protocol plus SimulatedSource
│   │   ├── LLM/                    LLMEngine/Translator/Explainer, Claude and Gemini BYOK, prompts, output validator, demo engine
│   │   ├── Services/               TranslationJob: whole-song pre-translation with per-line commit (RQ-7)
│   │   ├── Collection/             CollectionSnapshot store, export/import with merge (RQ-18), mastery rules (RQ-13)
│   │   ├── Security/               SecureStore protocol
│   │   └── Curation/               curated shelves JSON (RQ-17), offline demo song
│   └── Tests/LyricsCoreTests/      34 unit tests
└── LyricsTranslator/               SwiftUI app (iPhone; runs on Apple-silicon Macs as "Designed for iPad")
    ├── App/                        @main, AppModel (state and orchestration), settings, navigation
    ├── DesignSystem/               themes (Midnight and Woody), LP card, vinyl, badges, buttons
    ├── Features/
    │   ├── Onboarding/             FG-00  intro cards, engine choice, "Connect your music" (DCR-1)
    │   ├── Library/                FG-01 / FG-01-1  LP grid, now-playing bar (DCR-2), curated shelves (DCR-8)
    │   ├── Search/                 FG-02  LRCLIB search with Synced / Plain / No-lyrics badges
    │   ├── AddSong/                FG-03  cover, title, artist, lyrics (LRC auto-detect), duplicate check
    │   ├── Translating/            FG-04  spinning record, n/N lines, stages, ETA, first-line preview
    │   ├── Saved/                  FG-05  LP drops onto the shelf
    │   ├── Player/                 FG-06  synced lyrics, auto-scroll, star, transport, offset, gold LP
    │   ├── LineDetail/             FG-07  explanation sheet: key expressions, structure, usage, example
    │   ├── PhraseBox/              FG-08  saved phrases, stats, sort, undo
    │   └── Settings/               FG-09  engine, API key and verify, theme, language, connections, data
    ├── Platform/                   Keychain, Apple Music source, Spotify stub, engine factory,
    │                               Apple Foundation Models engine, llama.cpp placeholder, network monitor
    └── Resources/                  Info.plist, Assets.xcassets
```

## Build (needs a Mac with Apple silicon and Xcode 16 or later)

iOS apps cannot be built on Linux or Windows (PR-6). On a Mac:

```bash
cd ios
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # set DEVELOPMENT_TEAM (and Spotify client ID later)
brew install xcodegen && xcodegen generate                   # optional: regenerates the committed .xcodeproj
open LyricsTranslator.xcodeproj
```

Select the **LyricsTranslator** scheme, then an iPhone simulator or device, and press Run.

Core tests run anywhere Swift 6 is installed, including Linux:

```bash
cd ios/Packages/LyricsCore && swift test
```

## Try the full study loop without any account

1. Onboarding: pick **On-device**, then tap **나중에 하기** ("Later").
2. Tap **+ 노래 추가**, search `day off`, and pick the bundled demo song **Day-Off — Team 9**. It has synced lyrics and works offline.
3. Tap **저장** ("Save"). The translating screen shows progress, then the saved screen appears.
4. Tap **바로 공부하기** ("Study now"), then **데모 재생** ("Demo play") in the study-only banner. Lyrics now sync to a simulated playhead.
5. Tap a line to open its explanation. Star lines to collect them in **문장 저장함** (the phrase box).

## UI/UX test mode (no SDKs, no device needed)

Every screen works in the iOS Simulator. Features that need an external SDK or real hardware fall back to simple mocks:

| Feature | What you get in the prototype |
|---|---|
| Connect **Spotify** (onboarding or Settings) | Mock link. It "plays" your newest synced song (or the demo song), so the now-playing bar, synced lyrics, transport and seek all work. The Search screen shows the **내 스포티파이 플레이리스트** ("My Spotify playlists") tab with mock playlists, and tapping a song searches for it. |
| Connect **Apple Music** in the Simulator or on a Mac | The same mock link. On a real iPhone it uses the Music app. |
| **이 곡 재생** ("Play this song") / **데모 재생** ("Demo play") in the Player | Loads that song on the active link, so any synced song can be studied with live sync. |
| On-device engine | `DemoEngine` produces instant placeholder translations and explanations. Claude and Gemini are real if you enter an API key. |
| Settings → **온디바이스 모델 다운로드** ("Download on-device model") | Simulated ~4 s download with progress. The model then shows as installed and can be deleted. |

## Engines (Win-AGRE-4)

| Choice | Implementation in this prototype |
|---|---|
| On-device | **Apple Foundation Models** (`AppleFMEngine`) on iOS 26+ Apple Intelligence devices. Otherwise a **llama.cpp** placeholder once a model is installed. Otherwise the deterministic **DemoEngine**. Spike S1 picks the default. |
| Claude (BYOK) | `ClaudeEngine`: Messages API over URLSession. One request per song, JSON output validated per line, backoff on 429/5xx. Default model `claude-haiku-4-5` (SIR-9). |
| Gemini (BYOK) | `GeminiEngine`: `generateContent` with the JSON response type. The key is sent in a header, never in the URL. |

API keys are stored only in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). They are masked after saving and removed by **전체 삭제** ("Delete all") (PR-10, LOS-10).

## What is stubbed (next iterations)

| Item | Status | Where |
|---|---|---|
| Spotify App Remote (SIR-5) | Mock link (see above). The real adapter needs `SpotifyiOS.xcframework` in `ios/Vendor/` (git-ignored), a client ID in `Secrets.xcconfig`, and redirect URI `lyricstranslator://spotify-callback` on the dashboard. | `Platform/MusicSources.swift` |
| llama.cpp engine (SIR-8) | Placeholder that delegates to DemoEngine. Add the pinned llama.cpp Swift package if S1 selects it. | `Platform/Engines.swift` |
| Model download with SHA-256 check (PR-9) | Simulated download that writes a marker file. | `Platform/Engines.swift` |
| SQLite (WAL) store (LOS-3) | Prototype uses an atomically written JSON file behind `CollectionRepository`. Swap the implementation without touching callers. | `Collection/CollectionSnapshot.swift` |
| iCloud sync (RQ-18) | Export/import is done. CloudKit sync ships "if time allows" (Win-AGRE-11). | Settings → Data |
| Native Mac layout (DCR-9) | Runs as "Designed for iPad" on Apple-silicon Macs. | — |
| Curated shelves (RQ-17) | 3 shelves × 5 songs. Release needs 10+ per shelf, checked against LRCLIB. | `Curation/Resources/curated_shelves.json` |

## Conventions

- Business logic lives in `LyricsCore`, never in views (PR-5). The core has no third-party dependencies.
- Every external system goes through exactly one adapter (SSRD §4.4, A.III).
- Translations and explanations are keyed by engine ID and prompt version, so changing models never overwrites earlier results.
- No analytics, no team server (PR-1, LOS-11).
- The app uses Swift 5 language mode with targeted concurrency checking for the prototype. The core package already builds in Swift 6 mode.
