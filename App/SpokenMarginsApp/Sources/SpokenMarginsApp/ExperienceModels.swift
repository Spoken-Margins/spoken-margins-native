import Foundation
import SessionKit

struct WrittenMarginDraft: Equatable {
    let capture: WrittenInterjectionCapture
    var text: String
    let itemTitle: String
    let targetDescription: String
    let progressPercent: Int
    /// The shared Margin this note answers, and whether the listener switched it to independent (#473).
    var replyChoice = MarginReplyChoice()
    var reply: MarginReplyDraft? { replyChoice.effective }

    var captureID: String { capture.id }
    var priorWasPlaying: Bool { capture.wasPlaying }
    var lockedSessionID: String { capture.sessionId }
    var lockedItemID: String { capture.itemId }
    var lockedTargetID: String { capture.targetId }
}

enum TimelinePullPresentation {
    static let activationDistance: CGFloat = 72

    static func overscrollDistance(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat = 0
    ) -> CGFloat {
        let maximumScrollOffset = max(-topInset, contentHeight + bottomInset - containerHeight)
        return max(0, contentOffsetY - maximumScrollOffset)
    }

    static func shouldOpenTimeline(overscrollDistance: CGFloat) -> Bool {
        overscrollDistance >= activationDistance
    }
}

/// A tile in the Add sheet's top grid. Each is a different way in; none repeats another (#3217).
enum AddSourceTile: String, CaseIterable, Identifiable, Hashable, Sendable {
    case linkOrPodcast
    case findPodcast
    case pastedText
    case importFromFiles
    case quickFolder
    case liveSession
    case spokenNote

    var id: String { rawValue }

    /// The route a tile opens inside the sheet, for the tiles that swap the sheet's content.
    var route: AddSourceRoute? {
        switch self {
        case .linkOrPodcast: .linkOrPodcast
        case .pastedText: .pastedText
        case .importFromFiles: .importFromFiles
        case .quickFolder: .quickFolder
        case .findPodcast, .liveSession, .spokenNote: nil
        }
    }

    var title: String {
        switch self {
        case .findPodcast: "Find a Podcast"
        case .liveSession: "Live Session"
        case .spokenNote: "Spoken Note"
        default: route?.title ?? ""
        }
    }

    var detail: String {
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

    var systemImage: String {
        switch self {
        case .findPodcast: "magnifyingglass"
        case .liveSession: "clock.badge"
        case .spokenNote: "mic"
        default: route?.systemImage ?? "plus"
        }
    }
}

enum AddSourcePresentation {
    /// The grid's order: the two ways to bring in a podcast sit together, then the two from the device, then the rest, then a note of your own.
    static let tiles: [AddSourceTile] = [
        .linkOrPodcast, .findPodcast,
        .pastedText, .importFromFiles,
        .quickFolder, .liveSession,
        .spokenNote
    ]

    /// Find a Podcast needs the catalog to open from the sheet; without that, the tile is left out.
    static func tiles(canSearchPodcasts: Bool) -> [AddSourceTile] {
        canSearchPodcasts ? tiles : tiles.filter { $0 != .findPodcast }
    }
}

enum TimelineProvenance: String, CaseIterable, Hashable, Sendable {
    case source
    case listeningMap
    case myMargin
    case sharedMargin
    case userResponse
    case assistantResponse

    var label: String {
        switch self {
        case .source: "Chapter"
        case .listeningMap: "Listening map"
        case .myMargin: "My Margin"
        case .sharedMargin: "Shared Margin"
        case .userResponse: "My response"
        case .assistantResponse: "Assistant response"
        }
    }

