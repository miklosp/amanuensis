# CLAUDE.md

macOS SwiftUI app named **Amanuensis** (bundle identifier `work.miklos.amanuensis`), deployment target macOS 26.3, Swift 6.2. The app ships as *Amanuensis* — display name and `Amanuensis.app` come from `PRODUCT_NAME`. The Xcode project, target, and scheme are all named `Amanuensis` too; only the internal SPM package and its modules keep the original `AudioPipeline*` names (deliberately — that's the implementation library, e.g. `import AudioPipelineJobs`). The git repo directory is still `audio-pipeline/` (cosmetic only). M1 (menu-bar recorder, mic + system audio capture via Core Audio process tap, FLAC conversion) is complete. Source for the audio + storage + settings layers lives in a local SPM umbrella package at `Packages/AudioPipeline/`; the app target keeps UI, the app entry point, and `AppCoordinator` as the composition root.

## Build & run

There is no Xcode workspace, only the `.xcodeproj`. Standard Xcode toolchain:

```bash
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis clean
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR
```
To launch the built app: `open <BUILT_PRODUCTS_DIR>/Amanuensis.app`. For interactive development, opening the `.xcodeproj` in Xcode and using ⌘R is faster.

## Tests

Two test surfaces:

- **SPM tests** (autonomous, run via `swift test --package-path Packages/AudioPipeline`): deterministic logic across the package's Swift Testing suites (`AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests`, …).
- **App-hosted XCTest** (`AmanuensisTests` target): integration smoke for code that needs a real audio device, the TCC private SPI, or a running `NSApp`. Run from Xcode (⌘U), or `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' test`. It codesigns and launches the app, so it has to run on a real macOS session (compile → codesign → launch → run → coverage).

The SPM scaffolding script for adding new library products is `scripts/run-setup-spm-package.sh <ProductName>`.

**After SPM tests pass, always rebuild the app target** to confirm the app still compiles: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`. `swift test` only compiles the SPM package, not the app target, so a green SPM suite is not proof the app builds.

## Project structure quirks

- **`PBXFileSystemSynchronizedRootGroup`**: the `Amanuensis/` source folder is declared as a synchronized group in `project.pbxproj` (`path = Amanuensis`). New `.swift` files dropped into `Amanuensis/` (or its subfolders) are automatically picked up by Xcode — no need to edit the pbxproj to register them. Subfolders become groups automatically. The synchronized group's folder (`Amanuensis/`) and the package source folders (`Packages/AudioPipeline/Sources/`) deliberately do not overlap — see `docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md` §4.
- **Default actor isolation is `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Types and functions are implicitly `@MainActor` unless explicitly annotated otherwise (e.g. `nonisolated`, `@globalActor`-typed, or moved to a background actor). Keep this in mind when adding audio code, which typically needs to run off the main thread — explicitly opt out with `nonisolated` or a dedicated actor.
- **App Sandbox is on** (`ENABLE_APP_SANDBOX = YES`) with `ENABLE_USER_SELECTED_FILES = readwrite`. Entitlements live in `Amanuensis/Amanuensis.entitlements` (App Sandbox, network client, audio input, Music read/write); the user-selected-files scope is injected by the build setting rather than the entitlements plist. See `docs/permissions.md` for the full breakdown.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` are enabled — concurrency diagnostics are strict.

## Tooling

### `docs/swift-modules-and-gotchas.md`

Project-specific cheatsheet of every framework this app uses (Core Audio tap, AVAudioEngine, MenuBarExtra, Keychain, SQLite, Carbon hotkey, Accessibility, etc.) and the traps to watch for under strict concurrency and App Sandbox. Tagged `[M1]/[M2]/[M4]` so you can skip what isn't yet in scope. Read it before adding code in a new module area.
