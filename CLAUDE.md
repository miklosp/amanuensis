# CLAUDE.md

macOS SwiftUI app. Bundle identifier `work.miklos.audio-pipeline`, deployment target macOS 26.3, Swift 6.2. M1 (menu-bar recorder, mic + system audio capture via Core Audio process tap, FLAC conversion) is complete. Source for the audio + storage + settings layers lives in a local SPM umbrella package at `Packages/AudioPipeline/`; the app target keeps UI, the app entry point, and `AppCoordinator` as the composition root.

## Build & run

There is no Xcode workspace, only the `.xcodeproj`. Outside the Claude Code sandbox (regular terminal, Xcode):

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline clean
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -showBuildSettings | rg '^\s+BUILT_PRODUCTS_DIR'
```
To launch the built app: `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`. For interactive development, opening the `.xcodeproj` in Xcode and using ⌘R is faster.

## Tests

Two test surfaces:

- **SPM tests** (autonomous, run via `swift test --disable-sandbox --package-path Packages/AudioPipeline`): deterministic logic in `AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests`. The `--disable-sandbox` flag is required because SwiftPM's manifest compilation would otherwise call `sandbox_apply` and hit the nested-sandbox blocker; with the flag the suite runs inside the Claude Code sandbox without further workarounds.
- **App-hosted XCTest** (`audio-pipelineTests` target): integration smoke for code that needs a real audio device, the TCC private SPI, or a running `NSApp`. Run via `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test`, or from Xcode (⌘U). The daemon runs `xcodebuild` outside the sandbox so the codesign path works — verified end-to-end (compile → codesign → launch → run → coverage).

The SPM scaffolding script for adding new library products is `scripts/run-setup-spm-package.sh <ProductName>`.

**After SPM tests pass, always rebuild the app target** to confirm the app still compiles: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build` (via the xcode-build skill's daemon). `swift test` only compiles the SPM package, not the app target, so a green SPM suite is not proof the app builds.

## Project structure quirks

- **`PBXFileSystemSynchronizedRootGroup`**: the `audio-pipeline/` source folder is declared as a synchronized group in `project.pbxproj`. New `.swift` files dropped into `audio-pipeline/` (or its subfolders) are automatically picked up by Xcode — no need to edit the pbxproj to register them. Subfolders become groups automatically. The synchronized group's folder (`audio-pipeline/`) and the package source folders (`Packages/AudioPipeline/Sources/`) deliberately do not overlap — see `docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md` §4.
- **Default actor isolation is `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Types and functions are implicitly `@MainActor` unless explicitly annotated otherwise (e.g. `nonisolated`, `@globalActor`-typed, or moved to a background actor). Keep this in mind when adding audio code, which typically needs to run off the main thread — explicitly opt out with `nonisolated` or a dedicated actor.
- **App Sandbox is on** (`ENABLE_APP_SANDBOX = YES`) with `ENABLE_USER_SELECTED_FILES = readonly`. Any audio file I/O beyond user-selected reads will require adding entitlements (microphone, audio input, file read/write scopes) — the entitlements file does not yet exist and will need to be created and wired into `INFOPLIST` / build settings when needed.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` are enabled — concurrency diagnostics are strict.

## Tooling

### `swift-modules-and-gotchas.md`

Project-specific cheatsheet of every framework this app uses (Core Audio tap, AVAudioEngine, MenuBarExtra, Keychain, SQLite, Carbon hotkey, Accessibility, etc.) and the traps to watch for under strict concurrency and App Sandbox. Tagged `[M1]/[M2]/[M4]` so you can skip what isn't yet in scope. Read it before adding code in a new module area.

### `apple-docs` CLI

Local snapshot of Apple developer documentation: DocC reference, Human Interface Guidelines, Swift Evolution, App Store Review Guidelines, plus six more sources. Data lives at `~/.apple-docs/`. Prefer this over `find-docs` (Context7) for Apple-platform queries — the corpus covers HIG and Swift Evolution, which Context7 does not.

```bash
apple-docs search "AVAudioEngine"                       # search by term or symbol
apple-docs read AVAudioEngine --framework avfoundation  # full page
apple-docs browse coreaudio                              # framework topic tree
apple-docs --help                                        # full command list
```
Add `--json` for scripted/parseable output.
