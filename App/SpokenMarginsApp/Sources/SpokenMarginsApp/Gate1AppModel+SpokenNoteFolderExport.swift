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
            presentSpokenNoteFolderOutcome(outcome, title: title)
        }
    }

    private func presentSpokenNoteFolderOutcome(_ outcome: SpokenNoteFolderOutcome, title: String) {
        let line = outcome.line(title: title)
        recordDeveloperDiagnostic("spokenNote.folderExport", ["problem": String(outcome.isProblem)])
        guard outcome.isProblem else {
            reportConfirmation(line)
            return
        }
        // Stays until the listener closes it (an error banner does), with the way to the folder when that is the fix.
        let choose = outcome.needsFolderChoice
            ? UserFeedbackEvent.Action(
                title: "Choose Folder", accessibilityLabel: "Choose an export folder in Settings",
                identifier: "spokenNote.chooseFolder.button", perform: { [weak self] in self?.openSettings() })
            : nil
        statusMessage = "Error"
        lastError = line
        presentFeedback(UserFeedbackEvent(kind: .error, message: line, action: choose))
        diagnostics["recentFailure"] = line
    }
}
