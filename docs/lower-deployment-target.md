# Lowering the Deployment Target (research, deferred)

The app currently targets **macOS 26.3** (`MACOSX_DEPLOYMENT_TARGET` in
`Amanuensis.xcodeproj/project.pbxproj`, four configs; `platforms: [.macOS("26.3")]`
in `Packages/AudioPipeline/Package.swift`). This note records what it would take to
lower that so older macs can run the app. It came up while adopting Liquid Glass for
the dictation overlay and mic cue — "graceful degradation on older macs" only means
something if there are older macs in scope, which today there aren't.

**Status: deferred.** Captured 2026-06-27 as a potential future improvement. The
glass-HUD polish proceeds independently at the 26.3 target.

---

## The floor is macOS 14.4 — set by one feature: system-audio capture

The system-audio path uses Core Audio **process taps**
(`Packages/AudioPipeline/Sources/RecordingCore/ProcessTapRecorder.swift`):

- `AudioHardwareCreateProcessTap`, `CATapDescription`, `AudioHardwareCreateAggregateDevice`,
  `kAudioAggregateDeviceTapListKey`, `kAudioAggregateDeviceTapAutoStartKey`.
- `AudioHardwareCreateProcessTap` was introduced in **macOS 14.2** (verified via
  apple-docs). 14.0–14.1 lack it entirely; 14.2–14.3 shipped with process-tap bugs
  that real-world tap projects (AudioCap and similar) avoid by requiring **14.4**.
- There is **no fallback recorder** — no AVAudioEngine or ScreenCaptureKit
  system-audio path exists in the code.

So **14.4 is the realistic minimum.** Going below macOS 14 would mean
re-architecting system-audio capture entirely (e.g. a ScreenCaptureKit audio path) —
a separate, much larger project, out of scope for a simple target lower.

## Almost everything else already works at 14.4

The app's backbone is 14-era or older:

- Observation (`@Observable` / `@Bindable`) — 14.0
- `ContentUnavailableView` — 14.0; `.symbolEffect(_:options:isActive:)` — 14.0
- `MenuBarExtra`, `Window`, `Settings`, `NavigationSplitView`, `Table`, `.task`,
  `.onChange`, `.contextMenu(forSelectionType:)` — 13.0
- AVAudioEngine / AVAudioFile, CGEvent taps (hotkey monitor + paste insertion),
  the mic-in-use HAL property (`kAudioDevicePropertyDeviceIsRunningSomewhere`),
  the private TCC capture SPI (`TCCAccessPreflight` / `TCCAccessRequest`) — all ≤14.0

## The only thing above 14.4 is Liquid Glass — a tiny surface

| API | Introduced | Sites |
|---|---|---|
| `.glassEffect(.regular, in:)` | macOS 26.0 | `UI/Sidebar/SidebarActivityBar.swift` (1), plus the dictation overlay + mic cue if migrated to glass |
| `.buttonStyle(.glassProminent)` | macOS 26.0 | `UI/Providers/ProviderEditorView.swift`, `UI/Jobs/JobsView.swift`, `UI/Jobs/JobEditorView.swift` ×2 (4) |

Nothing else in the codebase exceeds 14.4. There are currently **no** `@available` /
`if #available` guards anywhere — the code assumes the declared target outright.

## What the work would be

1. Lower `MACOSX_DEPLOYMENT_TARGET` (4 configs in `project.pbxproj`) and the
   `Package.swift` `platforms` to `.macOS("14.4")` (keep the string form — SPM's
   `.v14` can't express the `.4`).
2. Wrap the glass sites in `if #available(macOS 26, *)` with material fallbacks
   (`.glassEffect` → `.ultraThinMaterial` / `.regularMaterial`; `.glassProminent` →
   `.borderedProminent`). A shared `glassBackground` helper keeps it DRY.
3. **Recompile against 14.4.** The compiler then flags any remaining too-new API as a
   hard error — that recompile is the authoritative sweep; the inventory above is the
   first pass.
4. **Test the process-tap path on real macOS 14.4.** The private TCC SPI and tap
   behavior vary across point releases — this is the actual risk, not the SwiftUI.
5. Toolchain note: the Swift 6.2 features in use (default-`MainActor` isolation, the
   upcoming-feature flags) are compile-time only — **no runtime OS floor** — so they
   stay as-is.

## Cost

The *code* cost is small: Liquid Glass is the only macOS-26 dependency (~5 sites).
The real costs are the recompile-sweep, testing on old hardware, and an ongoing tax —
every future macOS-26 nicety then needs an availability guard.

---

_Source: research during the Liquid Glass HUD polish, 2026-06-27._
