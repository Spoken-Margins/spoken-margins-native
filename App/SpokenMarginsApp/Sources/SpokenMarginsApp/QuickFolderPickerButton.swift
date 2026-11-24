import SwiftUI
import UniformTypeIdentifiers

/// Chooses the Quick Folder from outside the Add sheet: the Your AI screen's "Where your brief arrives" (#4683, Design 2b), and
/// Settings' Quick Folder row and screen (#3770). It has its own folder picker and makes the call it is given (the Add sheet's
/// `configureQuickAccessFolder`, or `reconnectQuickAccessFolder` for Choose Folder Again), so a folder chosen here is the one
/// Following and the Add sheet show. The Add sheet's own picker is unchanged.
struct QuickFolderPickerButton: View {
    /// True once a folder is chosen and can be opened: the button then reads **Change Folder**.
    let hasWorkingFolder: Bool
    /// Replaces the Choose/Change wording, for "Choose Folder Again".
    var title: String? = nil
    var accessibilityIdentifier = "yourAI.chooseFolder"
    let choose: @MainActor (URL) -> Void
    let failed: @MainActor (Error) -> Void
    @State private var isPicking = false

    var body: some View {
        Button(title ?? (hasWorkingFolder ? "Change Folder" : "Choose Folder")) { isPicking = true }
            .accessibilityIdentifier(accessibilityIdentifier)
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): choose(url)
                case .failure(let error): failed(error)
                }
            }
    }
}
