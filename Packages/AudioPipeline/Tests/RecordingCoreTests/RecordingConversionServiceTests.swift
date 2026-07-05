import Foundation
import Testing
@testable import RecordingCore

@Suite struct RecordingConversionServiceTests {

    @Test func twoConcurrentConversions_doNotClobberEachOther() async throws {
        try await withTempDirectory { tmp in
            let signalA = SignalActor()
            let signalB = SignalActor()

            let service = RecordingConversionService { mic, _, destination in
                if mic.lastPathComponent.hasPrefix("a") {
                    await signalA.wait()
                } else {
                    await signalB.wait()
                }
                try Data().write(to: destination)
            }

            let micA = tmp.appending(path: "a-mic.caf")
            let micB = tmp.appending(path: "b-mic.caf")
            try Data().write(to: micA)
            try Data().write(to: micB)
            let destA = tmp.appending(path: "a-combined.flac")
            let destB = tmp.appending(path: "b-combined.flac")

            let taskA = await service.startConversion(
                folderName: "a", mic: micA, system: nil,
                destination: destA, micFlac: tmp.appending(path: "a-mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )
            let taskB = await service.startConversion(
                folderName: "b", mic: micB, system: nil,
                destination: destB, micFlac: tmp.appending(path: "b-mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )

            #expect(await service.isConverting(folderName: "a"))
            #expect(await service.isConverting(folderName: "b"))

            await signalA.fire()
            let outcomeA = await taskA.value
            #expect(outcomeA.folderName == "a")
            if case .failure(let err) = outcomeA.result {
                Issue.record("A unexpectedly failed: \(err.message)")
            }
            #expect(await service.isConverting(folderName: "a") == false)
            // The fix: A's completion must NOT have cleared B's slot.
            #expect(await service.isConverting(folderName: "b") == true)

            await signalB.fire()
            let outcomeB = await taskB.value
            #expect(outcomeB.folderName == "b")
            #expect(await service.isConverting(folderName: "b") == false)
        }
    }

    @Test func waitForConversion_returnsWhenTaskCompletes() async throws {
        try await withTempDirectory { tmp in
            let signal = SignalActor()

            let service = RecordingConversionService { _, _, destination in
                await signal.wait()
                try Data().write(to: destination)
            }

            let mic = tmp.appending(path: "mic.caf")
            try Data().write(to: mic)
            let dest = tmp.appending(path: "combined.flac")

            _ = await service.startConversion(
                folderName: "rec", mic: mic, system: nil,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )

            // Kick off a waiter; it should not return until we fire the signal.
            let waiter = Task { await service.waitForConversion(folderName: "rec") }
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(waiter.isCancelled == false)
            // Heuristic: the waiter is still running because the conversion hasn't
            // finished. (We can't assert "not yet returned" directly; the value
            // check below covers it: if it had returned early, isConverting would
            // already be false here.)
            #expect(await service.isConverting(folderName: "rec"))

            await signal.fire()
            await waiter.value
            #expect(await service.isConverting(folderName: "rec") == false)
        }
    }

    @Test func waitForConversion_returnsImmediately_whenNothingPending() async {
        let service = RecordingConversionService { _, _, destination in
            try Data().write(to: destination)
        }
        // Should return without throwing or hanging.
        await service.waitForConversion(folderName: "missing")
    }

    @Test func successfulConversion_deletesSources_whenKeepIsFalse() async throws {
        try await withTempDirectory { tmp in
            let mic = tmp.appending(path: "mic.caf")
            let system = tmp.appending(path: "system.caf")
            let dest = tmp.appending(path: "combined.flac")
            try Data("mic".utf8).write(to: mic)
            try Data("sys".utf8).write(to: system)

            let service = RecordingConversionService { _, _, destination in
                try Data("flac".utf8).write(to: destination)
            }

            let task = await service.startConversion(
                folderName: "rec", mic: mic, system: system,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: false, keepSeparateTracks: false
            )
            _ = await task.value

            #expect(FileManager.default.fileExists(atPath: mic.path) == false)
            #expect(FileManager.default.fileExists(atPath: system.path) == false)
            #expect(FileManager.default.fileExists(atPath: dest.path) == true)
        }
    }

    @Test func successfulConversion_keepsSources_whenKeepIsTrue() async throws {
        try await withTempDirectory { tmp in
            let mic = tmp.appending(path: "mic.caf")
            let dest = tmp.appending(path: "combined.flac")
            try Data("mic".utf8).write(to: mic)

            let service = RecordingConversionService { _, _, destination in
                try Data("flac".utf8).write(to: destination)
            }

            let task = await service.startConversion(
                folderName: "rec", mic: mic, system: nil,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )
            _ = await task.value

            #expect(FileManager.default.fileExists(atPath: mic.path) == true)
        }
    }

    @Test func sameFolderDoubleStart_returnsSameInflightTask() async throws {
        try await withTempDirectory { tmp in
            let signal = SignalActor()
            let counter = Counter()
            let service = RecordingConversionService { _, _, destination in
                await counter.increment()
                await signal.wait()
                try Data().write(to: destination)
            }
            let mic = tmp.appending(path: "mic.caf")
            try Data().write(to: mic)
            let dest = tmp.appending(path: "combined.flac")

            let task1 = await service.startConversion(
                folderName: "x", mic: mic, system: nil,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )
            let task2 = await service.startConversion(
                folderName: "x", mic: mic, system: nil,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: true, keepSeparateTracks: false
            )

            await signal.fire()
            let out1 = await task1.value
            let out2 = await task2.value

            // The guard means the second start returned the first task — combine
            // was invoked exactly once, both callers see the same outcome folder.
            #expect(await counter.value == 1)
            #expect(out1.folderName == "x")
            #expect(out2.folderName == "x")
            #expect(await service.isConverting(folderName: "x") == false)
        }
    }

    @Test func failedConversion_keepsSources_andSurfacesError() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        try await withTempDirectory { tmp in
            let mic = tmp.appending(path: "mic.caf")
            let dest = tmp.appending(path: "combined.flac")
            try Data("mic".utf8).write(to: mic)

            let service = RecordingConversionService { _, _, _ in
                throw Boom()
            }

            let task = await service.startConversion(
                folderName: "rec", mic: mic, system: nil,
                destination: dest, micFlac: tmp.appending(path: "mic.flac"), systemFlac: nil,
                keepSourcesOnSuccess: false, keepSeparateTracks: false
            )
            let outcome = await task.value

            switch outcome.result {
            case .success:
                Issue.record("expected failure")
            case .failure(let err):
                #expect(err.message == "boom")
            }
            // Sources MUST survive a failed conversion — we keep them as fallback evidence.
            #expect(FileManager.default.fileExists(atPath: mic.path) == true)
            #expect(FileManager.default.fileExists(atPath: dest.path) == false)
            #expect(await service.isConverting(folderName: "rec") == false)
        }
    }
}

private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

@Test func conversionKeepsSeparateTracksWhenEnabled() async throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mic = dir.appending(path: "mic.caf");     FileManager.default.createFile(atPath: mic.path, contents: Data())
    let sys = dir.appending(path: "system.caf");  FileManager.default.createFile(atPath: sys.path, contents: Data())
    let combined = dir.appending(path: "combined.flac")
    let micFlac = dir.appending(path: "mic.flac")
    let sysFlac = dir.appending(path: "system.flac")

    let svc = RecordingConversionService(
        combine: { _, _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) },
        exportTrack: { _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) })

