import Foundation
import SessionKit

/// Share Diagnostics (#903). Kept out of `Gate1AppModel.swift` to hold that file under its size
/// ceiling (scripts/hot_file_ratchet.py).
extension Gate1AppModel {
    /// Writes the diagnostics export to a file for the share sheet, or nil after reporting why not.
    func diagnosticsExportFileURL() -> URL? {
        guard let text = diagnosticsExportText() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            return try DiagnosticsExportFile.write(text, build: developerDiagnosticBuild, exportedAt: Date(), to: directory)
        } catch {
            reportFailure("Diagnostics export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
