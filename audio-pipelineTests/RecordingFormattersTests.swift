import Foundation
import Testing
@testable import audio_pipeline

@Suite struct RecordingFormattersTests {
    @Suite struct DurationText {
        @Test func nilRendersEmDash() {
            #expect(RecordingFormatters.durationText(nil) == "—")
        }

        @Test func zeroRendersAsZeroPaddedMinutesAndSeconds() {
            #expect(RecordingFormatters.durationText(0) == "0:00")
        }

        @Test func subMinuteValuesPadSecondsToTwoDigits() {
            #expect(RecordingFormatters.durationText(5) == "0:05")
        }

        @Test func sixtyFiveSecondsBecomesOneOhFive() {
            #expect(RecordingFormatters.durationText(65) == "1:05")
        }

        @Test func tenMinutesExactly() {
            #expect(RecordingFormatters.durationText(600) == "10:00")
        }

        @Test func fractionalSecondsRoundToNearestWhole() {
            #expect(RecordingFormatters.durationText(64.4) == "1:04")
            #expect(RecordingFormatters.durationText(64.6) == "1:05")
        }
    }

    @Suite struct SizeText {
        // Mirrors the formatter the production code uses, so the comparison
        // stays locale-aware and tracks ByteCountFormatter's output exactly.
        private static func expected(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        @Test(arguments: [
            Int64(0),
            Int64(512),
            Int64(1_500),
            Int64(1_048_576),
            Int64(1_234_567_890),
        ])
        func matchesByteCountFormatter(bytes: Int64) {
            #expect(RecordingFormatters.sizeText(bytes) == Self.expected(bytes))
        }
    }
}
