import Foundation
import SessionKit

/// A spoken note marked complete is saved to the listener's export folder (#3661). The work is the coordinator's
/// (`MarginOutputCoordinator.saveSpokenNote`) and the files are `SpokenNoteExport`'s (#3660); this only starts it and
/// says what happened.
extension Gate1AppModel {
    /// Called when an item was marked complete by hand. Does nothing for an item that is not a spoken note.
    func saveCompletedSpokenNoteToExportFolder(_ item: Item) {
        guard let noteId = SpokenNoteItem.noteId(of: item) else { return }
        saveSpokenNoteToExportFolder(noteId: noteId, title: item.title)
    }

    /// Also the Library row's "Save to Export Folder", for a completed note whose folder was not ready then. Safe to
    /// repeat: what is already in the folder is left as it is.
    func saveSpokenNoteToExportFolder(noteId: String, title: String) {
        let support = try? applicationSupportDirectory()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await marginOutput.saveSpokenNote(noteId: noteId, title: title, applicationSupport: support)
            hangTelemetry.labels.scoped("spokenNote.folderExport.publish") { presentSpokenNoteFolderOutcome(outcome, title: title) }
        }
    }

    private func presentSpokenNoteFolderOutcome(_ outcome: SpokenNoteFolderOutcome, title: String) {
        let line = outcome.line(title: title)
        recordDeveloperDiagnostic("spokenNote.folderExport", ["problem": String(outcome.isProblem)])
        // Saved: no banner. It would replace the Undo that marking complete just offered; the row says "Exported".
        guard outcome.isProblem else {
            reportSuccess(line)
            return
        }
        let action = outcome.settingsActionTitle.map { title in
            UserFeedbackEvent.Action(
                title: title, accessibilityLabel: "\(title) in Settings",
                identifier: "spokenNote.chooseFolder.button", perform: { [weak self] in self?.openSettings() })
        }
        if outcome.isMissingFolderOnly {
            // No folder yet is the listener's choice to make, not a failure: a warning, with the way to Settings.
            reportWarning(line, action: action)
            return
        }
        // A real failure stays until the listener closes it, with the way to the folder when that is the fix.
        statusMessage = "Error"
        lastError = line
        presentFeedback(UserFeedbackEvent(kind: .error, message: line, action: action))
        diagnostics["recentFailure"] = line
    }
}
