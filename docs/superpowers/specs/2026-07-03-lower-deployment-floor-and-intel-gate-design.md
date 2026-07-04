# Lower deployment floor to macOS 14.4 + gate local models to Apple Silicon — design

**Date:** 2026-07-03
**Branch:** `worktree-feat+lower-deployment-floor` (off `main`)
**Scope:** Drop the app's minimum from macOS 26.3 to **14.4**, branch the macOS-26 Liquid Glass UI to a plain fallback, and hide on-device ("local") transcription models entirely on Intel / ANE-less Macs. No behavioural change on Apple Silicon at a supported OS; this widens the supported population and degrades gracefully outside it.

**Supersedes the research note** `docs/lower-deployment-target.md` (2026-06-27), which reached the same 14.4 conclusion but predates the local-model work and missed two macOS-15 APIs (see Component 3). That note stays as history; this spec is the actionable version.

## Goals

1. Lower `MACOSX_DEPLOYMENT_TARGET` and the SPM `platforms` floor from `26.3` to `14.4` — the lowest reachable without re-architecting audio capture.
2. Make every macOS-26 Liquid Glass site branch: glass on 26+, a plain material/plain-style fallback below. "Glass if available, basic overlay if not."
3. Replace the two macOS-15-only SwiftUI APIs so the code compiles at 14.4.
4. Gate on-device models on **Apple Silicon hardware**: Intel machines never see, download, or select local models. Cloud providers are unaffected and remain available everywhere.

## Non-goals

- **No capture rewrite.** Going below macOS 14.2 would mean replacing Core Audio process taps with a ScreenCaptureKit audio path — a separate, much larger project. 14.4 keeps the current capture architecture intact.
- **No CPU/whisper.cpp local backend for Intel.** A genuinely Intel-capable on-device engine is out of scope. Intel gets cloud transcription (already built), not a local fallback.
- **No auto-fallback-to-cloud routing.** Per decision: Intel simply doesn't offer local at all. There is no "local failed → retry on cloud" path.
- **No broader UI redesign.** UI work is limited to what lowering the floor requires (glass branching + two API swaps).

---

## Why 14.4 is the floor

The floor is set by **audio capture**, in two independent places, both currently unguarded:

1. **System-audio process tap** — `Packages/AudioPipeline/Sources/RecordingCore/ProcessTapRecorder.swift`: `CATapDescription`, `AudioHardwareCreateProcessTap`, `kAudioTapPropertyFormat`, the `kAudioAggregateDeviceTap*` keys, `AudioHardwareDestroyProcessTap`. All introduced **macOS 14.2**.
2. **Per-process mic-in-use detection** — `Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift`: `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`/`BundleID`/`IsRunningInput`. All **macOS 14.2**.

14.2–14.3 shipped process-tap bugs that real-world tap projects avoid by requiring **14.4**; the code's own comments already call 14.4 the practical floor. There is **no fallback recorder** (no AVAudioEngine/ScreenCaptureKit system-audio path). So 14.4 is the realistic minimum, and below 14.2 is impossible without the capture rewrite named in non-goals.

Everything else in the app is 14.0-era or older (Observation, `ContentUnavailableView`, `.symbolEffect`, `MenuBarExtra`, `NavigationSplitView`, `Table`, AVAudioEngine/AVAudioFile, CGEvent taps, the private TCC capture SPI) — all ≤14.0, no obstacle at 14.4.

**Dependency floors are compatible:** WhisperKit declares `.macOS(.v13)`, FluidAudio `.macOS(.v14)`. Neither blocks a 14.4 package floor.

---

## Component 1 — Deployment target 26.3 → 14.4

### Current state
- `Amanuensis.xcodeproj/project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET = 26.3` in four build configs (lines ~317/377/475/494). Test targets inherit or set their own.
- `Packages/AudioPipeline/Package.swift:17`: `platforms: [.macOS("26.3")]`.
- `ONLY_ACTIVE_ARCH = YES` in Debug only; no `ARCHS` restriction → **Release is universal (arm64 + x86_64) by default**, so Intel becomes a real target once the floor drops.

### Change
- Set `MACOSX_DEPLOYMENT_TARGET = 14.4` in all app-target configs and any test target that pins its own value.
- Set `platforms: [.macOS("14.4")]` in `Package.swift` — **keep the string form**; `.v14` cannot express the `.4`.

### Note
The recompile at 14.4 is the **authoritative sweep** for stray too-new APIs — it turns any remaining one into a hard compile error. The inventories in Components 2–3 are the first pass; the compiler is the backstop.

