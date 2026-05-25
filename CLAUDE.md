# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS SwiftUI app. Bundle identifier `work.miklos.audio-pipeline`, deployment target macOS 26.3, Swift 6.2. M1 (menu-bar recorder, mic + system audio capture via Core Audio process tap, FLAC conversion) is complete. Source for the audio + storage + settings layers lives in a local SPM umbrella package at `Packages/AudioPipeline/`; the app target keeps UI, the app entry point, and `AppCoordinator` as the composition root.

## Build & run

There is no Xcode workspace, only the `.xcodeproj`. Use `xcodebuild` from the repo root:

```bash
# Debug build for the host Mac
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build

# Clean
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline clean

# Locate the built .app (Debug)
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -showBuildSettings | rg '^\s+BUILT_PRODUCTS_DIR'
```

From inside the Claude Code sandbox, add `-derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox` — see [[build-location-icloud]] for why.

To launch the built app: `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`. For interactive development, opening the `.xcodeproj` in Xcode and using ⌘R is faster.

## Tests

Two test surfaces:

- **SPM tests** (autonomous, run via `swift test --disable-sandbox --package-path Packages/AudioPipeline`): deterministic logic in `AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests`. The `--disable-sandbox` flag is required because SwiftPM's manifest compilation would otherwise call `sandbox_apply` and hit the nested-sandbox blocker; with the flag the suite runs inside the Claude Code sandbox without further workarounds.
- **App-hosted XCTest** (`audio-pipelineTests` target, Xcode-scoped): integration smoke for code that needs a real audio device, the TCC private SPI, or a running `NSApp`. Run from Xcode (⌘U) or `xcodebuild test`. The latter currently hits the codesign-in-nested-sandbox blocker described in `~/.claude/projects/-Users-miklos-Code-audio-pipeline/memory/project_xcodebuild_test_sandbox.md`.

The SPM scaffolding script for adding new library products is `scripts/run-setup-spm-package.sh <ProductName>`.

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
apple-docs frameworks                                    # list framework roots
apple-docs status                                        # corpus stats
apple-docs --help                                        # full command list
```

Add `--json` for scripted/parseable output.

**Sandbox caveat:** running `apple-docs` from inside the Claude Code sandbox currently fails with `EPERM reading "/Users/miklos/.bun/bin/apple-docs"` because the symlink target under `~/.bun/install/` is outside the writable list. Until `~/.bun` is added to the writable sandbox paths, run `apple-docs` from a regular terminal and paste results into the conversation.

### Skills & plugins (Claude Code, project scope)

Project-scoped — declared in this repo, not in your global Claude Code setup. Two delivery mechanisms:

- **Local skills** are folders in `.claude/skills/`. Vendored skills travel with the repo on `git clone` and need no restart. The six `swift*`/`swiftui*` skills below are *not* vendored (gitignored) — clone them from [Dimillian/Skills](https://github.com/Dimillian/Skills) into `.claude/skills/` yourself.
- **Plugins** are enabled in `.claude/settings.json`, which also declares the `swiftui-expert-skill` marketplace so a fresh clone can resolve it. Plugin code is fetched from the marketplace on clone; a Claude Code restart is then needed for plugins to load.

**Local skills (`.claude/skills/`)**

- **`swift-state-machine`** — build type-safe Swift state machines with enum states and action-based transitions. Use for lifecycle/protocol flows, reentrancy-sensitive operations, or async/concurrent workflows.
- **`swift-concurrency-expert`** — Swift 6.2+ concurrency review and remediation: Sendable conformance, `@MainActor` annotations, actor-isolation warnings, data-race diagnostics, completion-handler → async/await migration.
- **`swiftui-liquid-glass`** — implement, review, or improve SwiftUI features using the iOS 26+ Liquid Glass API.
- **`swiftui-performance-audit`** — diagnose slow rendering, janky scrolling, excessive view updates, and layout thrash from code review; guides user-run Instruments profiling when needed.
- **`swiftui-ui-patterns`** — example-driven SwiftUI view/component patterns (navigation, view modifiers, stacks/grids); ships 30+ topic docs under `references/`.
- **`swiftui-view-refactor`** — refactor SwiftUI view files toward small dedicated subviews, MV-over-MVVM data flow, stable view trees, and correct Observation usage.

The five `swift*`/`swiftui*` skills above are from [Dimillian/Skills](https://github.com/Dimillian/Skills). The four `swiftui-*` ones overlap the `swiftui-expert` plugin below — both are available; pick whichever fits the task.

**Plugins (`.claude/settings.json`)**

- **`swiftui-expert@swiftui-expert-skill`** — SwiftUI best-practice guidance: state management, view composition, performance (lists, scrolling, navigation), Swift Charts, animation, macOS-specific patterns, accessibility, Instruments trace analysis. Reach for it whenever you're laying out new SwiftUI views or troubleshooting view performance.
- **`swift-lsp@claude-plugins-official`** — SourceKit-LSP wrapper for Swift code intelligence (jump-to-def, diagnostics, hover) inside Claude Code. Attaches to `.swift` files automatically once Claude Code is restarted after install.

`enabledPlugins` also carries `false` overrides for `frontend-design` and `ui-ux-pro-max` — global (user-scoped) plugins switched off for this repo as irrelevant to a native macOS app.

**Disabled skills (`skillOverrides` in `.claude/settings.json`)**

`agent-browser`, `firecrawl-scrape`, `tui-design-skill`, and `writing-for-humans` are set to `off` — globally-available skills with no bearing on a macOS SwiftUI app.

Manage with `claude plugin list`, `claude plugin enable/disable <name>`, `claude plugin update <name>`. Add new sources repo-locally with `claude plugin marketplace add <owner/repo> --scope project` and `claude plugin install <plugin> --scope project` (both default to user scope otherwise).
