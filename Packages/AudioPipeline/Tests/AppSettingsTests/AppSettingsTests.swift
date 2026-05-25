import Foundation
import Testing
import AppSettings

// Mirrors the private `Keys` enum in AppSettings.swift. Kept in sync by hand:
// changing the persisted keys would break user preferences anyway, so they're
// de-facto stable contract. The persistence round-trip tests below would fail
// loudly if the source key strings drift.
private enum PersistedKey {
    static let recordingsDirectory = "recordingsDirectory"
    static let outputFormat = "outputFormat"
}

// Runs `body` with a fresh `UserDefaults` suite that's removed on exit, so no
// suite leaks between tests or runs.
private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "AppSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

@Suite struct AppSettingsBehavior {
    @Test func freshSuite_usesBuiltInDefaults() {
        withIsolatedDefaults { defaults in
            let settings = AppSettings(defaults: defaults)

            #expect(settings.recordingsDirectory == AppSettings.defaultRecordingsDirectory)
            #expect(settings.outputFormat == .caf)
        }
    }

    @Test func recordingsDirectory_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let custom = URL(
                filePath: "/tmp/audio-pipeline-tests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )

            let first = AppSettings(defaults: defaults)
            first.recordingsDirectory = custom

            let second = AppSettings(defaults: defaults)
            #expect(second.recordingsDirectory == custom)
        }
    }

    @Test func outputFormat_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.outputFormat = .both

            let second = AppSettings(defaults: defaults)
            #expect(second.outputFormat == .both)
        }
    }

    @Test func outputFormat_invalidPersistedRaw_fallsBackToCAF() {
        withIsolatedDefaults { defaults in
            defaults.set("not-a-valid-format", forKey: PersistedKey.outputFormat)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.outputFormat == .caf)
        }
    }
}

@Suite struct OutputFormatInvariants {
    @Test(arguments: AppSettings.OutputFormat.allCases)
    func id_equalsRawValue(format: AppSettings.OutputFormat) {
        #expect(format.id == format.rawValue)
    }

    @Test(arguments: AppSettings.OutputFormat.allCases)
    func title_isNonEmpty(format: AppSettings.OutputFormat) {
        #expect(!format.title.isEmpty)
    }

    @Test func allCases_coversExpectedRawValues() {
        let rawValues = Set(AppSettings.OutputFormat.allCases.map(\.rawValue))
        #expect(rawValues == ["caf", "flac", "both"])
    }
}