---

## Component 2 — Glass branching (macOS 26 → material/plain fallback)

### Current state
Liquid Glass appears at ~6 sites, mostly funneled through one seam file:

- `Amanuensis/UI/GlassPanel.swift` — `glassPanel(in:glass:)` (`:11-12`, wraps `.glassEffect`) and `glassTile(in:)` (`:21-49`). The shared Control-Center-style tile. Its own doc comment (`:8-10`) already flags that a sub-26 fallback belongs here.
- `Amanuensis/UI/CueCard.swift:39` — `.glassTile(in: Capsule())` (mic cue), via the seam.
- `Amanuensis/UI/DictationOverlayView.swift:37` — `.glassTile(in: Capsule())` (dictation HUD), via the seam.
- `Amanuensis/UI/Sidebar/SidebarActivityBar.swift:20` — `.glassEffect(.regular, in: .rect(cornerRadius: 9))` **called directly, not via the seam**.
- `.buttonStyle(.glassProminent)` at `ProviderEditorView.swift:71`, `JobsView.swift:45`, `JobEditorView.swift:119` and `:185`.

Both HUD overlays are AppKit `NSPanel`s hosting SwiftUI (`FloatingCueController.swift`, `DictationOverlayController.swift`) — the windows impose no floor; only the glass styling inside them does.

### Change
- **In `GlassPanel.swift`**, make `glassPanel`/`glassTile` `@ViewBuilder` and branch:
  - `if #available(macOS 26, *)` → current `.glassEffect(...)` path.
  - else → the same shape filled with `.ultraThinMaterial` (chosen for the HUD pills as the closest translucent analogue; tunable).
  Both HUDs inherit the fallback automatically through the seam.
