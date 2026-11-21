import Foundation

public struct WrittenMarginDraft: Equatable {
    public let capture: WrittenInterjectionCapture
    public var text: String
    public let itemTitle: String
    public let targetDescription: String
    public let progressPercent: Int
    /// The shared Margin this note answers, and whether the listener switched it to independent (#473).
    public var replyChoice = MarginReplyChoice()
    public var reply: MarginReplyDraft? { replyChoice.effective }

    public init(
        capture: WrittenInterjectionCapture,
        text: String,
        itemTitle: String,
        targetDescription: String,
        progressPercent: Int,
        replyChoice: MarginReplyChoice = MarginReplyChoice()
    ) {
        self.capture = capture
        self.text = text
        self.itemTitle = itemTitle
        self.targetDescription = targetDescription
        self.progressPercent = progressPercent
        self.replyChoice = replyChoice
    }

    public var captureID: String { capture.id }
    public var priorWasPlaying: Bool { capture.wasPlaying }
    public var lockedSessionID: String { capture.sessionId }
    public var lockedItemID: String { capture.itemId }
    public var lockedTargetID: String { capture.targetId }
}

public enum TimelinePullPresentation {
    public static let activationDistance: CGFloat = 72

    public static func overscrollDistance(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat = 0
    ) -> CGFloat {
        let maximumScrollOffset = max(-topInset, contentHeight + bottomInset - containerHeight)
        return max(0, contentOffsetY - maximumScrollOffset)
    }

    public static func shouldOpenTimeline(overscrollDistance: CGFloat) -> Bool {
        overscrollDistance >= activationDistance
    }
}

/// A tile in the Add sheet's top grid. Each is a different way in; none repeats another (#3217).
public enum AddSourceTile: String, CaseIterable, Identifiable, Hashable, Sendable {
    case linkOrPodcast
    case findPodcast
    case pastedText
    case importFromFiles
    case quickFolder
    case liveSession
    case spokenNote

    public var id: String { rawValue }

    /// The route a tile opens inside the sheet, for the tiles that swap the sheet's content.
    public var route: AddSourceRoute? {
        switch self {
        case .linkOrPodcast: .linkOrPodcast
        case .pastedText: .pastedText
        case .importFromFiles: .importFromFiles
        case .quickFolder: .quickFolder
        case .findPodcast, .liveSession, .spokenNote: nil
        }
    }

    public var title: String {
        switch self {
        case .findPodcast: "Find a Podcast"
        case .liveSession: "Live Session"
        case .spokenNote: "Spoken Note"
        default: route?.title ?? ""
        }
    }

    public var detail: String {
        switch self {
        case .linkOrPodcast: "A web article, podcast episode, feed, or public audio link"
        case .findPodcast: "Search podcasts by name"
        case .pastedText: "Words already copied to your clipboard"
        case .importFromFiles: "A document, book, transcript, audiobook or Margins packet"
        case .quickFolder: "A folder of eligible local files"
        case .liveSession: "Margins on a meeting or book"
        case .spokenNote: "Dictate an idea, then read it back"
        }
    }

    public var systemImage: String {
        switch self {
        case .findPodcast: "magnifyingglass"
        case .liveSession: "clock.badge"
        case .spokenNote: "mic"
        default: route?.systemImage ?? "plus"
        }
    }
}

public enum AddSourcePresentation {
    /// The grid's order: the two ways to bring in a podcast sit together, then the two from the device, then the rest, then a note of your own.
    public static let tiles: [AddSourceTile] = [
        .linkOrPodcast, .findPodcast,
        .pastedText, .importFromFiles,
        .quickFolder, .liveSession,
        .spokenNote
    ]

    /// Find a Podcast needs the catalog to open from the sheet; without that, the tile is left out.
    public static func tiles(canSearchPodcasts: Bool) -> [AddSourceTile] {
        canSearchPodcasts ? tiles : tiles.filter { $0 != .findPodcast }
    }
}

public enum TimelineProvenance: String, CaseIterable, Hashable, Sendable {
    case source
    case listeningMap
    case myMargin
    case sharedMargin
    case userResponse
    case assistantResponse

    public var label: String {
        switch self {
        case .source: "Chapter"
        case .listeningMap: "Listening map"
        case .myMargin: "My Margin"
        case .sharedMargin: "Shared Margin"
        case .userResponse: "My response"
        case .assistantResponse: "Assistant response"
        }
    }

    public var systemImage: String {
        switch self {
        case .source: "doc.text"
        case .listeningMap: "map"
        case .myMargin: "quote.bubble.fill"
        case .sharedMargin: "person.2.fill"
        case .userResponse: "person.crop.circle"
        case .assistantResponse: "sparkles"
        }
    }
}

public struct SharedMarginRow: Identifiable, Equatable, Sendable {
    public let interjection: ImportedCommentaryInterjection
    public let layer: ImportedCommentaryLayer
    public let itemTitle: String
    /// The item's placement work in flight, if any (#872).
    public var placement: SharedMarginPlacementPasses.Pass? = nil

    public init(
        interjection: ImportedCommentaryInterjection,
        layer: ImportedCommentaryLayer,
        itemTitle: String,
        placement: SharedMarginPlacementPasses.Pass? = nil
    ) {
        self.interjection = interjection
        self.layer = layer
        self.itemTitle = itemTitle
        self.placement = placement
    }

    public var id: String { "shared::\(layer.id)::\(interjection.id)" }
    public var placementStatus: SharedMarginPlacementStatus {
        SharedMarginPlacementStatus(resolution: interjection.resolution, marginId: interjection.id,
                                    layerStatus: layer.sourceResolutionStatus, pass: placement,
                                    hasPositionEvidence: interjection.carriesPositionEvidence(in: layer),
                                    awaitingPlacementPass: layer.awaitsPlacementPass)
    }
    /// Its voice hasn't played for this listener yet (#469), and it can (#3402).
    public var isNew: Bool { interjection.showsAsNew }
    /// The sender's name, or "a friend" when the file names nobody; a stand-in is never shown as a name (#3247).
    public var collectionLabel: String { SharedPacketArrival.senderName(layer.displayLabel) ?? "a friend" }
    /// Where it plays now (#3789): a podcast Margin says one of three plain phrases whatever the pass is doing.
    public var placementPlan: SharedMarginPlacementPlan { SharedMarginPrompts.plan(interjection, in: layer, durationMs: nil) }
    public var positionDescription: String {
        if let words = SharedMarginPlacementWording.line(for: interjection, in: layer, durationMs: nil) { return words }
        if let placing = placementStatus.positionDescription { return placing }
        return SharedMarginPlacementWording.line(for: interjection.resolution)
    }
}
