import Foundation
import SessionKit

struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    /// The feed's publication date as a readable date, and the opening of its description (#1322). Nil when unknown.
    var publishedDateText: String?
    var descriptionText: String?
    var overview = ""
    var navigation: [CanonicalNavigationNode] = []
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var listeningMapScenes: [MediaTimelineChapter] = []
    /// The same scenes with their end times and summaries, for the podcast Now view (#1629).
    var listeningMapSummarySpans: [SceneSummarySpan] = []
    var mediaDurationMs: Int?
    /// The scenes came from the server's community map (#553), not this phone or the publisher.
    var listeningMapIsCommunity: Bool { listeningMapScenes.first.map { CommunityMapConverter.isCommunitySceneId($0.id) } ?? false }
    var listeningMapAvailabilityDescription: String {
        let scenes = "\(listeningMapScenes.count) scene\(listeningMapScenes.count == 1 ? "" : "s")"
        return listeningMapIsCommunity ? "This item has a community map with \(scenes)." : "This item has a private Listening Map with \(scenes)."
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
