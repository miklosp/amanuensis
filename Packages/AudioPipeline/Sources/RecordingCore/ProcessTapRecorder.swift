import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

// Captures system audio (everything playing through the default output device)
// via macOS 14.4+ Core Audio process taps. Mirrors AudioCap's setup:
//   CATapDescription → AudioHardwareCreateProcessTap → private aggregate
//   device wrapping the tap → AudioDeviceCreateIOProcIDWithBlock → start.
//
// All Core Audio resources are torn down explicitly in stop(). A crash mid-run
// can leave the private aggregate device hanging around until reboot — there
// is no cleanup-on-launch sweep in this first pass.
@MainActor
final class ProcessTapRecorder {
    private let url: URL

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ioQueue: DispatchQueue?
    private var writer: AudioFileWriter?

    init(url: URL) {
        self.url = url
    }

    func start() throws {
        // Empty exclude-list ⇒ tap every process that outputs audio, mixed to
        // stereo. This is the "record all system audio" configuration.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard createStatus == noErr, tap != kAudioObjectUnknown else {
            throw ProcessTapError.createTapFailed(createStatus)
        }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            tap,
            &formatAddress,
            0,
            nil,
            &size,
            &asbd
        )
        guard formatStatus == noErr else {
            throw ProcessTapError.readTapFormatFailed(formatStatus)
        }

        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw ProcessTapError.unsupportedTapFormat
        }

        let outputUID = try Self.defaultOutputDeviceUID()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "audio-pipeline-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw ProcessTapError.createAggregateFailed(aggregateStatus)
        }
        aggregateDeviceID = aggregate

        let writer = try AudioFileWriter(url: url, format: avFormat, label: "system")
        self.writer = writer

        let queue = DispatchQueue(
            label: "work.miklos.audio-pipeline.tap.io",
            qos: .userInitiated
        )
        ioQueue = queue

        let bytesPerFrame = asbd.mBytesPerFrame
        guard bytesPerFrame > 0 else { throw ProcessTapError.unsupportedTapFormat }

        // AVAudioFormat is an NSObject; wrap it so the IO block's capture
        // satisfies strict-concurrency Sendable checks. The format is
        // initialised once on the main actor and read-only thereafter, so the
        // unchecked-Sendable promise is genuinely upheld.
        let formatRef = SendableFormat(value: avFormat)

        var procID: AudioDeviceIOProcID?
        let blockStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregate,
            queue
        ) { @Sendable _, inInput, _, _, _ in
            Self.handle(
                inputBufferList: inInput,
                format: formatRef.value,
                bytesPerFrame: bytesPerFrame,
                writer: writer
            )
        }
        guard blockStatus == noErr, let createdProcID = procID else {
            throw ProcessTapError.createIOProcFailed(blockStatus)
        }
        ioProcID = createdProcID

        let startStatus = AudioDeviceStart(aggregate, createdProcID)
        guard startStatus == noErr else {
            throw ProcessTapError.deviceStartFailed(startStatus)
        }

        Self.log.info("system tap started at \(avFormat.sampleRate, privacy: .public)Hz \(avFormat.channelCount, privacy: .public)ch")
    }

    func stop() -> RecordingTrackResult? {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        guard let writer else { return nil }
        let frames = writer.close()
        Self.log.info("system tap stopped — \(frames, privacy: .public) frames written")
        return RecordingTrackResult(
            url: writer.url,
            format: writer.processingFormat,
            framesWritten: frames
        )
    }

    // Runs on the Core Audio IO thread. Copies the inbound buffer list into a
    // newly-allocated AVAudioPCMBuffer (so the data outlives the IO callback)
    // and hands it to the writer. The malloc is the price of decoupling the
    // file I/O from the real-time thread — fine for the first pass.
    private nonisolated static func handle(
        inputBufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        bytesPerFrame: UInt32,
        writer: AudioFileWriter
    ) {
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputBufferList)
        )
        guard source.count > 0 else { return }
        let firstByteCount = source[0].mDataByteSize
        let frameCount = AVAudioFrameCount(firstByteCount / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else { return }
        copy.frameLength = frameCount

        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let pairs = min(source.count, destination.count)
        for index in 0..<pairs {
            let src = source[index]
            let dst = destination[index]
            guard let srcPtr = src.mData, let dstPtr = dst.mData else { continue }
            let bytes = min(src.mDataByteSize, dst.mDataByteSize)
            memcpy(dstPtr, srcPtr, Int(bytes))
        }

        writer.enqueue(copy)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else {
            throw ProcessTapError.noDefaultOutputDevice
        }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        let uidStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &uidSize,
            &uid
        )
        guard uidStatus == noErr else {
            throw ProcessTapError.readDeviceUIDFailed(uidStatus)
        }
        return uid as String
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "tap")
}

private struct SendableFormat: @unchecked Sendable {
    let value: AVAudioFormat
}

enum ProcessTapError: Error {
    case createTapFailed(OSStatus)
    case readTapFormatFailed(OSStatus)
    case unsupportedTapFormat
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case noDefaultOutputDevice
    case readDeviceUIDFailed(OSStatus)
}
