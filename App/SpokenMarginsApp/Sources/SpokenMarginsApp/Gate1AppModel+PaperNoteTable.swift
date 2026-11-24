import Foundation
import SessionKit
import SessionKitPersistence

/// The Margins tab's "Paper notes table" export (#4340): one row per paper with a Paper note, in the tab's scope. The
/// table and its files are SessionKit's (`PaperNoteTable`, `PaperNoteTableExport`); this file gathers the papers from what
/// the model holds and reads each paper's bibliography and structure off the main thread.
extension Gate1AppModel {
    /// The papers in the Library that the tab's collection or item scope includes.
    func paperNotesTableScope() -> Set<String> {
        let papers = libraryItems.lazy
            .filter { PaperNoteSlots.isPaper(mediaType: $0.mediaType, sourceReference: $0.sourceReference, sourceReferenceType: $0.sourceReferenceType) }
            .map(\.id)
        return PaperNoteTableExport.scope(marginCollectionQuery, itemIDs: papers)
    }

    /// Whether the export has a row to give: the menu item is off otherwise.
    var hasPaperNotesInScope: Bool {
        // Most Libraries have no answer at all: say so before walking the Library rows on every redraw of the tab.
        guard marginRows.contains(where: { $0.interjection.paperRole != nil }) else { return false }
        return PaperNoteTableExport.hasAnswers(marginRows.lazy.map(\.interjection), scope: paperNotesTableScope())
    }

    /// Builds the table for the tab's scope and writes it as `format`, for the share sheet. Each paper's item and
    /// structured document are read off the main thread. Nil, with the failure reported, when nothing could be written.
    func preparePaperNotesTableFileURL(format: PaperNoteTableExport.Format) async -> URL? {
        let scope = paperNotesTableScope()
        let margins = Dictionary(grouping: marginRows.lazy.map(\.interjection).filter { $0.paperRole != nil && scope.contains($0.itemId) }, by: \.itemId)
        let rows = libraryItems.filter { margins[$0.id] != nil }.map { (id: $0.id, title: $0.title, author: $0.author) }
        guard let store, !rows.isEmpty else {
            reportFailure(PaperNoteTableExport.failed)
            return nil
        }
        let directory = MarginMarkdownShare.shareDirectory
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result {
                let papers = rows.map { row in
                    PaperNoteTable.Paper(
                        itemId: row.id, title: row.title, author: row.author,
                        bibliography: (try? store.loadItem(id: row.id))?.documentStructure?.bibliography,
                        document: try? store.loadStructuredDocument(itemId: row.id),
                        margins: margins[row.id] ?? []
                    )
                }
                return try PaperNoteTableExport.write(PaperNoteTable(papers: papers, scope: scope), format: format, under: directory)
            }
        }.value
        switch outcome {
        case .success(let url): return url
        case .failure(let error):
            reportFailure(error, context: "Paper notes table export failed")
            return nil
        }
    }
}
