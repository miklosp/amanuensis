import XCTest
import AppSettings
@testable import Amanuensis

@MainActor
final class RecordingsFolderAccessTests: XCTestCase {
    private func isolatedSettings() -> (AppSettings, String) {
        let suite = "RecordingsFolderAccessTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), suite)
    }

    func test_noBookmark_usesRecordingsDirectoryAsIs() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let dir = URL.musicDirectory.appending(path: "Amanuensis", directoryHint: .isDirectory)
        settings.recordingsDirectory = dir

        let access = RecordingsFolderAccess(settings: settings)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_bogusBookmark_fallsBackToDefault() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.recordingsDirectory = URL(filePath: "/tmp/should-not-be-used", directoryHint: .isDirectory)
        settings.recordingsDirectoryBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let access = RecordingsFolderAccess(settings: settings)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL,
                       AppSettings.defaultRecordingsDirectory.standardizedFileURL)
    }

    func test_selectUnderMusic_storesNoBookmark() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let access = RecordingsFolderAccess(settings: settings)
        let dir = URL.musicDirectory.appending(path: "Amanuensis", directoryHint: .isDirectory)

        access.select(dir)
        XCTAssertNil(settings.recordingsDirectoryBookmark)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(settings.recordingsDirectory.standardizedFileURL, dir.standardizedFileURL)
    }
}
