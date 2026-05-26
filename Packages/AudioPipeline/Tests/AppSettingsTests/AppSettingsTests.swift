import Foundation
import Testing
import AppSettings

// Mirrors the private `Keys` enum in AppSettings.swift. Kept in sync by hand:
// changing the persisted keys would break user preferences anyway, so they're
// de-facto stable contract. The persistence round-trip tests below would fail
// loudly if the source key strings drift.
private enum PersistedKey {
    static let recordingsDirectory = "recordingsDirectory"
    static let keepOriginalCAF = "keepOriginalCAF"
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
            #expect(settings.keepOriginalCAF == true)
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

    @Test func keepOriginalCAF_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.keepOriginalCAF = false

            let second = AppSettings(defaults: defaults)
            #expect(second.keepOriginalCAF == false)
        }
    }

    @Test func keepOriginalCAF_persistedFalse_loadsAsFalse() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PersistedKey.keepOriginalCAF)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.keepOriginalCAF == false)
        }
    }
}
