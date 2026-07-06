import Foundation
import AppKit
import AVFoundation
import DictationCore
import LocalTranscription
import RecordingCore
import AudioPipelineJobs
import AppSettings

/// Drives always-on auto-dictation: mic tap → VAD → segmenter → per-utterance
/// local transcription → append into the focused field. Toggled on/off by
/// DictationCoordinator when `shortTapAction == .autoListening`.
@MainActor
@Observable
final class AutoDictationController {
    private(set) var isRunning = false

    private let settings: AppSettings
    private let keychain: any KeychainProviding
    private let handlers: [JobShape: any AudioJobSending]
    private let ensureLocalModelResident: (String) async -> Void
    private let log: (String) -> Void

    private let detector: StreamingVoiceDetector
    private let tempStore = DictationTempStore()
    private let overlay = DictationOverlayController()

    // Tuning. One frame = 4096 samples = 256 ms @ 16 kHz.
    private static let frameSamples = StreamingVoiceDetector.frameSize
    private static let maxSegmentFrames = 59          // ~15 s
    private static let preRollFrames = 2              // ~512 ms
    private static let minSegmentSamples = 4_000      // ~250 ms: discard shorter

    private var tap: ContinuousMicTap?
    private var frameStream: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var segmentStream: AsyncStream<[Float]>.Continuation?
    private var transcribeTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var runGeneration = 0

    // Consumer-loop state (main-actor isolated; only touched in consumerTask).
    private var segmenter = AutoDictationSegmenter(maxSegmentFrames: AutoDictationController.maxSegmentFrames)
    private var preRoll: [[Float]] = []
    private var current: [Float] = []

    init(settings: AppSettings,
         keychain: any KeychainProviding,
         handlers: [JobShape: any AudioJobSending],
         ensureLocalModelResident: @escaping (String) async -> Void,
         log: @escaping (String) -> Void,
         vadModelDirectory: URL) {
        self.settings = settings
        self.keychain = keychain
        self.handlers = handlers
        self.ensureLocalModelResident = ensureLocalModelResident
        self.log = log
        self.detector = StreamingVoiceDetector(modelDirectory: vadModelDirectory)
    }