- **Route `SidebarActivityBar.swift:20` through the seam** (or wrap it in the same `if #available` guard) so no glass call escapes the branch.
- **Add a `View` extension `glassProminentButton()`** that yields `.buttonStyle(.glassProminent)` on 26+, `.buttonStyle(.borderedProminent)` below; replace the four call sites with it. (A plain function returning `some ButtonStyle` can't branch types; a `@ViewBuilder` `View` extension can.)

### Result
One seam file owns all glass/no-glass branching; call sites stay readable; below 26 the app shows material HUDs and bordered-prominent buttons.

---

## Component 3 — Two macOS-15 API replacements

Both live in the overlay/cue UI and are the highest floor below the glass APIs (the old research note missed them).

- **`onGeometryChange(for:of:action:)`** — `Amanuensis/UI/DictationOverlayView.swift:40` (macOS 15). Replace with the pre-15 idiom: a `GeometryReader` in `.background` publishing through a `PreferenceKey`, consumed with `.onPreferenceChange`.
- **`Color.mix(with:by:)`** — `Amanuensis/UI/CueCard.swift:58` (`Color.red.mix(with: .white, by: 0.45)`, macOS 15). It's a fixed blend → replace with a precomputed constant `Color(red:green:blue:)` (or a small manual RGB-blend helper), matching the current appearance.

---

## Component 4 — Audio-path guards: deliberately none

The 14.2 symbols in `ProcessTapRecorder.swift` and `OtherInputActivityMonitor.swift` are unguarded today. At a **14.4 floor they are always available** (14.2 ≤ 14.4), so no `@available`/`#available` guards are required or wanted. We will **not** add dead guards. (Guards would only matter below 14.2, which non-goals exclude.)

---

## Component 5 — Intel / ANE-less gate for local models

### Current state
- Three ANE-oriented engines behind `LocalTranscriptionEngine` (FluidAudio/Parakeet-SenseVoice-Cohere, WhisperKit, IndicConformer). None reject Intel in code; all assume the Neural Engine for usable speed (FluidAudio most explicitly — its default configs select `.cpuAndNeuralEngine`). On Intel: CPU-only, unusably slow, and some ANE graphs may not load.
- **No arch/capability gating anywhere** (`#if arch`, `sysctl`, `isAppleSilicon` — zero hits repo-wide).
- Local is surfaced as a sentinel `TranscriptionSource.local` (`Packages/AudioPipeline/Sources/AudioPipelineJobs/TranscriptionSource.swift`) with `Provider.localID`. Cloud providers are real stored `Provider`s. UI surfaces: the Job-editor provider picker's `Text("Local")` option (`JobEditorView.swift:65-68,101-136`, already conditional on `downloadedLocalIDs` non-empty), the Models management views (`Amanuensis/UI/Models/{ModelSelector,ModelsView,ModelCardView}.swift`), and the Dictation model selector.
- Batch routing: `AppCoordinator.runJob` (`:361-382`) switches on `TranscriptionSource`; `.local` → `.localPlaceholder` + `JobShape.localTranscription`. On failure it logs and returns `.failure` — **no retry, no fallback** exists today.

### Change
- **Add one capability value** — e.g. `enum LocalModelSupport { static let isSupported: Bool }` — computed once from `sysctlbyname("hw.optional.arm64", ...)` returning `1`. This reads **hardware truth** (Apple Silicon → true, Intel → false), robust even under Rosetta, and gates on hardware rather than OS version, so an M1 on macOS 14.4 still gets local models. Preferred over `#if arch(arm64)` (compile-time per-slice, wrong under Rosetta translation).
  - Placement: a small type in the `LocalTranscription` module (or shared settings module) so both the package and app can read it.
- **Every local-model UI surface consults `isSupported` and hides when false:**
  - Job-editor "Local" picker option: gate its inclusion on `LocalModelSupport.isSupported` (in addition to the existing `downloadedLocalIDs` check).
  - Models management view: hide the local-models section/grid entirely on Intel — no catalog, no download UI.
  - Dictation model selector: hide local options.
  - On Intel there is nothing downloadable and nothing selectable.
- **Defensive floor only:** if migrated/synced data somehow presents a `.local` job on Intel, `runJob`'s `.local` branch returns a clear `LocalTranscriptionError`-style failure ("Local models require an Apple Silicon Mac") instead of attempting inference. **No cloud auto-routing.**

### Alternative considered
Make `LocalModelCatalog.all` return `[]` on Intel (gate at the data layer). Cleaner data-wise, but risks the Models view rendering an empty "no models" state rather than the section being **absent**. Rejected in favour of the explicit capability flag that hides sections outright — matching the decision that Intel "shouldn't show local models in menu."

---

## Verification / success criteria

1. **SPM suite green at 14.4** — `swift test --disable-sandbox --package-path Packages/AudioPipeline` passes after the `platforms` change.
2. **App target recompiles clean at 14.4** — the authoritative stray-API sweep. Any API above 14.4 that the inventories missed surfaces here as a hard error and gets guarded/replaced.
3. **Apple Silicon dev machine unchanged** — app builds and runs at the 14.4 target with glass intact (the 26+ path), local models present and selectable.
4. **Intel path testable without an Intel Mac** — a debug override forcing `LocalModelSupport.isSupported = false` confirms every local-model surface disappears and cloud stays available. Add a temporary override hook (compiled out or debug-only) for this check.
5. **Known residual risk (cannot verify in-sandbox):** process-tap and private-TCC-SPI behaviour on **real macOS 14.4 hardware** varies across point releases. This is the actual risk of the lowering, not the SwiftUI. Documented as a caveat; requires a real or VM 14.4 machine to close. Ship-gating on this is a project decision, not part of the code change.

## Rollback / ongoing cost

- The change is reversible: raising the target back to 26.3 leaves the `#available` branches as harmless dead fallbacks.
- Ongoing tax: every future macOS-26 nicety now needs an availability guard. The `GlassPanel.swift` seam + `glassProminentButton()` helper keep that cost localized for the glass family.

---

## Amendment (2026-07-04) — distribution & dictation gate

- **Distribution: separate single-arch builds, never a universal binary.** Ship an **arm64** build (with local models) and an **x86_64** build (local models disabled at runtime via `LocalModelSupport.isSupported == false`). The release pipeline builds/notarizes the two arches separately (e.g. `xcodebuild … ARCHS=arm64 …` and `… ARCHS=x86_64 …`) rather than a fat universal archive. `ARCHS` is left at the project default; per-arch selection happens at archive time.
- **x86_64 compile fix.** The IndicConformer engine's `Float(Float16)` read (`CoreMLIndicInference.swift`) is arm64-only; the x86_64 slice uses `MLMultiArray`'s portable NSNumber accessor. Local code is compiled (not omitted) on x86_64 but never runs (runtime-gated).
- **Dictation gate.** The Jobs-only defensive scope in Component 5 is extended to Dictation. `syncDictationWarmModel` requires `LocalModelSupport.isSupported` before warming a resident model. The two capture entry points (`beginCapture`, `endCaptureAndTranscribe`) preflight on `localDictationUnsupported` (dictation set to Local && `!isSupported`) and fail closed with an Apple Silicon-specific overlay message — kept distinct from the generic "no provider configured" case, and matching the clarity of the `runJob` guard. `resolveTranscriberInputs` stays a pure resolver.
