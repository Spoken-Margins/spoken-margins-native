import Foundation
import SessionKit
import SessionKitPersistence
import SwiftUI

/// Which sentences of a spoken note carry the listener's Margins (#3664). The note screen reads it to mark a sentence a
/// Margin was added on. It holds no Margins of its own: it reads them from the database off the main thread and keeps only
/// how many sit on each sentence. A sentence is found by its id, so the mark stays on the same words when the note's audio
/// is joined again after a take is added.
@MainActor
final class SpokenNoteMarginsModel: ObservableObject {
    @Published private(set) var countsBySentence: [SpokenNote.SentenceRef: Int] = [:]

    private var requests = 0

    /// Reads the note's Margins again and places them on `timeline`. A note never played has no timeline and no Margins.
    func refresh(noteId: String, timeline: SpokenNoteWholeTimeline?, app: Gate1AppModel) {
        requests += 1
        let request = requests
        guard let timeline, let store = app.store else {
            if !countsBySentence.isEmpty { countsBySentence = [:] }
            return
        }
        let itemId = SpokenNoteItem.itemId(forNoteId: noteId)
        Task {
            let counts = await Task.detached(priority: .utility) { () -> [SpokenNote.SentenceRef: Int] in
                guard let margins = try? store.loadInterjections(itemId: itemId) else { return [:] }
                return SpokenNoteMargins.marginIdsBySentence(margins, itemId: itemId, on: timeline).mapValues(\.count)
            }.value
            // Reads can finish out of order: only the newest request's answer is kept.
            if request == requests, counts != countsBySentence { countsBySentence = counts }
        }
    }
}
