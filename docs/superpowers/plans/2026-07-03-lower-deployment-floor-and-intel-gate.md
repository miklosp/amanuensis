# Lower Deployment Floor to macOS 14.4 + Gate Local Models to Apple Silicon — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lower the app's minimum macOS from 26.3 to 14.4, branch the macOS-26 Liquid Glass UI to a plain fallback, replace two macOS-15-only SwiftUI APIs, and hide on-device transcription models on Intel / ANE-less Macs.

**Architecture:** The macOS-26 dependency is a small, mostly-centralized UI surface. Add availability branches in one seam file (`GlassPanel.swift`) plus two overlay-view API swaps, add a hardware-capability flag (`LocalModelSupport`) that every local-model UI surface consults, then flip the deployment floor last so the recompile at 14.4 is the authoritative stray-API sweep. Tasks 1–4 each keep the app building at the current 26.3 target; Task 5 lowers the floor.

**Tech Stack:** Swift 6.2, SwiftUI, SPM (local `AudioPipeline` package), Xcode project `Amanuensis.xcodeproj`, Swift Testing.

## Global Constraints

_Every task's requirements implicitly include this section._

- **Deployment floor = macOS 14.4**, applied in two places: `Amanuensis.xcodeproj/project.pbxproj` (`MACOSX_DEPLOYMENT_TARGET = 14.4`, 4 configs) and `Packages/AudioPipeline/Package.swift` (`platforms: [.macOS("14.4")]` — **keep the string form**, `.v14` cannot express `.4`).
- **Dependency floors already compatible:** WhisperKit `.macOS(.v13)`, FluidAudio `.macOS(.v14)`. Do not touch them.
- **No `@available` guards on the audio path.** The 14.2 process-tap / per-process-HAL symbols in `RecordingCore/ProcessTapRecorder.swift` and `RecordingCore/OtherInputActivityMonitor.swift` are always available at a 14.4 floor. Do **not** add guards there.
- **Glass branch = `if #available(macOS 26, *)`**, fallback `.ultraThinMaterial` for tiles/backgrounds and `.borderedProminent` for prominent buttons. All branching lives in `Amanuensis/UI/GlassPanel.swift`.
- **Intel gate = hide, don't fall back.** Local-model surfaces consult `LocalModelSupport.isSupported`; on Intel they are absent. No cloud auto-routing. Only a defensive `runJob` failure for stray `.local` jobs.
- **Local engines (post-merge of PR #22, now on `main`):** three — FluidAudio, WhisperKit, and IndicConformer — with 7 catalog models and a 5-case `LocalRunner`. All are ANE/Core ML and unusable on Intel, so the Intel gate (Task 4) covers them uniformly through the shared catalog / `downloadedLocalIDs` — no per-engine gating. `IndicConformerEngine()` stays constructed unconditionally in `AppCoordinator` (a cheap actor init; Core ML models load lazily), which is harmless on Intel. IndicConformer uses only `CoreML`/`Accelerate` (both present on x86_64), so it does not raise the compile floor.
- **Warnings are not errors** in this project; transient "unnecessary `#available`" warnings on Tasks 2–4 (target still 26.3) are expected and clear at Task 5.
- **Build/test environment (sandbox):**
  - SPM tests run in-sandbox: `swift test --disable-sandbox --package-path Packages/AudioPipeline`.
  - App builds route through the Hammerspoon daemon helper: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`. The helper is gitignored and **absent from this worktree** — Task 2 copies it in from the main checkout. If the daemon cannot target the worktree path, open the worktree's `Amanuensis.xcodeproj` in Xcode and ⌘B instead.
- **Unverifiable in-sandbox:** process-tap behavior on real macOS 14.4 hardware, and the Intel runtime UI-hide (no Intel machine). Both are documented caveats, not blockers. A DEBUG env override (`AMANUENSIS_FORCE_NO_LOCAL=1`, added in Task 1) lets the Intel UI-hide be exercised on Apple Silicon.

---

### Task 1: `LocalModelSupport` hardware-capability flag

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelSupport.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelSupportTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum LocalModelSupport { public static let isSupported: Bool }` in module `LocalTranscription`. `true` on Apple Silicon, `false` on Intel. Later tasks import `LocalTranscription` and read `LocalModelSupport.isSupported`.

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelSupportTests.swift`:

```swift
import Testing
@testable import LocalTranscription

@Suite struct LocalModelSupportTests {
    // Ties the runtime sysctl result to the architecture the test binary was
    // compiled for: Apple Silicon (arm64 slice) supports local models; Intel
    // (x86_64 slice) does not. Deterministic on any native run.
    @Test func matchesRunningArchitecture() {
        #if arch(arm64)
        #expect(LocalModelSupport.isSupported == true)
        #else
        #expect(LocalModelSupport.isSupported == false)
        #endif
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelSupportTests`
Expected: FAILS TO COMPILE — `cannot find 'LocalModelSupport' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelSupport.swift`:

```swift
import Darwin
import Foundation

/// Whether this Mac can run the on-device transcription models. The engines
/// (FluidAudio, WhisperKit, IndicConformer) are tuned for the Apple Neural
/// Engine and are unusably slow — or fail to load — on Intel. Gate every
/// local-model surface on this so Intel machines never see, download, or
/// select local models.
public enum LocalModelSupport {
    /// `true` on Apple Silicon (Neural Engine present), `false` on Intel.
    /// Reads the hardware capability via sysctl, so it is correct regardless of
    /// which binary slice is executing (Intel slice, or arm64 under Rosetta).
    public static let isSupported: Bool = hasAppleSilicon()

    private static func hasAppleSilicon() -> Bool {
        #if DEBUG
        // Verification aid: simulate an Intel Mac on Apple Silicon by launching
        // with AMANUENSIS_FORCE_NO_LOCAL set, to confirm the local UI hides.
        if ProcessInfo.processInfo.environment["AMANUENSIS_FORCE_NO_LOCAL"] != nil {
            return false
        }
        #endif
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelSupportTests`
Expected: PASS (on the Apple Silicon dev machine: `isSupported == true`).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModelSupport.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelSupportTests.swift
git commit -m "feat(local): LocalModelSupport hardware-capability flag (Apple Silicon gate)"
```

---

### Task 2: Centralize glass branching in `GlassPanel.swift`

Rewrites the glass seam to branch on macOS 26, routes the one direct `glassEffect` call and the four `.glassProminent` buttons through it. Keeps the build green at the current 26.3 target (both branches compile regardless of target).

**Files:**
- Modify: `Amanuensis/UI/GlassPanel.swift` (whole file)
- Modify: `Amanuensis/UI/Sidebar/SidebarActivityBar.swift:20`
- Modify: `Amanuensis/UI/Jobs/JobEditorView.swift:119` and `:185`
- Modify: `Amanuensis/UI/Jobs/JobsView.swift:45`
- Modify: `Amanuensis/UI/Providers/ProviderEditorView.swift:71`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (all `extension View` in `GlassPanel.swift`):
  - `func glassTile(in shape: some InsettableShape) -> some View` (existing name, reworked internally)
  - `func glassBackground(in shape: some Shape) -> some View` (new)
  - `func glassProminentButtonStyle() -> some View` (new)

- [ ] **Step 1: Copy the build helper into the worktree (one-time setup)**

```bash
cp /Users/miklos/Code/audio-pipeline/scripts/xcode-build-helper.sh scripts/ 2>/dev/null
cp /Users/miklos/Code/audio-pipeline/scripts/log-helper.sh scripts/ 2>/dev/null
chmod +x scripts/xcode-build-helper.sh scripts/log-helper.sh
```
(These are gitignored — they will not appear in `git status`. If the main checkout lacks them, restore from history: `git show bb9c56b^:scripts/xcode-build-helper.sh`.)

- [ ] **Step 2: Rewrite `GlassPanel.swift`**

Replace the entire contents of `Amanuensis/UI/GlassPanel.swift` with:

```swift
import SwiftUI

extension View {
    /// A Control Center-style glass tile: adaptive frosted glass with a
    /// pointer-reactive surface and a bright specular rim, shared by the
    /// floating HUDs (mic cue, dictation overlay). Liquid Glass on macOS 26+,
    /// a frosted `.ultraThinMaterial` fallback below. Pair with adaptive
    /// `.primary` / `.secondary` foreground styles so text contrast follows the
    /// same appearance signal the tile does.
    ///
    /// This file is the single seam for the glass treatment: the
    /// `if #available(macOS 26, *)` branches live here only.
    func glassTile(in shape: some InsettableShape) -> some View {
        modifier(GlassTile(shape: shape))
    }

    /// A plain Liquid Glass background: `.glassEffect(.regular, in:)` on macOS
    /// 26+, `.ultraThinMaterial` below. Used by the sidebar activity bar.
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Prominent action-button style: `.glassProminent` on macOS 26+,
    /// `.borderedProminent` below.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private struct GlassTile<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        tile(content)
            .overlay {
                // The bright specular rim a Control Center tile has; brightest
                // along the top edge, fading toward the bottom.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
    }

    @ViewBuilder
    private func tile(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    // Dark wash in dark mode, light wash in light mode, so the tile stays a
    // legible card and the adaptive text always has contrast.
    private var tint: Color {
        colorScheme == .dark ? .black.opacity(0.4) : .white.opacity(0.35)
    }
}
```

- [ ] **Step 3: Route the direct `glassEffect` call through the seam**

In `Amanuensis/UI/Sidebar/SidebarActivityBar.swift`, replace line 20:

```swift
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
```

with:

```swift
            .glassBackground(in: .rect(cornerRadius: 9))
```

- [ ] **Step 4: Route the four prominent buttons through the seam**

There are four call sites — `JobEditorView.swift:119` and `:185`, `JobsView.swift:45`, `ProviderEditorView.swift:71` — each a line reading `.buttonStyle(.glassProminent)` (indentation varies). Replace the token uniformly across just those three files (this leaves the seam's own `.glassProminent` in `GlassPanel.swift` untouched):

```bash
sed -i '' 's/\.buttonStyle(\.glassProminent)/.glassProminentButtonStyle()/' \
  Amanuensis/UI/Jobs/JobEditorView.swift \
  Amanuensis/UI/Jobs/JobsView.swift \
  Amanuensis/UI/Providers/ProviderEditorView.swift
```

Each replaced site now reads (indentation preserved by `sed`):

```swift
                    .glassProminentButtonStyle()
```

- [ ] **Step 5: Verify no `.glassEffect` / `.glassProminent` / bare `Glass` remains outside the seam**

Run: `rg -n 'glassEffect|glassProminent|\bGlass\b' Amanuensis --type swift`
Expected: matches ONLY inside `Amanuensis/UI/GlassPanel.swift`. No hits in any other file.

- [ ] **Step 6: Build the app target (still at 26.3) to confirm both branches compile**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`. (The `.ultraThinMaterial` / `.borderedProminent` fallback branches are type-checked even though the 26.3 target never runs them.)

- [ ] **Step 7: Commit**

```bash
git add Amanuensis/UI/GlassPanel.swift Amanuensis/UI/Sidebar/SidebarActivityBar.swift \
        Amanuensis/UI/Jobs/JobEditorView.swift Amanuensis/UI/Jobs/JobsView.swift \
        Amanuensis/UI/Providers/ProviderEditorView.swift
git commit -m "refactor(ui): branch Liquid Glass through GlassPanel seam (glass on 26+, material below)"
```

---

### Task 3: Replace the two macOS-15-only SwiftUI APIs

**Files:**
- Modify: `Amanuensis/UI/CueCard.swift:58` (+ a constant)
- Modify: `Amanuensis/UI/DictationOverlayView.swift:40`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: no new public symbols. Behavior preserved.

- [ ] **Step 1: Replace `Color.mix` in `CueCard.swift`**

In `Amanuensis/UI/CueCard.swift`, add a constant just after the stored properties (after line 16, `let onDismiss: () -> Void`):

```swift

    // Red lightened ~45% toward white. Was `Color.red.mix(with: .white, by: 0.45)`
    // (macOS 15+); this precomputed sRGB constant keeps the pulse highlight
    // essentially identical below the deployment floor.
    private static let pulseRed = Color(red: 1.0, green: 0.45, blue: 0.45)
```

Then replace line 58:

```swift
                .background(pulse ? Color.red.mix(with: .white, by: 0.45) : .red, in: Circle())
```

with:

```swift
                .background(pulse ? Self.pulseRed : .red, in: Circle())
```

- [ ] **Step 2: Replace `onGeometryChange` in `DictationOverlayView.swift`**

In `Amanuensis/UI/DictationOverlayView.swift`, replace line 40:

```swift
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
```

with:

```swift
            .background {
                // Pre-macOS-15 size reporting: a background GeometryReader
                // doesn't affect the pill's layout, and `.onChange` fires on the
                // main actor as the animated width changes. Replaces the macOS-15
                // `.onGeometryChange`.
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size, initial: true) { _, newSize in
                            onResize(newSize)
                        }
                }
            }
```

- [ ] **Step 3: Verify no macOS-15 APIs remain**

Run: `rg -n 'onGeometryChange|\.mix\(with:' Amanuensis --type swift`
Expected: no matches.

- [ ] **Step 4: Build the app target to confirm it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/CueCard.swift Amanuensis/UI/DictationOverlayView.swift
git commit -m "refactor(ui): replace macOS-15 Color.mix and onGeometryChange with 14-compatible equivalents"
```

---

### Task 4: Gate local-model surfaces on `LocalModelSupport.isSupported`

Hides every local-model UI surface on Intel and adds a defensive `runJob` failure for stray `.local` jobs.

**Files:**
- Modify: `Amanuensis/UI/MainWindowView.swift` (add import + gate sidebar label)
- Modify: `Amanuensis/UI/Jobs/JobEditorView.swift:66-68` (`downloadedLocalIDs`)
- Modify: `Amanuensis/UI/Dictation/DictationView.swift:79-81` (`downloadedLocalIDs`)
- Modify: `Amanuensis/UI/Jobs/JobsView.swift:30-32` (`hasLocalModel`)
- Modify: `Amanuensis/AppCoordinator.swift:366-368` (`runJob` `.local` branch) and `:616-620` (`JobRunError`)

**Interfaces:**
- Consumes: `LocalModelSupport.isSupported: Bool` from Task 1 (module `LocalTranscription`).
- Produces: `JobRunError.localModelUnsupported` (new case, private to `AppCoordinator`).

- [ ] **Step 1: Gate the sidebar destination in `MainWindowView.swift`**

Add the import — replace line 1:

```swift
import SwiftUI
```

with:

```swift
import LocalTranscription
import SwiftUI
```

Then replace the "Local Models" label (lines 20–21):

```swift
                Label("Local Models", systemImage: "cpu")
                    .tag(SidebarDestination.localModels)
```

with:

```swift
                if LocalModelSupport.isSupported {
                    Label("Local Models", systemImage: "cpu")
                        .tag(SidebarDestination.localModels)
                }
```

(Leave the `case .localModels:` detail branch at lines 49–50 unchanged — the enum case stays; it is simply unreachable via the sidebar on Intel.)

- [ ] **Step 2: Gate `downloadedLocalIDs` in `JobEditorView.swift`**

Replace lines 66–68:

```swift
    private var downloadedLocalIDs: [String] {
        LocalModelCatalog.all.map(\.id).filter { localModelsStore.states[$0]?.isDownloaded == true }
    }
```

with:

```swift
    private var downloadedLocalIDs: [String] {
        guard LocalModelSupport.isSupported else { return [] }
        return LocalModelCatalog.all.map(\.id).filter { localModelsStore.states[$0]?.isDownloaded == true }
    }
```

(`JobEditorView.swift` already `import LocalTranscription` at line 3. Empty `downloadedLocalIDs` hides the "Local" picker option at lines 106–108 and 135–137 and empties the `ModelSelector` local list.)

- [ ] **Step 3: Gate `downloadedLocalIDs` in `DictationView.swift`**

Replace lines 79–81:

```swift
    private var downloadedLocalIDs: [String] {
        LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
    }
```

with:

```swift
    private var downloadedLocalIDs: [String] {
        guard LocalModelSupport.isSupported else { return [] }
        return LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
    }
```

(`DictationView.swift` already `import LocalTranscription` at line 4. Hides the "Local" dictation-provider option at lines 47–49.)

- [ ] **Step 4: Gate `hasLocalModel` in `JobsView.swift`**

Replace lines 30–32:

```swift
    private var hasLocalModel: Bool {
        LocalModelCatalog.all.contains { localModelsStore.states[$0.id]?.isDownloaded == true }
    }
```

with:

```swift
    private var hasLocalModel: Bool {
        LocalModelSupport.isSupported
            && LocalModelCatalog.all.contains { localModelsStore.states[$0.id]?.isDownloaded == true }
    }
```

(`JobsView.swift` already `import LocalTranscription` at line 2.)

- [ ] **Step 5: Add the defensive guard + error case in `AppCoordinator.swift`**

Replace the `.local` branch (lines 366–368):

```swift
        case .local:
            provider = Provider.localPlaceholder
            shape = .localTranscription
```

with:

```swift
        case .local:
            guard LocalModelSupport.isSupported else {
                await self.flashActivity("Failed: '\(job.name)' — local models require an Apple Silicon Mac")
                logs.log(.error, "Failed: '\(job.name)' — local models require an Apple Silicon Mac", category: .job)
                return .failure(JobRunError.localModelUnsupported)
            }
            provider = Provider.localPlaceholder
            shape = .localTranscription
```

Then add the error case — replace lines 616–620:

```swift
    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
        case presetMissing
        case outputFolderAccessDenied
```

with:

```swift
    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
        case presetMissing
        case outputFolderAccessDenied
        case localModelUnsupported
```

(`AppCoordinator.swift` already `import LocalTranscription` at line 7. Do not change the closing brace or other cases of the enum.)

- [ ] **Step 6: Build the app target to confirm it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify the Intel-hide behavior on Apple Silicon via the DEBUG override**

Find the built app and launch it with the override, then confirm no local-model UI appears (no "Local Models" sidebar item; no "Local" option in the Jobs or Dictation provider pickers):

```bash
APP=$(./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | tail -1)
AMANUENSIS_FORCE_NO_LOCAL=1 open -n "$APP/Amanuensis.app"
```
Expected: the app launches with all local-model surfaces hidden. Quit it, relaunch normally (`open "$APP/Amanuensis.app"`), and confirm the local-model surfaces return.

- [ ] **Step 8: Commit**

```bash
git add Amanuensis/UI/MainWindowView.swift Amanuensis/UI/Jobs/JobEditorView.swift \
        Amanuensis/UI/Dictation/DictationView.swift Amanuensis/UI/Jobs/JobsView.swift \
        Amanuensis/AppCoordinator.swift
git commit -m "feat(local): hide local-model surfaces on Intel via LocalModelSupport gate"
```

---

### Task 5: Lower the deployment floor to 14.4 (authoritative recompile sweep)

**Files:**
- Modify: `Packages/AudioPipeline/Package.swift:17`
- Modify: `Amanuensis.xcodeproj/project.pbxproj` (4 × `MACOSX_DEPLOYMENT_TARGET`)

**Interfaces:**
- Consumes: the guards/replacements from Tasks 2–4.
- Produces: the shipped 14.4 floor.

- [ ] **Step 1: Lower the SPM package platform**

In `Packages/AudioPipeline/Package.swift`, replace line 17:

```swift
    platforms: [.macOS("26.3")],
```

with:

```swift
    platforms: [.macOS("14.4")],
```

- [ ] **Step 2: Run the full SPM suite at the new floor**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -30`
Expected: the deterministic suites pass, including `LocalModelSupportTests`. (The package has no macOS-26 APIs, so this must stay green.) The merged IndicConformer e2e/integration tests are **gated** — they skip (or no-op) when their model/FLEURS fixtures are absent, which is the normal state here; do not treat skipped gated tests as failures. If any deterministic (non-gated) suite regresses, it is unrelated to the platform change and should be investigated separately.

- [ ] **Step 3: Lower the Xcode deployment target (all 4 configs)**

Run:

```bash
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 26.3;/MACOSX_DEPLOYMENT_TARGET = 14.4;/g' Amanuensis.xcodeproj/project.pbxproj
rg -n 'MACOSX_DEPLOYMENT_TARGET' Amanuensis.xcodeproj/project.pbxproj
```
Expected: all four lines now read `MACOSX_DEPLOYMENT_TARGET = 14.4;` and no `26.3` remains. (`LSMinimumSystemVersion` is derived from this setting automatically — no Info.plist edit needed.)

- [ ] **Step 4: Recompile the app at 14.4 — the authoritative stray-API sweep**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build 2>&1 | tail -60`
Expected: `** BUILD SUCCEEDED **`.

If instead the build reports an error like `'someAPI' is only available in macOS X.Y or newer`, that is a too-new API the inventory missed. For each: wrap the site in `if #available(macOS 26, *) { … } else { <14.4 fallback> }` (for a glass/26 API, route it through the `GlassPanel.swift` seam), or replace it with a 14.4-compatible equivalent, then rebuild. Repeat until the build succeeds. This recompile — not the inventory — is the definitive check.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Package.swift Amanuensis.xcodeproj/project.pbxproj
git commit -m "build: lower deployment floor to macOS 14.4"
```

- [ ] **Step 6: Update the deferred research note's status**

In `docs/lower-deployment-target.md`, replace the status line (lines 10–11):

```markdown
**Status: deferred.** Captured 2026-06-27 as a potential future improvement. The
glass-HUD polish proceeds independently at the 26.3 target.
```

with:

```markdown
**Status: done (2026-07-03).** Implemented per
`docs/superpowers/specs/2026-07-03-lower-deployment-floor-and-intel-gate-design.md`.
Floor lowered to 14.4; Liquid Glass branched via the `GlassPanel.swift` seam; two
macOS-15 APIs replaced; local models gated to Apple Silicon.
```

- [ ] **Step 7: Commit**

```bash
git add docs/lower-deployment-target.md
git commit -m "docs: mark deployment-floor lowering done"
```

---

## Residual manual verification (post-implementation, not blocking)

- **Real macOS 14.4 hardware:** launch the app on a 14.4 machine/VM and record system audio + mic; confirm the process tap and per-process mic cue work, and that glass surfaces render as `.ultraThinMaterial` (no Liquid Glass). This is the actual risk of the lowering and cannot be checked in-sandbox.
- **A real Intel Mac (optional):** confirm the app launches (universal binary) and shows no local-model UI. Approximated on Apple Silicon by Task 4 Step 7's DEBUG override.
