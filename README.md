<p align="center">
  <img src="Screenshots/mac512.png" alt="Amanuensis app icon" width="128" height="128">
</p>

# Amanuensis

> **amanuensis** · /əˌmæn.juˈen.sɪs/ · *noun*
>
> a person whose job is to write down what another person says or to copy what another person has written

An audio recording, transcription, and dictation app for macOS that lives in the
menu bar. It records your microphone and other apps' system audio at once, with no
virtual audio driver, and saves everything locally. From there a recording can go
to a transcription model, or to an audio-capable model that transcribes and
summarizes in one pass. Hold a modifier key for push-to-talk dictation, and the
transcript is pasted at your cursor.

Transcription runs in the cloud or on-device. Local models need Apple Silicon; on
an Intel Mac you use the cloud providers.

## Philosophy

- **Maximum compatibility.** Runs on macOS 14.4 and up. That's the floor the
  system-audio process-tap API sets, not an arbitrary cutoff.
- **Minimum permissions.** Sandboxed, with the Hardened Runtime, and it asks for
  exactly what it needs, nothing speculative. See
  [Permissions](#permissions-the-app-requests) for the full breakdown.
- **Minimum footprint.** The app bundles no models, so its download stays under
  10 MB. Local transcription is opt-in, and the Core ML models run on the Neural
  Engine with a small memory footprint — the English model needs under ~100 MB of
  RAM.
- **Free and open source.** MIT-licensed. No account, no subscription, no
  telemetry, and you can audit the whole thing.
- **Signed and notarized.** Release builds are Developer ID–signed and notarized
  by Apple, so they open straight from Gatekeeper without the right-click
  workaround or the "unidentified developer" warning.

> Naming note: the app ships as **Amanuensis** (`work.miklos.amanuensis`), but the
> internal SPM package and its modules keep their original `AudioPipeline` names
> (e.g. `import AudioPipelineJobs`). Intentional, and purely cosmetic.

## Requirements

- macOS 14.4 or later. The system-audio process-tap API (macOS 14.2+) sets the
  floor; 14.4 is the practical minimum. On-device transcription requires an Apple
  Silicon Mac; Intel Macs use cloud providers only.
- Apple Silicon or Intel. Releases ship separate `arm64` and `x86_64` builds, so
  grab the one that matches your Mac.
- Xcode 26 / Swift 6.2 to build from source.

## Build & run

There is no Xcode workspace, only the `.xcodeproj`:

```bash
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build
```

Or open `Amanuensis.xcodeproj` in Xcode and press ⌘R. To find the built app:

```bash
xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug \
  -showBuildSettings | grep BUILT_PRODUCTS_DIR
open <BUILT_PRODUCTS_DIR>/Amanuensis.app
```

See [`CLAUDE.md`](CLAUDE.md) for the test surfaces and project structure details.

## Local models (on-device, Apple Silicon only)

Nothing is bundled. You download a model from inside the app, and after that
transcription runs entirely on your Mac with no network call. The models are tuned
for the Neural Engine and won't run on Intel, so the whole local surface is hidden
there.

| Model | Languages | Download | Notes |
|---|---|---|---|
| Parakeet TDT-CTC 110M | English | 217 MB | Tiny and fastest. Best default for English. |
| Parakeet TDT v3 | 25 European languages | 460 MB | Multilingual, auto-detects language. |
| SenseVoice Small | 50+ (Chinese, Japanese, Korean, English…) | 450 MB | Fast; strong on Chinese. |
| Parakeet TDT Japanese | Japanese | 590 MB | Dedicated Japanese model. |
| Whisper large-v3-turbo | 99 languages | 627 MB | Broadest coverage, near-large-v3 accuracy. |
| IndicConformer 600M | Hindi, Bengali, Marathi, Telugu, Tamil, Malayalam, Kannada | 700 MB | Best Hindi accuracy; on-device RNN-T. |
| Cohere Transcribe | 14 (incl. Japanese, Chinese, Korean) | 2.1 GB | Highest accuracy; heavier, transcribes long audio in 35s chunks. |

The FluidAudio (Parakeet, SenseVoice, Cohere) and WhisperKit engines do the heavy
lifting. The IndicConformer decoder is ported from
[Muesli](https://github.com/pHequals7/muesli) (MIT, © 2026 Pranav Hari), running a
Core ML quantization by
[phequals](https://huggingface.co/phequals/indic-conformer-600m-multilingual-coreml-rnnt)
of AI4Bharat's `indic-conformer-600m-multilingual`. Full attribution is in
[`NOTICE.md`](Packages/AudioPipeline/Sources/LocalTranscription/NOTICE.md).

## Cloud providers

Amanuensis ships with the providers below preconfigured (base URLs, suggested
models, field hints). They're all bring-your-own-key: you add your API key, and
it lives in the Keychain. The two "OpenAI-compatible" entries are generic, so you
can point them at any endpoint that speaks the OpenAI API (a self-hosted server,
LM Studio, a gateway). Providers are defined as plain data in
[`presets.json`](Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json),
and you can add your own from the in-app Providers UI.

### Speech-to-text (transcription)

| Provider | Suggested models | Notes |
|---|---|---|
| OpenAI Whisper | `whisper-1` | Prompt biases spelling/style only (~224 tokens). |
| OpenAI gpt-4o-transcribe | `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | Follows free-text instructions (no 224-token cap). |
| Groq Whisper | `whisper-large-v3`, `whisper-large-v3-turbo` | Upload cap 25 MB (free) / 100 MB (paid). |
| Mistral Voxtral | `voxtral-mini-2602` | No prompt parameter. |
| Cohere | `cohere-transcribe-03-2026` | Requires a language code per request; no prompt. |
| ElevenLabs Scribe | `scribe_v2`, `scribe_v1` | Speaker diarization on by default. |
| Soniox Async | `stt-async-v5` | Upload → poll → fetch; speaker diarization; context prompting. |
| Deepgram | `nova-3`, `nova-2` | Keyterm prompting on Nova-3; smart formatting. |
| OpenAI-compatible Transcription | — | Any OpenAI-style `/audio/transcriptions` endpoint. |

### Audio-capable chat / multimodal

These take the audio plus a free-text instruction and return Markdown (e.g.
"transcribe and summarize this meeting").

| Provider | Suggested models | Notes |
|---|---|---|
| OpenAI Chat (audio) | `gpt-4o-audio-preview` | 128K-token context. |
| Gemini | `gemini-2.5-flash`, `gemini-2.5-pro` | ~1M-token context; native Gemini API. |
| Gemini (OpenAI-compatible) | `gemini-2.5-flash`, `gemini-2.5-pro` | Gemini via its OpenAI-compatible surface. |
| OpenRouter | — | Route to any OpenRouter-hosted model. |
| OpenAI-compatible Chat | — | Any OpenAI-style `/chat/completions` endpoint. |

## Permissions the app requests

Amanuensis runs under the **App Sandbox** with the **Hardened Runtime**, and asks
only for what it needs. For the full breakdown, with the exact entitlement keys
and where each one is declared, see [`docs/permissions.md`](docs/permissions.md).

### Entitlements (granted at build/install time)

| Entitlement | Why |
|---|---|
| App Sandbox (`com.apple.security.app-sandbox`) | Runs the app sandboxed. |
| Network client (`com.apple.security.network.client`) | Outbound calls to the transcription / audio-understanding APIs you configure. No network traffic happens otherwise. |
| Audio input (`com.apple.security.device.audio-input`) | Microphone capture and the Core Audio process tap. |
| Music assets read/write (`com.apple.security.assets.music.read-write`) | Promptless access to `~/Music`; the default recordings folder is `~/Music/Amanuensis`. |
| User-selected files read/write (`com.apple.security.files.user-selected.read-write`) | Read/write a recordings folder you pick yourself, remembered as a security-scoped bookmark. (Injected via the `ENABLE_USER_SELECTED_FILES` build setting, not the entitlements plist.) |

### Runtime permissions (you approve these via system prompts / System Settings)

| Permission | Why |
|---|---|
| **Microphone** | Record the mic, and capture audio for dictation. Asked the first time you record. |
| **System Audio Capture** | Capture other apps' audio output through the Core Audio process tap. Without it, the system track records silence. |
| **Input Monitoring** | A listen-only global key tap that detects the dictation trigger key. It observes; it never consumes or logs keystrokes. |
| **Accessibility (post events)** | Synthesize a ⌘V to paste dictated text at your cursor. This is the narrow "post events" capability, not full Accessibility control. |

The System Audio Capture grant uses a private TCC API, which is the one thing
keeping Amanuensis off the Mac App Store today; every other permission is
App-Store-compatible.

## Contributing

PRs and feature requests are welcome. Open an issue or a pull request.

## License

[MIT](LICENSE) © 2026 Miklos Petravich
