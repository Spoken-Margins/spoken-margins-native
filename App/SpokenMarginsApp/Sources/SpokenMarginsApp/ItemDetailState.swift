import Foundation
import SessionKit

struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    var overview = ""
    var navigation: [CanonicalNavigationNode] = []
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var listeningMapScenes: [MediaTimelineChapter] = []
    /// The scenes came from the server's community map (#553), not this phone or the publisher.
    var listeningMapIsCommunity = false
    var mediaDurationMs: Int?
    var isNativeAudio = false
    var documentStructure: PDFDocumentStructure?
    var sessions: [Session] = []
    var sessionRows: [SessionPresentation] = []
    var interjections: [Interjection] = []
    var importedCommentaryLayers: [ImportedCommentaryLayer] = []
    var importedCommentaryInterjections: [String: [ImportedCommentaryInterjection]] = [:]
    var sharedMarginPlacement: SharedMarginPlacementPasses.Pass?
    var turns: [ConversationTurn] = []
}

struct SessionPresentation: Identifiable {
    let session: Session
    let interjectionCount: Int
    let interjectionPreview: String?

    var id: String { session.id }
}
