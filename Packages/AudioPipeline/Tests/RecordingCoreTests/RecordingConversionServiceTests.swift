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
                destination: destA, keepSourcesOnSuccess: true
            )
            let taskB = await service.startConversion(
                folderName: "b", mic: micB, system: nil,
                destination: destB, keepSourcesOnSuccess: true
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
                destination: dest, keepSourcesOnSuccess: true
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
                destination: dest, keepSourcesOnSuccess: false
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
                destination: dest, keepSourcesOnSuccess: true
            )
            _ = await task.value

            #expect(FileManager.default.fileExists(atPath: mic.path) == true)
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
                destination: dest, keepSourcesOnSuccess: false
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
