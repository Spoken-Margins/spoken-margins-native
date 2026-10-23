import Foundation

/// Everything the item screen shows for one item, prepared off the store so rendering never reads it.
/// Lives in SessionKit so `ItemDetailLoader` can be host-tested (moved from the app target, #318).
public struct ItemDetailState: Equatable, Sendable {
    public var id = ""
    public var title = ""
    public var status = ""
    public var text = ""
    public var externalReference = ""
    /// The feed's publication date as a readable date, and the opening of its description (#1322). Nil when unknown.
    public var publishedDateText: String?
    public var descriptionText: String?
    public var externalReferenceType = ""
    public var overview = ""
    public var navigation: [CanonicalNavigationNode] = []
    public var chapters: [Chapter] = []
    public var mediaChapters: [MediaTimelineChapter] = []
    public var listeningMapScenes: [MediaTimelineChapter] = []
    /// The same scenes with their end times and summaries, for the podcast Now view (#1629).
    public var listeningMapSummarySpans: [SceneSummarySpan] = []
    public var mediaDurationMs: Int?
    /// The scenes came from the server's community map (#553), not this phone or the publisher.
    public var listeningMapIsCommunity: Bool { listeningMapScenes.first.map { CommunityMapConverter.isCommunitySceneId($0.id) } ?? false }
    public var listeningMapAvailabilityDescription: String {
        let scenes = "\(listeningMapScenes.count) scene\(listeningMapScenes.count == 1 ? "" : "s")"
        return listeningMapIsCommunity ? "This item has a community map with \(scenes)." : "This item has a private Listening Map with \(scenes)."
    }
    /// The page this item was added from, when it has a public one (#1167).
    public var originalSourceURL: URL? {
        OriginalSourceLink.url(externalReference: externalReference, externalReferenceType: externalReferenceType)
    }
    public var isNativeAudio = false
    public var timelineSource = TimelineSourceContent(text: "")
    public var documentStructure: PDFDocumentStructure?
    public var sessions: [Session] = []
    public var sessionRows: [SessionPresentation] = []
    public var interjections: [Interjection] = []
    public var importedCommentaryLayers: [ImportedCommentaryLayer] = []
    public var importedCommentaryInterjections: [String: [ImportedCommentaryInterjection]] = [:]
    public var sharedMarginPlacement: SharedMarginPlacementPasses.Pass?
    public var turns: [ConversationTurn] = []

    public init(
        id: String = "",
        title: String = "",
        status: String = "",
        text: String = "",
        externalReference: String = "",
        publishedDateText: String? = nil,
        descriptionText: String? = nil,
        externalReferenceType: String = "",
        overview: String = "",
        navigation: [CanonicalNavigationNode] = [],
        chapters: [Chapter] = [],
        mediaChapters: [MediaTimelineChapter] = [],
        listeningMapScenes: [MediaTimelineChapter] = [],
        listeningMapSummarySpans: [SceneSummarySpan] = [],
        mediaDurationMs: Int? = nil,
        isNativeAudio: Bool = false,
        timelineSource: TimelineSourceContent = TimelineSourceContent(text: ""),
        documentStructure: PDFDocumentStructure? = nil,
        sessions: [Session] = [],
        sessionRows: [SessionPresentation] = [],
        interjections: [Interjection] = [],
        importedCommentaryLayers: [ImportedCommentaryLayer] = [],
        importedCommentaryInterjections: [String: [ImportedCommentaryInterjection]] = [:],
        sharedMarginPlacement: SharedMarginPlacementPasses.Pass? = nil,
        turns: [ConversationTurn] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.text = text
        self.externalReference = externalReference
        self.publishedDateText = publishedDateText
        self.descriptionText = descriptionText
        self.externalReferenceType = externalReferenceType
        self.overview = overview
        self.navigation = navigation
        self.chapters = chapters
        self.mediaChapters = mediaChapters
        self.listeningMapScenes = listeningMapScenes
        self.listeningMapSummarySpans = listeningMapSummarySpans
        self.mediaDurationMs = mediaDurationMs
        self.isNativeAudio = isNativeAudio
        self.timelineSource = timelineSource
        self.documentStructure = documentStructure
        self.sessions = sessions
        self.sessionRows = sessionRows
        self.interjections = interjections
        self.importedCommentaryLayers = importedCommentaryLayers
        self.importedCommentaryInterjections = importedCommentaryInterjections
        self.sharedMarginPlacement = sharedMarginPlacement
        self.turns = turns
    }
}

public struct SessionPresentation: Identifiable, Equatable, Sendable {
    public let session: Session
    public let interjectionCount: Int
    public let interjectionPreview: String?

    public init(session: Session, interjectionCount: Int, interjectionPreview: String?) {
        self.session = session
        self.interjectionCount = interjectionCount
        self.interjectionPreview = interjectionPreview
    }

    public var id: String { session.id }
}
