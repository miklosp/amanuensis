import Foundation
import AppSettings
import os

// Owns the effective recordings-folder URL and its security-scoped access for
// the process lifetime. Folders outside ~/Music are only reachable through a
// security-scoped bookmark; ~/Music is covered by assets.music.read-write. The
// default ~/Music/Amanuensis is the universal fallback whenever a bookmark fails.
@MainActor
final class RecordingsFolderAccess {
    private let settings: AppSettings
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "recordings-folder")

    // URL currently usable for writes (security scope already started if needed).
    private(set) var effectiveURL: URL

    private var activeScopedURL: URL?

    init(settings: AppSettings) {
        self.settings = settings
        self.effectiveURL = settings.recordingsDirectory
        resolveOnLaunch()
    }

    private func resolveOnLaunch() {
        guard let data = settings.recordingsDirectoryBookmark else {
            effectiveURL = settings.recordingsDirectory  // default / ~/Music, asset-covered
            return
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                log.error("startAccessingSecurityScopedResource failed; falling back to default")
                effectiveURL = AppSettings.defaultRecordingsDirectory
                return
            }
            activeScopedURL = url
            effectiveURL = url
            if stale, let fresh = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                settings.recordingsDirectoryBookmark = fresh
            }
        } catch {
            log.error("bookmark resolve failed: \(String(describing: error), privacy: .public)")
            effectiveURL = AppSettings.defaultRecordingsDirectory
        }
    }

    // Called from the Settings folder picker after the user chooses a folder.
    func select(_ url: URL) {
        stopActiveScope()
        if AppSettings.needsSecurityScope(for: url) {
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
                )
                guard url.startAccessingSecurityScopedResource() else {
                    log.error("startAccessingSecurityScopedResource failed for selected folder; falling back to default")
                    fallBackToDefault()
                    return
                }
                settings.recordingsDirectoryBookmark = data
                activeScopedURL = url
            } catch {
                log.error("bookmark create failed: \(String(describing: error), privacy: .public); falling back to default")
                fallBackToDefault()
                return
            }
        } else {
            settings.recordingsDirectoryBookmark = nil
        }
        settings.recordingsDirectory = url
        effectiveURL = url
    }

    // A non-Music folder the user picked is unusable (bookmark create or scope
    // start failed). Degrade to the always-writable default rather than leave
    // effectiveURL on a folder the sandbox will deny writes to (D7).
    private func fallBackToDefault() {
        settings.recordingsDirectoryBookmark = nil
        settings.recordingsDirectory = AppSettings.defaultRecordingsDirectory
        effectiveURL = AppSettings.defaultRecordingsDirectory
    }

    func teardown() { stopActiveScope() }

    private func stopActiveScope() {
        if let url = activeScopedURL {
            url.stopAccessingSecurityScopedResource()
            activeScopedURL = nil
        }
    }
}
