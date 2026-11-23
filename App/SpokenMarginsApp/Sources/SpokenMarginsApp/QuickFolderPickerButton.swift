import SwiftUI
import UniformTypeIdentifiers

/// Chooses the Quick Folder from outside the Add sheet: the Your AI screen's "Where your brief arrives" (#4683, Design 2b).
/// It has its own folder picker and makes the same call the Add sheet's does (`configureQuickAccessFolder`), so a folder
/// chosen here is the one Following and the Add sheet show. The Add sheet's own picker is unchanged.
struct QuickFolderPickerButton: View {
    /// True once a folder is chosen and can be opened: the button then reads **Change Folder**.
    let hasWorkingFolder: Bool
    let choose: @MainActor (URL) -> Void
    let failed: @MainActor (Error) -> Void
    @State private var isPicking = false

    var body: some View {
        Button(hasWorkingFolder ? "Change Folder" : "Choose Folder") { isPicking = true }
            .accessibilityIdentifier("yourAI.chooseFolder")
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): choose(url)
                case .failure(let error): failed(error)
                }
            }
    }
}