    var systemImage: String {
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

struct MarginRow: Identifiable, Equatable, Sendable {
    let interjection: Interjection
    let itemTitle: String
    let sessionDate: Date?
    /// The chapter the Margin was made in and, for text, its paragraph number (#777). nil when the item has no
    /// chapters or the position isn't a paragraph.
    var place: MarginPlaces.Place? = nil

    var id: String { "\(interjection.sessionId)::\(interjection.id)" }
    var isWritten: Bool { interjection.captureKind == .written }
    var fullText: String {
        [interjection.displayText, interjection.cleanedTranscript, interjection.transcript]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? preview
    }

    var preview: String {
        for value in [interjection.displayText, interjection.cleanedTranscript, interjection.transcript] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return needsAttention ? attentionDescription : "Audio Margin"
    }

    var needsAttention: Bool {
        if isWritten { return false }
        let transcriptReady = ["transcribed", "complete"].contains(interjection.transcriptionStatus)
        let contextFailed = interjection.anchorContextStatus == .unavailable
        return !transcriptReady || contextFailed || interjection.audioStatus == "missing"
    }

    var canPlayRecording: Bool { !isWritten && interjection.audioPath != nil }
    var canRetryTranscription: Bool { !isWritten && !["transcribed", "complete"].contains(interjection.transcriptionStatus) && interjection.audioPath != nil }

    /// A voice Margin whose transcript can't be made until Speech Recognition is back on (#268).
    var transcriptWaitsForSpeechRecognition: Bool {
        canRetryTranscription && interjection.transcriptionStatus == "failed" && SpeechRecognitionAccess.isOff
    }

    var attentionDescription: String {
        TranscriptionFailureWording.marginAttention(
            transcriptionStatus: interjection.transcriptionStatus,
            speechRecognitionOff: SpeechRecognitionAccess.isOff,
            contextUnavailable: interjection.anchorContextStatus == .unavailable,
            recordingMissing: interjection.audioStatus == "missing"
        )
    }

    /// The row's second line: where the Margin was made, then the day (#777). Responses and summaries keep their label.
    func placeDescription(now: Date = Date()) -> String {
        guard interjection.targetType == .item else { return "\(targetDescription) · \(interjection.roughPercent)%" }
        return MarginRowWording.placeLine(
            placeName: place?.chapterName, mediaTimeMs: interjection.anchor.mediaTimeMs,
            meetingClockMs: place?.meetingClockMs,
            paragraph: place?.paragraph, roughPercent: interjection.roughPercent,
            createdAt: interjection.createdAt, now: now)
    }

    /// Set when a call, Siri, the headphones or a closed app ended this recording early, until the listener opens it (#1976).
    var cutShort: CutShortMark? {
        CutShortMargins.shared.mark(sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    /// The row's headline: what needs attention, else where it was made, led by "Cut short" or "Recovered" while that
    /// mark is on. A recovered Margin always waits on its transcript, so the mark can't be shown only when nothing does.
    func captionDescription(now: Date = Date()) -> String {
        [cutShort?.tag, needsAttention ? attentionDescription : placeDescription(now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    var targetDescription: String {
        switch interjection.targetType {
        case .item: "Source"
        case .assistantTurn: "Assistant response"
        case .summaryTurn: "Margin summary"
        }
    }
}

struct SharedMarginRow: Identifiable, Equatable, Sendable {
    let interjection: ImportedCommentaryInterjection
    let layer: ImportedCommentaryLayer
    let itemTitle: String
    /// The item's placement work in flight, if any (#872).
    var placement: SharedMarginPlacementPasses.Pass? = nil

    var id: String { "shared::\(layer.id)::\(interjection.id)" }
    var placementStatus: SharedMarginPlacementStatus {
        SharedMarginPlacementStatus(resolution: interjection.resolution, marginId: interjection.id,
                                    layerStatus: layer.sourceResolutionStatus, pass: placement,
                                    hasPositionEvidence: interjection.carriesPositionEvidence(in: layer),
                                    awaitingPlacementPass: layer.awaitsPlacementPass)
    }
    /// Its voice hasn't played for this listener yet (#469), and it can (#3402).
    var isNew: Bool { interjection.showsAsNew }
    /// The sender's name, or "a friend" when the file names nobody; a stand-in is never shown as a name (#3247).
    var collectionLabel: String { SharedPacketArrival.senderName(layer.displayLabel) ?? "a friend" }
    /// Where it plays now (#3789): a podcast Margin says one of three plain phrases whatever the pass is doing.
    var placementPlan: SharedMarginPlacementPlan { SharedMarginPrompts.plan(interjection, in: layer, durationMs: nil) }
    var positionDescription: String {
        if let words = SharedMarginPlacementWording.line(for: interjection, in: layer, durationMs: nil) { return words }
        if let placing = placementStatus.positionDescription { return placing }
        return SharedMarginPlacementWording.line(for: interjection.resolution)
    }
}
