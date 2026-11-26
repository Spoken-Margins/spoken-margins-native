#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

/// Why the Export Diagnostics action handed on no file. A Shortcut shows the message, so it never passes on an
/// empty or missing file in silence.
enum ExportDiagnosticsShortcutError: Error, Equatable, LocalizedError {
    case appUnavailable
    case notWritten

    var errorDescription: String? {
        switch self {
        case .appUnavailable: "Spoken Margins could not open its Library, so no diagnostics were made. Open the app once and run the shortcut again."
        case .notWritten: "Spoken Margins could not write the diagnostics file. Try again, or use Settings, Share Diagnostics."
        }
    }
}

/// The file behind the Export Diagnostics action (#5126): the same file Settings › Share Diagnostics makes, through the
/// same `writeDiagnosticsExportFileOffMain()` and so the same `DiagnosticsExport` redaction. It only reads; it starts,
/// stops and pauses nothing, so what is playing keeps playing.
enum ExportDiagnosticsShortcutAction {
    @MainActor
    static func file(model: Gate1AppModel?) async throws -> IntentFile {
        guard let model else { throw ExportDiagnosticsShortcutError.appUnavailable }
        // Read into memory: the next export (or the Settings button) replaces the temporary file, and a Shortcut may
        // hold this result for a while before handing it on.
        let url: URL
        let data: Data
        do {
            url = try await model.writeDiagnosticsExportFileOffMain()
            data = try await Task.detached(priority: .userInitiated) { [url] in try Data(contentsOf: url) }.value
        } catch {
            throw ExportDiagnosticsShortcutError.notWritten
        }
        guard !data.isEmpty else { throw ExportDiagnosticsShortcutError.notWritten }
        return IntentFile(data: data, filename: url.lastPathComponent, type: .json)
    }
}

/// Returns the Diagnostics file, so a listener's own Shortcut can pass it on with a screenshot to a bug report. It runs
/// without opening the app.
struct ExportDiagnosticsIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Diagnostics"
    // A literal, because App Intents metadata is read at build time. It carries `DiagnosticsExportFile.contentsDescription`
    // word for word; DiagnosticsExportDescriptionTests fails if the two drift apart.
    static let description = IntentDescription(
        "Returns the same Diagnostics file as Settings, Share Diagnostics. App state and recent playback events, as a file for a bug report. Web links and file paths in it are replaced with placeholders, and episodes, articles and PDFs in your Library appear as codes, not by their titles. It holds no Margin text, recordings or audio. Spoken Margins sends it nowhere; pass the file to any action you like."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // The same weak reference the other actions use; the app sets it at launch, including when a shortcut launches
        // the app in the background.
        .result(value: try await ExportDiagnosticsShortcutAction.file(model: ListeningEditionShortcutBridge.model))
    }
}
#endif