    func toggle() { isRunning ? stop() : start() }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        prepareTask?.cancel(); prepareTask = nil
        tap?.stop(); tap = nil
        frameStream?.finish(); frameStream = nil
        consumerTask?.cancel(); consumerTask = nil
        segmentStream?.finish(); segmentStream = nil   // lets the transcribe loop drain + exit
        preRoll.removeAll(); current.removeAll()
        segmenter = AutoDictationSegmenter(maxSegmentFrames: Self.maxSegmentFrames)
        overlay.update(phase: .idle, enabled: settings.dictation.showOverlay)
    }

    private func start() {
        guard !isRunning else { return }
        // Preflight: local + Apple Silicon only.
        guard TranscriptionSource(providerID: settings.dictation.providerID) == .local,
              LocalModelSupport.isSupported else {
            overlay.flash("Auto-dictation needs a local model on Apple Silicon")
            return
        }
        isRunning = true
        overlay.setModelLoading(true)
        overlay.update(phase: .listening, enabled: settings.dictation.showOverlay)

        runGeneration += 1
        let gen = runGeneration

        // Serial transcription consumer: one segment at a time, in order.
        let (segStream, segCont) = AsyncStream<[Float]>.makeStream()
        segmentStream = segCont
        transcribeTask = Task { [weak self] in
            for await samples in segStream { await self?.transcribeAndInsert(samples, generation: gen) }
        }

        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.detector.prepare()
                await self.detector.reset()
                await self.ensureLocalModelResident(self.settings.dictation.model)
            } catch {
                guard self.isRunning, self.runGeneration == gen else { return }   // stale session (stopped/restarted during prepare) — don't flash or tear down the current one
                self.log("Auto-dictation: VAD prepare failed: \(error.localizedDescription)")
                self.overlay.flash("Couldn't start auto-dictation")
                self.stop()
                return
            }
            guard self.isRunning, self.runGeneration == gen else { return }   // a stop()/restart happened during prepare — abandon this stale session
            self.overlay.setModelLoading(false)
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard isRunning else { return }
        let (stream, cont) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        frameStream = cont
        do {
            self.tap?.stop()   // defensive: never leave a prior tap running
            let tap = try ContinuousMicTap(frameSize: Self.frameSamples) { [cont] frame in
                cont.yield(frame)   // audio thread → stream; consumer hops to main
            }
            try tap.start()
            self.tap = tap
        } catch {
            log("Auto-dictation: mic unavailable: \(error.localizedDescription)")
            overlay.flash("Mic unavailable")
            stop()
            return
        }
        consumerTask = Task { [weak self] in
            for await frame in stream { await self?.consume(frame) }
        }
    }

    private func consume(_ frame: [Float]) async {
        // Maintain a rolling pre-roll so the first word isn't clipped.
        preRoll.append(frame)
        if preRoll.count > Self.preRollFrames { preRoll.removeFirst() }

        let event: VoiceActivityEvent = (try? await detector.detect(frame)) ?? .none
        guard isRunning else { return }
        let mapped: AutoDictationSegmenter.VoiceEvent
        switch event {
        case .speechStart: mapped = .speechStart
        case .speechEnd:   mapped = .speechEnd
        case .none:        mapped = .none
        }

        switch segmenter.step(mapped) {
        case .ignore:
            break
        case .beginSegment:
            current = preRoll.flatMap { $0 }   // include pre-roll + this frame
            overlay.update(phase: .listening, enabled: settings.dictation.showOverlay)
        case .appendFrame:
            current.append(contentsOf: frame)
        case .finalizeSegment:
            finalizeCurrent()
        case .rolloverSegment:
            finalizeCurrent()
            current = frame                    // this frame opens the next segment
        }
    }

    private func finalizeCurrent() {
        let samples = current
        current.removeAll()
        guard samples.count >= Self.minSegmentSamples else { return }   // drop coughs/clicks
        segmentStream?.yield(samples)
        overlay.update(phase: .transcribing, enabled: settings.dictation.showOverlay)
    }

    private func transcribeAndInsert(_ samples: [Float], generation gen: Int) async {
        guard isRunning, runGeneration == gen else { return }   // stale drained segment from a stopped/restarted session — skip write+transcribe entirely
        let url = tempStore.newCaptureURL()
        defer { tempStore.delete(url) }
        do {
            try await Task.detached { try SegmentAudioWriter.write(samples, to: url) }.value
        } catch {
            log("Auto-dictation: segment write failed: \(error.localizedDescription)")
            if isRunning { overlay.update(phase: .listening, enabled: settings.dictation.showOverlay) }
            return
        }
        let job = Job(
            name: "Dictation", providerID: Provider.localID,
            model: settings.dictation.model,
            fields: ["language": settings.dictation.language], outputExt: "txt")
        let transcriber = BatchTranscriber(
            job: job, provider: .localPlaceholder,
            shape: .localTranscription, keychain: keychain, handlers: handlers)
        let box = TranscriptBox()
        do {
            try await transcriber.transcribe(
                audioFile: url, onPartial: { _ in }, onFinal: { box.value = $0 })
        } catch {
            log("Auto-dictation: transcription failed: \(error.localizedDescription)")
            if isRunning { overlay.update(phase: .listening, enabled: settings.dictation.showOverlay) }
            return
        }
        let text = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, runGeneration == gen else { return }   // toggled off (or restarted) mid-transcription: drop the tail utterance rather than insert into whatever is now focused
        if !text.isEmpty {
            _ = TextInserter().insert(" " + text, mode: settings.dictation.insertMode)
        }
        if isRunning { overlay.update(phase: .listening, enabled: settings.dictation.showOverlay) }
    }
}

/// Single-writer transcript box (BatchTranscriber calls onFinal once,
/// synchronously, before returning — the await is the happens-before barrier).
private final class TranscriptBox: @unchecked Sendable { nonisolated(unsafe) var value = "" }
