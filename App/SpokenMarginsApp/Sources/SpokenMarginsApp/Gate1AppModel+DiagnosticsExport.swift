import Foundation
import SessionKit
import SessionKitPersistence

/// Share Diagnostics (#903). Kept out of `Gate1AppModel.swift` to hold that file under its size
/// ceiling (scripts/hot_file_ratchet.py).
extension Gate1AppModel {
    /// Writes the diagnostics export to a file for the share sheet, or nil after reporting why not.
    /// Runs the whole export on the calling thread; the Settings button uses `prepareDiagnosticsExportFileURL()`.
    func diagnosticsExportFileURL() -> URL? {
        diagnosticsExportOutcome(Result { try diagnosticsExportInputs().writeFile() })
    }

    /// The same file, built off the main actor so the button can show "Preparing diagnostics…" meanwhile (#1191).
    /// The app state is copied first, on the main actor; only the store scan, the JSON and the file write move off it.
    func prepareDiagnosticsExportFileURL() async -> URL? {
        let inputs = diagnosticsExportInputs()
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try inputs.writeFile() }
        }.value
        return diagnosticsExportOutcome(outcome)
    }

    private func diagnosticsExportOutcome(_ outcome: Result<URL, Error>) -> URL? {
        switch outcome {
        case .success(let file):
            return file
        case .failure(let error):
            reportFailure("Diagnostics export failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Everything the diagnostics export reads from the running app. `SQLiteSessionStore` serializes its own
/// connection, so `writeFile()` is safe to run off the main actor.
struct DiagnosticsExportInputs: Sendable {
    let live: [String: String]
    let store: SQLiteSessionStore?
    let fixed: DiagnosticsExport.Fixed
    /// The voice download log (#2224). Read from its file, so a download from an earlier launch is in the export.
    /// Settings › Voices may never have been opened this launch, so there is no log object to ask.
    var voiceDownloadLogFile: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map { VoiceCatalogCoordinator.downloadLogURL(supportDirectory: $0) }

    func writeFile() throws -> URL {
        var stored: [String: String] = [:]
        if let store {
            stored = PodcastAnchorCaptureDiagnostics.exportEntries(
                sessions: (try? store.loadSessions()) ?? [],
                interjections: { try store.loadInterjections(sessionId: $0) }
            )
        }
        if let voiceDownloadLogFile, let log = VoiceDownloadLog.exportJSON(fileURL: voiceDownloadLogFile) {
            stored["voiceDownloads"] = log
        }
        let text = try DiagnosticsExport.jsonText(DiagnosticsExport.entries(live: live, stored: stored, fixed: fixed))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        return try DiagnosticsExportFile.write(text, build: fixed.developerBuild, exportedAt: fixed.exportedAt, to: directory)
    }
}
