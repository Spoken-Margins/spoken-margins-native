import Foundation
import SessionKit
import SessionKitPersistence

/// The Paper note's reads and writes (#4340). The rules live in SessionKit (`PaperNoteSlots`, `SessionEngine.setPaperRole`,
/// `SessionEngine.changePaperAnswer`); this file reads what the section needs and carries the listener's taps to the engine.
extension Gate1AppModel {
    /// Whether `itemId` gets a Paper note: a PDF by its Library row (`PaperNoteSlots.isPaper`, so "x.pdf.docx" does not),
    /// or the open item with a PDF structure.
    func offersPaperNote(itemId: String) -> Bool {
        guard !itemId.isEmpty else { return false }
        if let row = libraryItems.first(where: { $0.id == itemId }) {
            return PaperNoteSlots.isPaper(mediaType: row.mediaType, sourceReference: row.sourceReference, sourceReferenceType: row.sourceReferenceType)
        }
        return selectedItem.id == itemId && selectedItem.documentStructure != nil
    }

    /// Whether the open paper's Write it is on, from what the model holds (no read): a listening session Continue would
    /// resume, and text to place an answer in (Default 6 of the Design).
    var canWritePaperAnswer: Bool {
        !selectedItem.text.isEmpty
            && PaperNotePlace.session(addedAgainAt: addedAgainAt(forItem: selectedItem.id), sessions: selectedItem.sessions) != nil
    }

    /// What the Write sheet places answers with: the open paper's saved item (its full text), its sessions and `document`,
    /// read off the main thread. Nil when the item can't be read.
    func paperNoteWriteContext(document: StructuredDocument?) async -> PaperNoteWriteContext? {
        guard let store else { return nil }
        let id = selectedItem.id
        let addedAgain = addedAgainAt(forItem: id)
        return await Task.detached(priority: .userInitiated) { () -> PaperNoteWriteContext? in
            guard let item = try? store.loadItem(id: id), let sessions = try? store.loadSessions(itemId: id) else { return nil }
            return PaperNoteWriteContext(item: item, document: document, sessions: sessions, addedAgainAt: addedAgain)
        }.value
    }

    /// "Save" on the Write sheet: a written Margin carrying `role`, at `choice`, on the session "Where you are" reads.
    /// `draftId` is made when the prompt opens, so a second tap writes nothing more. The playing item, the playhead and
    /// the session's place are untouched (`SessionEngine.addWrittenInterjection`). Returns false, writing nothing, when
    /// the place can't be found or the save fails; the sheet keeps the text and says so.
    ///
    /// With `replacing` ("Change answer" › Write it) the Margin is saved without a role and then takes it from the old
    /// answer in one transaction (`changePaperAnswer`), so the slot never shows both. A retry after a failed move finds
    /// the Margin already saved under the same draft id and only moves the role.
    func writePaperAnswer(
        draftId: String, role: PaperNoteRole, text: String, choice: PaperNotePlace.Choice, context: PaperNoteWriteContext,
        replacing: Interjection? = nil
    ) -> Bool {
        guard let session = context.session, let character = try? context.character(for: choice) else { return false }
        var saved: Interjection?
        guard run({ engine in
            let written = try engine.addWrittenInterjection(
                id: draftId, sessionId: session.id, atCharacter: character, text: text,
                paperRole: replacing == nil ? role : nil)
            if let old = replacing {
                try engine.changePaperAnswer(
                    role, interjectionId: written.id, sessionId: written.sessionId, replacing: (old.id, old.sessionId))
                saved = written
                saved?.paperRole = role
            } else {
                saved = written
            }
        }), let saved else { return false }
        if let old = replacing, let index = selectedItem.interjections.firstIndex(where: { $0.id == old.id && $0.sessionId == old.sessionId }),
           selectedItem.interjections[index].paperRole == role {
            selectedItem.interjections[index].paperRole = nil
        }
        // Show the answer in its slot at once; the background reads bring the Margins tab and the rest.
        if selectedItem.id == saved.itemId,
           !selectedItem.interjections.contains(where: { $0.id == saved.id && $0.sessionId == saved.sessionId }) {
            selectedItem.interjections.append(saved)
        }
        refreshMarginRowsInBackground(forItem: saved.itemId)
        refreshSelectedItemInBackground()
        return true
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
