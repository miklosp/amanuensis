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
    static let suggestRecordingWhenMicInUse = "suggestRecordingWhenMicInUse"
    static let suggestStoppingWhenMeetingEnds = "suggestStoppingWhenMeetingEnds"
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
            #expect(settings.suggestRecordingWhenMicInUse == true)
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

    @Test func suggestRecordingWhenMicInUse_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.suggestRecordingWhenMicInUse = false

            let second = AppSettings(defaults: defaults)
            #expect(second.suggestRecordingWhenMicInUse == false)
        }
    }

    @Test func suggestRecordingWhenMicInUse_persistedFalse_loadsAsFalse() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PersistedKey.suggestRecordingWhenMicInUse)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestRecordingWhenMicInUse == false)
        }
    }

    @Test func suggestStoppingWhenMeetingEnds_defaultsTrue() {
        withIsolatedDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestStoppingWhenMeetingEnds == true)
        }
    }

    @Test func suggestStoppingWhenMeetingEnds_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.suggestStoppingWhenMeetingEnds = false

            let second = AppSettings(defaults: defaults)
            #expect(second.suggestStoppingWhenMeetingEnds == false)
        }
    }

    @Test func suggestStoppingWhenMeetingEnds_persistedFalse_loadsAsFalse() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PersistedKey.suggestStoppingWhenMeetingEnds)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestStoppingWhenMeetingEnds == false)
        }
    }

    @Test func recordingsDirectoryBookmark_persistsAndClears() {
        withIsolatedDefaults { defaults in
            let data = Data([0x01, 0x02, 0x03])

            let first = AppSettings(defaults: defaults)
            #expect(first.recordingsDirectoryBookmark == nil)
            first.recordingsDirectoryBookmark = data

            let second = AppSettings(defaults: defaults)
            #expect(second.recordingsDirectoryBookmark == data)

            second.recordingsDirectoryBookmark = nil
            let third = AppSettings(defaults: defaults)
            #expect(third.recordingsDirectoryBookmark == nil)
        }
    }

    @Test func defaultRecordingsDirectory_isUnderMusicNamedAmanuensis() {
        let dir = AppSettings.defaultRecordingsDirectory
        #expect(dir.lastPathComponent == "Amanuensis")
        #expect(dir.deletingLastPathComponent().standardizedFileURL
            == URL.musicDirectory.standardizedFileURL)
    }
}

@Suite struct NeedsSecurityScopePolicy {
    private let music = URL(filePath: "/Users/test/Music", directoryHint: .isDirectory)

    @Test func defaultAndMusicPaths_needNoScope() {
        let amanuensis = music.appending(path: "Amanuensis", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: amanuensis, musicDirectory: music) == false)
        #expect(AppSettings.needsSecurityScope(for: music, musicDirectory: music) == false)
        let nested = music.appending(path: "a/b", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: nested, musicDirectory: music) == false)
    }

    @Test func outsideMusic_needsScope() {
        let docs = URL(filePath: "/Users/test/Documents/Rec", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: docs, musicDirectory: music) == true)
    }

    @Test func siblingPrefix_needsScope() {
        // "/Users/test/MusicStuff" must NOT count as under "/Users/test/Music".
        let sibling = URL(filePath: "/Users/test/MusicStuff", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: sibling, musicDirectory: music) == true)
    }
}
