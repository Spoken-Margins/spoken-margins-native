import SessionKit
import SwiftUI

/// A spoken note the listener is renaming: which row, and the name being typed, which starts as the name it has now
/// (#3663).
struct SpokenNoteRenameTarget: Identifiable, Equatable {
    let itemId: String
    var draft: String
    var id: String { itemId }

    init(itemId: String, currentTitle: String) {
        self.itemId = itemId
        self.draft = currentTitle
    }
}

/// The one rename prompt, used by the note's own screen (tap its title) and by the Library (a row's Rename… action). It is
/// the same alert the Collections sheet uses to rename a collection: a text field with the current name in it, Cancel,
/// and a confirming button. Leaving the field empty goes back to the automatic name, which the message says.
private struct SpokenNoteRenameAlert: ViewModifier {
    @Binding var target: SpokenNoteRenameTarget?
    @EnvironmentObject private var model: Gate1AppModel
    /// Called with the title the note has after the rename, so a screen showing it can follow.
    var onRenamed: (String) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename Note", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("Name", text: Binding(get: { target?.draft ?? "" }, set: { target?.draft = $0 }))
                    .accessibilityIdentifier("spokenNote.rename.field")
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let note = target else { return }
                    Task {
                        if let title = await model.renameSpokenNote(itemId: note.itemId, to: note.draft) { onRenamed(title) }
                    }
                }
                .accessibilityIdentifier("spokenNote.rename.confirm")
            } message: {
                Text("Only the name changes. The recording, the words and your Margins stay as they are. Leave it empty to use the automatic name.")
            }
    }
}

extension View {
    /// Shows the rename prompt while `target` is set. The note's title is changed in the Library, on Now, on the Lock Screen
    /// and in the names of exported files; `onRenamed` also tells the caller the new title.
    func spokenNoteRenameAlert(_ target: Binding<SpokenNoteRenameTarget?>, onRenamed: @escaping (String) -> Void = { _ in }) -> some View {
        modifier(SpokenNoteRenameAlert(target: target, onRenamed: onRenamed))
    }
}
