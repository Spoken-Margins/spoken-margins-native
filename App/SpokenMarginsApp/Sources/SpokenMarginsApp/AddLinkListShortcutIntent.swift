#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

/// The listener's own automation (for example a 6:00 Shortcut that gets a link list from their AI) hands the list to this
/// action (#4683, Design section 2e). It runs without opening the app, so it only checks the list and saves it in the
/// App Group's `LinkListHandoffs/` folder; the app adds it the next time it opens (`drainLinkListHandoffs()`). What counts
/// as a list, what is refused and the words the listener sees are `LinkListShortcutAction`'s, which a host test runs.
/// No Siri phrase: it is a building block for an automation.
struct AddLinkListToSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Link List to Spoken Margins"
    static let description = IntentDescription(
        "Saves a Spoken Margins link list. It's added to your Library the next time you open the app."
    )
    static let openAppWhenRun = false

    // Both are optional so the action never stops at a "Choose" file picker when the other is supplied.
    @Parameter(title: "Link List File", description: "A saved link list, a JSON file.")
    var file: IntentFile?

    @Parameter(title: "Link List Text", description: "A link list, or a whole reply from your AI that contains one.")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$file) to Spoken Margins") { \.$text }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let fileData = file?.data
        let text = text
        let saved = try await Task.detached(priority: .userInitiated) {
            let folder = LinkListHandoffFolder(baseDirectory: try SourceLinkHandoffStore.appGroup().rootDirectory)
            return try LinkListShortcutAction.run(file: fileData, text: text, folder: folder)
        }.value
        return .result(dialog: IntentDialog(stringLiteral: saved.dialog))
    }
}
#endif
