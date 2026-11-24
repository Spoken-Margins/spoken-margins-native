import Foundation
import SessionKit
import SessionKitPersistence

/// The Paper note's reads and writes (#4340). The rules live in SessionKit (`PaperNoteSlots`, `SessionEngine.setPaperRole`,
/// `SessionEngine.changePaperAnswer`); this file reads what the section needs and carries the listener's taps to the engine.
extension Gate1AppModel {
    /// Whether `itemId` gets a Paper note: a PDF, by its Library row, or the open item with a PDF structure.
    func offersPaperNote(itemId: String) -> Bool {
        guard !itemId.isEmpty else { return false }
        if let row = libraryItems.first(where: { $0.id == itemId }), LibraryQueryEngine.isPDF(row) { return true }
        return selectedItem.id == itemId && selectedItem.documentStructure != nil
    }

    /// The open paper's section, from what the model holds: its title, the Library row's author, the PDF's bibliography
    /// and the listener's own Margins on it. `document` gives each answer its page.
    func paperNoteSlots(document: StructuredDocument?) -> PaperNoteSlots {
        let id = selectedItem.id
        return PaperNoteSlots(paper: .init(
            itemId: id, title: selectedItem.title,
            author: libraryItems.first(where: { $0.id == id })?.author,
            bibliography: selectedItem.documentStructure?.bibliography,
            document: document, margins: ownMargins(itemId: id)
        ))
    }

    /// The paper's structured document, read off the main thread, for the answers' pages. Nil when it has none.
    func paperNoteDocument(itemId: String) async -> StructuredDocument? {
        guard let store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? store.loadStructuredDocument(itemId: itemId)
        }.value
    }

    /// Gives a Margin a Paper note role, or takes it off with nil: "Choose a Margin" on an empty slot, "Remove from paper
    /// note", and the details screen's Paper note row.
    func setPaperRole(_ role: PaperNoteRole?, for margin: Interjection) {
        guard run({ engine in try engine.setPaperRole(role, interjectionId: margin.id, sessionId: margin.sessionId) }) else { return }
        publishPaperRole(role, marginId: margin.id, sessionId: margin.sessionId)
    }

    /// "Change answer": `margin` takes the slot's role and `replacing`, the Margin that answered it, gives it up; the old
    /// Margin stays. One write, so the slot never shows both or neither.
    func changePaperAnswer(_ role: PaperNoteRole, to margin: Interjection, replacing old: Interjection) {
        guard run({ engine in
            try engine.changePaperAnswer(
                role, interjectionId: margin.id, sessionId: margin.sessionId, replacing: (old.id, old.sessionId))
        }) else { return }
        publishPaperRole(role, marginId: margin.id, sessionId: margin.sessionId)
        if (old.id, old.sessionId) != (margin.id, margin.sessionId) {
            // The engine took the role off only if the old Margin still held it; the saved row says which.
            let saved = store.flatMap { try? $0.loadInterjections(sessionId: old.sessionId) }?.first { $0.id == old.id }
            publishPaperRole(saved?.paperRole, marginId: old.id, sessionId: old.sessionId)
        }
    }

    /// Shows a saved role at once: the open item's copy (which `ownMargins` reads first) and the Margins row, then the
    /// background read brings the rest. Only the role is copied, as the sharing star does (#2505).
    private func publishPaperRole(_ role: PaperNoteRole?, marginId: String, sessionId: String) {
        if let index = selectedItem.interjections.firstIndex(where: { $0.id == marginId && $0.sessionId == sessionId }) {
            selectedItem.interjections[index].paperRole = role
        }
        refreshMarginRow(sessionId: sessionId, interjectionId: marginId)
        refreshSelectedItemInBackground()
    }
}
