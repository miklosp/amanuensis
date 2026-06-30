import AppKit
import AppSettings
import AudioPipelineJobs
import Foundation
import os

// Resolves write access to a job's custom output folder under App Sandbox,
// re-prompting the user when the security-scoped bookmark is missing or stale.
// Mirrors RecordingsFolderAccess, but per-run (acquire → write → release): each
// job run targets one folder briefly, rather than holding a process-lifetime
// scope like the recordings folder does.
@MainActor
enum JobOutputFolderAccess {
    private static let log = Logger(subsystem: "work.miklos.amanuensis", category: "job-output-folder")

    // An active security scope for one job run. Carries the possibly-updated Job
    // (a renewed bookmark, or a newly-picked folder) for the caller to persist,
    // and the scoped URL to release once the run finishes.
    struct Grant {
        let job: Job
        let scopedURL: URL?
        func release() { scopedURL?.stopAccessingSecurityScopedResource() }
    }

    enum Outcome {
        case granted(Grant)
        case declined   // a scope was needed but the user cancelled the picker
    }

    // Folders next to the recording or under ~/Music need no scope — the
    // recordings scope / music entitlement already cover them, so grant a no-op.
    static func acquire(for job: Job) -> Outcome {
        guard let path = job.outputFolderPath, !path.isEmpty else {
            return .granted(Grant(job: job, scopedURL: nil))
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard AppSettings.needsSecurityScope(for: folder) else {
            return .granted(Grant(job: job, scopedURL: nil))
        }
        if let data = job.outputFolderBookmark, let grant = resolve(bookmark: data, for: job) {
            return .granted(grant)
        }
        return prompt(for: job, suggesting: folder)
    }

    // Resolve a saved bookmark and start its scope, refreshing the stored
    // bookmark if the system flags it stale. Returns nil if resolution or scope
    // start fails — the caller then re-prompts.
    private static func resolve(bookmark data: Data, for job: Job) -> Grant? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                log.error("startAccessingSecurityScopedResource failed for saved output bookmark")
                return nil
            }
            var updated = job
            updated.outputFolderPath = url.path
            if stale, let fresh = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                updated.outputFolderBookmark = fresh
            }
            return Grant(job: updated, scopedURL: url)
        } catch {
            log.error("output bookmark resolve failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // Ask the user to re-grant access to the output folder, then mint a fresh
    // bookmark and start its scope. Returns .declined if they cancel.
    private static func prompt(for job: Job, suggesting folder: URL) -> Outcome {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Grant Access"
        panel.message = "Amanuensis needs permission to save “\(job.name)” transcripts to this folder."
        if FileManager.default.fileExists(atPath: folder.path) {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return .declined
        }
        guard url.startAccessingSecurityScopedResource() else {
            log.error("startAccessingSecurityScopedResource failed for re-picked output folder")
            return .declined
        }
        var updated = job
        updated.outputFolderPath = url.path
        updated.outputFolderBookmark = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        return .granted(Grant(job: updated, scopedURL: url))
    }
}
