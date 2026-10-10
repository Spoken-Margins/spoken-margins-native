#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation

enum AddMarginShortcutError: Error, Equatable, LocalizedError {
    case emptyText
    case nothingPlaying
    case writingInProgress
    case libraryUnavailable
    case notSaved(String?)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "The Margin is empty. Pass the text the Margin should say."
        case .nothingPlaying:
            return "Nothing is playing in Spoken Margins. Start an item, then run the shortcut again."
        case .writingInProgress:
            return "Spoken Margins is already waiting on a Margin. Save or cancel it, then run the shortcut again."
        case .libraryUnavailable:
            return "Spoken Margins could not open its Library. Try the shortcut again."
        case .notSaved(let reason):
            return reason ?? "The Margin could not be saved."
        }
    }
}

/// Saves a written Margin on the playing item through the same begin/save path the in-app
/// "Write a Margin" button uses, so the anchor, the listening-signals bookkeeping and the
/// resume-after-saving behaviour are the ones listeners already get.
@MainActor
enum AddMarginShortcutAction {
    /// Returns the title of the item that received the Margin. Throws before touching playback when
    /// the text is empty, nothing is playing, or a Margin is already being written; a Margin is
    /// created only if it was saved.
    static func addWrittenMargin(text: String, to model: Gate1AppModel) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AddMarginShortcutError.emptyText }
        guard model.hasActiveSession else { throw AddMarginShortcutError.nothingPlaying }
        guard !model.recordingNavigationIsLocked else { throw AddMarginShortcutError.writingInProgress }

        model.beginWrittenMargin()
        guard let draft = model.writtenMarginDraft else {
            throw AddMarginShortcutError.notSaved(model.lastError)
        }
        model.saveWrittenMargin(text: text)
        guard model.writtenMarginDraft == nil else {
            // The save failed and kept the draft open; close it so the next shortcut run (or the
            // listener) starts clean, and say why.
            let reason = model.lastError
            model.cancelWrittenMargin()
            throw AddMarginShortcutError.notSaved(reason)
        }
        return draft.itemTitle
    }
}

struct AddMarginToSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Margin"
    static let description = IntentDescription(
        "Writes a text Margin on whatever is playing in Spoken Margins, at the current place. Playback carries on afterwards."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Text",
        description: "What the Margin says.",
        requestValueDialog: "What should the Margin say?"
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add Margin \(\.$text) to what's playing")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The same weak reference the Listening Edition action uses; the app sets it at launch,
        // including when a shortcut launches the app in the background.
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        let title = try AddMarginShortcutAction.addWrittenMargin(text: text, to: model)
        return .result(dialog: "Margin added to \(title).")
    }
}
#endif
