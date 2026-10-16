import Foundation
import SessionKit

struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    var externalReferenceType = ""
    var overview = ""
    var navigation: [CanonicalNavigationNode] = []
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var listeningMapScenes: [MediaTimelineChapter] = []
    var mediaDurationMs: Int?
    /// The scenes came from the server's community map (#553), not this phone or the publisher.
    var listeningMapIsCommunity: Bool { listeningMapScenes.first.map { CommunityMapConverter.isCommunitySceneId($0.id) } ?? false }
    var listeningMapAvailabilityDescription: String {
        let scenes = "\(listeningMapScenes.count) scene\(listeningMapScenes.count == 1 ? "" : "s")"
        return listeningMapIsCommunity ? "This item has a community map with \(scenes)." : "This item has a private Listening Map with \(scenes)."
    }
    /// The page this item was added from, when it has a public one (#1167).
    var originalSourceURL: URL? {
        OriginalSourceLink.url(externalReference: externalReference, externalReferenceType: externalReferenceType)
    }
    var isNativeAudio = false
    var timelineSource = TimelineSourceContent(text: "")
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
