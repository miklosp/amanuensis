# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS SwiftUI app, freshly scaffolded by Xcode 26.5. Bundle identifier `work.miklos.audio-pipeline`, deployment target macOS 26.3, Swift 5.0. The current source (`audio_pipelineApp.swift`, `ContentView.swift`) is the default Xcode "Hello, world!" template — no audio-pipeline functionality has been implemented yet.

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

To launch the built app: `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`. For interactive development, opening the `.xcodeproj` in Xcode and using ⌘R is faster.

## Tests

No test target is configured. If you need to add tests, create a new unit/UI test target in Xcode — do not hand-edit `project.pbxproj` to add one.

## Project structure quirks

- **`PBXFileSystemSynchronizedRootGroup`**: the `audio-pipeline/` source folder is declared as a synchronized group in `project.pbxproj`. New `.swift` files dropped into `audio-pipeline/` (or its subfolders) are automatically picked up by Xcode — no need to edit the pbxproj to register them. Subfolders become groups automatically.
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

Scoped to this repo, not installed globally. `xcodebuildmcp-cli` lives in `.claude/skills/`; the three plugins are enabled in `.claude/settings.json`, which also declares the two AvdLee marketplaces so a fresh clone can resolve them. A Claude Code restart is needed after cloning for the plugins to load.

- **`xcodebuildmcp-cli` skill** — wraps `xcodebuild` build/test/run, simulator/device control, log streaming, and UI automation. Use this for build artefacts and test runs instead of hand-assembling `xcodebuild` invocations. The build snippets in the "Build & run" section above are for human use.
- **`swiftui-expert@swiftui-expert-skill`** — SwiftUI best-practice guidance: state management, view composition, performance (lists, scrolling, navigation), Swift Charts, animation, macOS-specific patterns, accessibility, Instruments trace analysis. Reach for it whenever you're laying out new SwiftUI views or troubleshooting view performance.
- **`swift-concurrency@swift-concurrency-agent-skill`** — Swift 6 concurrency guidance: actors, async/await, AsyncSequence, Sendable conformance, task lifecycle, testing concurrent code, Swift 6 migration. This project's strict concurrency settings make it the right reference for every audio-thread, actor-isolation, or `@Sendable` question — pair it with `[[swift-modules-and-gotchas.md]]` for the project-specific traps.
- **`swift-lsp@claude-plugins-official`** — SourceKit-LSP wrapper for Swift code intelligence (jump-to-def, diagnostics, hover) inside Claude Code. Attaches to `.swift` files automatically once Claude Code is restarted after install.

Manage with `claude plugin list`, `claude plugin enable/disable <name>`, `claude plugin update <name>`. Add new sources repo-locally with `claude plugin marketplace add <owner/repo> --scope project` and `claude plugin install <plugin> --scope project` (both default to user scope otherwise).