    let outcome = await svc.startConversion(
        folderName: "f", mic: mic, system: sys, destination: combined,
        micFlac: micFlac, systemFlac: sysFlac,
        keepSourcesOnSuccess: false, keepSeparateTracks: true).value

    #expect({ if case .success = outcome.result { return true } else { return false } }())
    #expect(FileManager.default.fileExists(atPath: micFlac.path))   // separate FLAC kept
    #expect(FileManager.default.fileExists(atPath: sysFlac.path))
    #expect(!FileManager.default.fileExists(atPath: mic.path))      // .caf deleted (keepSources false)
    try? FileManager.default.removeItem(at: dir)
}

@Test func conversionSkipsSeparateTracksWhenDisabled() async throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mic = dir.appending(path: "mic.caf");     FileManager.default.createFile(atPath: mic.path, contents: Data())
    let combined = dir.appending(path: "combined.flac")
    let micFlac = dir.appending(path: "mic.flac")

    let svc = RecordingConversionService(
        combine: { _, _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) },
        exportTrack: { _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) })

    _ = await svc.startConversion(
        folderName: "f", mic: mic, system: nil, destination: combined,
        micFlac: micFlac, systemFlac: nil,
        keepSourcesOnSuccess: true, keepSeparateTracks: false).value

    #expect(!FileManager.default.fileExists(atPath: micFlac.path)) // not produced when disabled
    #expect(FileManager.default.fileExists(atPath: mic.path))      // .caf kept
    try? FileManager.default.removeItem(at: dir)
}
