import Foundation

public enum SessionKitError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidCommandForCapability(String)
    case invalidCommandForState(String)
    case missingFixture(String)
    case persistenceFailed(String)

    public var description: String {
        switch self {
        case .invalidCommandForCapability(let command):
            return "invalid_command_for_capability:\(command)"
        case .invalidCommandForState(let command):
            return "invalid_command_for_state:\(command)"
        case .missingFixture(let id):
            return "missing_fixture:\(id)"
        case .persistenceFailed(let message):
            return "persistence_failed:\(message)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case itemPlayback = "item_playback"
    case recordingInterjection = "recording_interjection"
    case interjectionSummary = "interjection_summary"
    case summaryPlayback = "summary_playback"
    case addendumCapture = "addendum_capture"
    case aiResponsePlayback = "ai_response_playback"
    case conversation
    case finished
    case abandoned
}

public enum PlaybackStatus: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case playing
    case paused
    case recording
    case failed
}

public extension PlaybackStatus {
    var isPlaybackActive: Bool {
        self == .starting || self == .playing
    }
}

public enum PlaybackStartStatus: Equatable, Sendable {
    case confirmed
    case pending
    case failed(String)
}

public enum PlaybackTransportState: String, Codable, Equatable, Sendable {
    case playing
    case paused
    case waiting
    case stopped
    case failed
}

public struct MediaSeekRequest: Equatable, Sendable {
    public var id: Int
    public var targetId: String?
    public var requestedMediaTimeMs: Int

    public init(id: Int, targetId: String?, requestedMediaTimeMs: Int) {
        self.id = id
        self.targetId = targetId
        self.requestedMediaTimeMs = max(0, requestedMediaTimeMs)
    }
}

public enum MediaSeekResolution: Equatable, Sendable {
    case pending
    case accepted(mediaTimeMs: Int)
    case failed(actualMediaTimeMs: Int?, reason: String)
}

public enum TargetType: String, Codable, Equatable, Sendable {
    case itemTextTTS = "item_text_tts"
    case transcriptBackedMedia = "transcript_backed_media"
    case assistantTurnTTS = "assistant_turn_tts"
    case summaryTurnTTS = "summary_turn_tts"
    case browserOwnedMedia = "browser_owned_media"
}

public enum InterjectionTargetType: String, Codable, Equatable, Sendable {
    case item
    case summaryTurn = "summary_turn"
    case assistantTurn = "assistant_turn"
}

public enum InterjectionCaptureKind: String, Codable, Equatable, Sendable {
    case audio
    case written
}

public enum AnchorType: String, Codable, Equatable, Sendable {
    case text
    case transcript
    case media
    case turn
}

public enum AnchorConfidence: String, Codable, Equatable, Sendable {
    case transcriptSpan = "transcript_span"
    case mediaTime = "media_time"
    case textRange = "text_range"
    case providerMetadata = "provider_metadata"
    case localFallback = "local_fallback"
}

public enum AudioSourceType: String, Codable, Equatable, Sendable {
    case generatedTTSRealtime = "generated_tts_realtime"
    case generatedTTSPrerendered = "generated_tts_prerendered"
    case nativeMediaFile = "native_media_file"
    case browserOwnedMedia = "browser_owned_media"
    case remoteStream = "remote_stream"
}

public struct SourceLink: Codable, Equatable, Sendable {
    public var url: String
    public var provider: String?
    public var title: String?
    public var role: String

    public init(url: String, provider: String? = nil, title: String? = nil, role: String = "source") {
        self.url = url
        self.provider = provider
        self.title = title
        self.role = role
    }
}

public enum PublisherChapterSource: String, Codable, Equatable, Sendable, CaseIterable {
    case podcasting20JSON = "podcasting_2_json"
    case podloveSimpleChapters = "podlove_simple_chapters"
    case embeddedMedia = "embedded_media"
    case timestampedDescription = "timestamped_description"

    public var precedence: Int {
        switch self {
        case .podcasting20JSON: return 4
        case .podloveSimpleChapters: return 3
        case .embeddedMedia: return 2
        case .timestampedDescription: return 1
        }
    }
}

public struct SourceChapterLink: Codable, Equatable, Sendable {
    public var url: String
    public var type: String

    public init(url: String, type: String) {
        self.url = url
        self.type = type
    }
}

public struct PublisherChapter: Codable, Equatable, Sendable {
    public var title: String
    public var description: String?
    public var startMs: Int
    public var endMs: Int?

    public init(title: String, description: String? = nil, startMs: Int, endMs: Int? = nil) {
        self.title = title
        self.description = description
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct PublisherChapterCollection: Codable, Equatable, Sendable {
    public var source: PublisherChapterSource
    public var chapters: [PublisherChapter]

    public init(source: PublisherChapterSource, chapters: [PublisherChapter]) {
        self.source = source
        self.chapters = chapters
    }
}

public enum LinkResolutionStatus: String, Codable, Equatable, Sendable {
    case resolving
    case playable
    case needsReview = "needs_review"
    case unsupported
}

public struct LinkResolutionCandidate: Codable, Equatable, Sendable {
    public var sourceLink: SourceLink
    public var title: String
    public var showTitle: String?
    public var durationMs: Int?
    public var publishedAt: String?
    /// The feed's `<guid>` for the episode, or Apple's `episodeGuid` (#177).
    public var episodeGUID: String?
    public var audioURL: String?
    public var transcriptLinks: [SourceTranscriptLink]
    public var chapterLinks: [SourceChapterLink]
    public var publisherChapterCollections: [PublisherChapterCollection]
    public var confidence: Double

    public init(
        sourceLink: SourceLink,
        title: String,
        showTitle: String? = nil,
        durationMs: Int? = nil,
        publishedAt: String? = nil,
        episodeGUID: String? = nil,
        audioURL: String? = nil,
        transcriptLinks: [SourceTranscriptLink] = [],
        chapterLinks: [SourceChapterLink] = [],
        publisherChapterCollections: [PublisherChapterCollection] = [],
        confidence: Double
    ) {
        self.sourceLink = sourceLink
        self.title = title
        self.showTitle = showTitle
        self.durationMs = durationMs
        self.publishedAt = publishedAt
        self.episodeGUID = episodeGUID
        self.audioURL = audioURL
        self.transcriptLinks = transcriptLinks
        self.chapterLinks = chapterLinks
        self.publisherChapterCollections = publisherChapterCollections
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLink
        case title
        case showTitle
        case durationMs
        case publishedAt
        case episodeGUID
        case audioURL
        case transcriptLinks
        case chapterLinks
        case publisherChapterCollections
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLink = try container.decode(SourceLink.self, forKey: .sourceLink)
        title = try container.decode(String.self, forKey: .title)
        showTitle = try container.decodeIfPresent(String.self, forKey: .showTitle)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        episodeGUID = try container.decodeIfPresent(String.self, forKey: .episodeGUID)
        audioURL = try container.decodeIfPresent(String.self, forKey: .audioURL)
        transcriptLinks = try container.decodeIfPresent([SourceTranscriptLink].self, forKey: .transcriptLinks) ?? []
        chapterLinks = try container.decodeIfPresent([SourceChapterLink].self, forKey: .chapterLinks) ?? []
        publisherChapterCollections = try container.decodeIfPresent([PublisherChapterCollection].self, forKey: .publisherChapterCollections) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
    }
}

public struct SourceTranscriptLink: Codable, Equatable, Sendable {
    public var url: String
    public var type: String
    public var language: String?
    public var rel: String?

    public init(url: String, type: String, language: String? = nil, rel: String? = nil) {
        self.url = url
        self.type = type
        self.language = language
        self.rel = rel
    }
}

public struct LinkResolutionRequest: Codable, Equatable, Sendable {
    public var id: String
    public var inputURL: String
    public var sourceSurface: String
    public var createdAt: Date

    public init(id: String, inputURL: String, sourceSurface: String, createdAt: Date) {
        self.id = id
        self.inputURL = inputURL
        self.sourceSurface = sourceSurface
        self.createdAt = createdAt
    }
}

public struct LinkResolutionResult: Codable, Equatable, Sendable {
    public var requestId: String
    public var status: LinkResolutionStatus
    public var originalLink: SourceLink
    public var selectedCandidate: LinkResolutionCandidate?
    public var candidates: [LinkResolutionCandidate]
    public var failureReason: String?

    public init(
        requestId: String,
        status: LinkResolutionStatus,
        originalLink: SourceLink,
        selectedCandidate: LinkResolutionCandidate? = nil,
        candidates: [LinkResolutionCandidate] = [],
        failureReason: String? = nil
    ) {
        self.requestId = requestId
        self.status = status
        self.originalLink = originalLink
        self.selectedCandidate = selectedCandidate
        self.candidates = candidates
        self.failureReason = failureReason
    }
}

public struct AudioRepresentation: Codable, Equatable, Sendable {
    public var id: String
    public var sourceType: AudioSourceType
    public var url: String?
    public var durationMs: Int?
    public var transcriptId: String?

    public init(id: String, sourceType: AudioSourceType, url: String? = nil, durationMs: Int? = nil, transcriptId: String? = nil) {
        self.id = id
        self.sourceType = sourceType
        self.url = url
        self.durationMs = durationMs
        self.transcriptId = transcriptId
    }
}

public struct PreparedTextAudio: Codable, Equatable, Sendable {
    public var normalizedText: String
    public var media: ItemMedia
    public var timeline: TranscriptTimeline
    public var createdAt: Date

    public init(normalizedText: String, media: ItemMedia, timeline: TranscriptTimeline, createdAt: Date = Date()) {
        self.normalizedText = normalizedText
        self.media = media
        self.timeline = timeline
        self.createdAt = createdAt
    }
}

public struct PlaybackPosition: Codable, Equatable, Sendable {
    public var itemId: String?
    public var targetType: TargetType?
    public var targetId: String?
    public var mediaTimeMs: Int?
    public var durationMs: Int?
    public var textStart: Int?
    public var textEnd: Int?
    public var transcriptSegmentId: String?
    public var chapterId: String?
    public var sourceLocator: SourceLocator?
    public var playbackRate: Double
    public var anchorConfidence: AnchorConfidence

    public init(
        itemId: String? = nil,
        targetType: TargetType? = nil,
        targetId: String? = nil,
        mediaTimeMs: Int? = nil,
        durationMs: Int? = nil,
        textStart: Int? = nil,
        textEnd: Int? = nil,
        transcriptSegmentId: String? = nil,
        chapterId: String? = nil,
        sourceLocator: SourceLocator? = nil,
        playbackRate: Double = 1,
        anchorConfidence: AnchorConfidence = .localFallback
    ) {
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.mediaTimeMs = mediaTimeMs
        self.durationMs = durationMs
        self.textStart = textStart
        self.textEnd = textEnd
        self.transcriptSegmentId = transcriptSegmentId
        self.chapterId = chapterId
        self.sourceLocator = sourceLocator
        self.playbackRate = playbackRate
        self.anchorConfidence = anchorConfidence
    }

    public var textRange: Range<Int>? {
        guard let textStart, let textEnd, textEnd >= textStart else { return nil }
        return textStart..<textEnd
    }
}

public struct PlaybackMediaContext: Codable, Equatable, Sendable {
    public var itemId: String
    public var targetType: TargetType
    public var targetId: String
    public var title: String
    public var subtitle: String?
    public var sourceURL: String?
    /// Concrete transport URL selected for this playback. The target and source URL remain canonical.
    public var playbackURL: String?
    public var artworkURL: String?
    public var durationMs: Int?
    public var sourceType: AudioSourceType?
    public var chapters: [MediaTimelineChapter]

    public init(
        itemId: String,
        targetType: TargetType,
        targetId: String,
        title: String,
        subtitle: String? = nil,
        sourceURL: String? = nil,
        playbackURL: String? = nil,
        artworkURL: String? = nil,
        durationMs: Int? = nil,
        sourceType: AudioSourceType? = nil,
        chapters: [MediaTimelineChapter] = []
    ) {
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.playbackURL = playbackURL
        self.artworkURL = artworkURL
        self.durationMs = durationMs
        self.sourceType = sourceType
        self.chapters = chapters
    }
}

public struct RuntimeCapabilityProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: [String: [String]]
    public let forbiddenCapabilities: [String]

    public init(id: String, displayName: String, capabilities: [String: [String]], forbiddenCapabilities: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.forbiddenCapabilities = forbiddenCapabilities
    }

    public func has(_ category: String, _ capability: String) -> Bool {
        capabilities[category, default: []].contains(capability)
    }

    public func hasAny(_ category: String, _ candidates: [String]) -> Bool {
        candidates.contains { has(category, $0) }
    }
}

public struct ItemMedia: Codable, Equatable, Sendable {
    public var sourceType: AudioSourceType
    public var url: String?
    public var durationMs: Int?
    public var nativeMediaId: String?

    public init(sourceType: AudioSourceType, url: String? = nil, durationMs: Int? = nil, nativeMediaId: String? = nil) {
        self.sourceType = sourceType
        self.url = url
        self.durationMs = durationMs
        self.nativeMediaId = nativeMediaId
    }
}

public enum PDFDocumentExtractionEngine: String, Codable, Equatable, Sendable {
    case pdfKit = "pdfkit"
    case appleVision = "apple_vision_document_recognition"
}

public enum PDFDocumentAnalysisStatus: String, Codable, Equatable, Sendable {
    case complete
    case unavailableOnOS = "unavailable_on_os"
    case resourceConstrained = "resource_constrained"
    case partial
    case failed
}

public enum PDFTableSpeechDisposition: String, Codable, Equatable, Sendable {
    case announceAndSkip = "announce_and_skip"
}

public struct PDFNormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PDFDocumentTableCell: Codable, Equatable, Sendable {
    public var rowStart: Int
    public var rowEnd: Int
    public var columnStart: Int
    public var columnEnd: Int
    public var text: String

    public init(
        rowStart: Int,
        rowEnd: Int,
        columnStart: Int,
        columnEnd: Int,
        text: String
    ) {
        self.rowStart = rowStart
        self.rowEnd = rowEnd
        self.columnStart = columnStart
        self.columnEnd = columnEnd
        self.text = text
    }
}

public struct PDFDocumentTable: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var pageIndex: Int
    public var rowCount: Int
    public var columnCount: Int
    public var bounds: PDFNormalizedRect
    public var cells: [PDFDocumentTableCell]
    public var speechDisposition: PDFTableSpeechDisposition

    public init(
        id: String,
        pageIndex: Int,
        rowCount: Int,
        columnCount: Int,
        bounds: PDFNormalizedRect,
        cells: [PDFDocumentTableCell],
        speechDisposition: PDFTableSpeechDisposition = .announceAndSkip
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.bounds = bounds
        self.cells = cells
        self.speechDisposition = speechDisposition
    }
}

public struct PDFDocumentPageTitle: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var text: String

    public init(pageIndex: Int, text: String) {
        self.pageIndex = pageIndex
        self.text = text
    }
}

/// Structured evidence is retained separately from `Item.text`: listening can
/// skip a visually dense table without throwing away its rows and cells.
public struct PDFDocumentStructure: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var extractionEngine: PDFDocumentExtractionEngine
    public var analysisStatus: PDFDocumentAnalysisStatus
    public var pageCount: Int
    public var analyzedPageCount: Int
    public var tables: [PDFDocumentTable]
    public var pageTitles: [PDFDocumentPageTitle]
    /// The paper's identifier for reference managers (#206). Optional and left out when
    /// nil, so items saved before it existed decode and Build 29 ignores it.
    public var bibliography: PDFBibliography?

    public init(
        schemaVersion: String = "pdf-document-structure.v1",
        extractionEngine: PDFDocumentExtractionEngine,
        analysisStatus: PDFDocumentAnalysisStatus,
        pageCount: Int,
        analyzedPageCount: Int,
        tables: [PDFDocumentTable] = [],
        pageTitles: [PDFDocumentPageTitle] = [],
        bibliography: PDFBibliography? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.extractionEngine = extractionEngine
        self.analysisStatus = analysisStatus
        self.pageCount = pageCount
        self.analyzedPageCount = analyzedPageCount
        self.tables = tables
        self.pageTitles = pageTitles
        self.bibliography = bibliography
    }
}

/// What Zotero or a citation plugin needs to match a paper to its library entry (#206):
/// a DOI or arXiv id from the first pages, and the PDF metadata's authors, year and title.
public struct PDFBibliography: Codable, Equatable, Sendable {
    public var doi: String?
    public var arxivId: String?
    public var authors: [String]
    public var year: Int?
    public var title: String?

    public init(doi: String? = nil, arxivId: String? = nil, authors: [String] = [], year: Int? = nil, title: String? = nil) {
        self.doi = doi
        self.arxivId = arxivId
        self.authors = authors
        self.year = year
        self.title = title
    }
}

public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var mediaType: String
    public var text: String?
    public var externalReference: String?
    public var externalReferenceType: String?
    public var media: ItemMedia?
    public var transcriptId: String?
    public var status: String
    public var deletedAt: Date?
    public var author: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var createdAt: Date?
    public var documentStructure: PDFDocumentStructure?
    /// Source completion survives replay and independent assistant-turn playback.
    public var sourceCompletedAt: Date? = nil
    /// A podcast episode's feed GUID, show title and publish date, stored when the episode is
    /// added from a feed or Apple Podcasts link. Shared Margins match by GUID because every
    /// subscriber's GUID is the same even when their audio links differ (#177). Optional and
    /// additive, so Build 29's decoder ignores them.
    public var episodeGUID: String? = nil
    public var showTitle: String? = nil
    public var publishedAt: String? = nil
    /// The publisher's description of an episode or post, as plain text (at most about 2,000 characters),
    /// kept when the item is added from a followed feed so the Item screen can show its opening (#1322).
    /// Optional and additive: Build 29 and 30 decode an item that carries it and ignore it. Never packed
    /// into a packet, an export or a log.
    public var descriptionText: String? = nil
    /// The podcast episode the listener said an imported audio file is (#755). Only an audio file the
    /// listener imported carries it, and only because they chose it, so a link-shared packet for that
    /// episode can land on the file. Kept apart from `episodeGUID` so nothing that treats a GUID as
    /// "streamed from a feed" mistakes the file for one. Optional and additive, so Build 29's decoder
    /// ignores it.
    public var linkedEpisode: LinkedEpisode? = nil

    public init(
        id: String,
        title: String,
        mediaType: String,
        text: String?,
        externalReference: String?,
        status: String,
        externalReferenceType: String? = nil,
        media: ItemMedia? = nil,
        transcriptId: String? = nil,
        deletedAt: Date? = nil,
        author: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        createdAt: Date? = nil,
        documentStructure: PDFDocumentStructure? = nil
    ) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.text = text
        self.externalReference = externalReference
        self.externalReferenceType = externalReferenceType
        self.media = media
        self.transcriptId = transcriptId
        self.status = status
        self.deletedAt = deletedAt
        self.author = author
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.documentStructure = documentStructure
    }
}

public enum BrowserTextCaptureMode: String, Codable, Equatable, Sendable {
    case selectedText = "selected_text"
    case readablePage = "readable_page"
    case markdownFile = "markdown_file"
    case plainTextFile = "plain_text_file"
}

public enum BrowserTextContentFormat: String, Codable, Equatable, Sendable {
    case plainText = "plain_text"
    case markdown
}

public struct BrowserTextSource: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var author: String?
    public var publishedAt: String?

    public init(url: String, title: String, author: String? = nil, publishedAt: String? = nil) {
        self.url = url
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
    }
}

public struct BrowserTextSelection: Codable, Equatable, Sendable {
    public var textStart: Int?
    public var textEnd: Int?
    public var prefix: String?
    public var suffix: String?

    public init(textStart: Int? = nil, textEnd: Int? = nil, prefix: String? = nil, suffix: String? = nil) {
        self.textStart = textStart
        self.textEnd = textEnd
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct BrowserTextContinuation: Codable, Equatable, Sendable {
    public var startSession: Bool
    public var preferredPlaybackOwner: String?

    public init(startSession: Bool = false, preferredPlaybackOwner: String? = nil) {
        self.startSession = startSession
        self.preferredPlaybackOwner = preferredPlaybackOwner
    }
}

public struct BrowserTextHandoff: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var itemId: String?
    public var captureMode: BrowserTextCaptureMode
    public var source: BrowserTextSource
    public var text: String
    public var contentFormat: BrowserTextContentFormat?
    public var selection: BrowserTextSelection?
    public var requestedContinuation: BrowserTextContinuation
    public var documentStructure: PDFDocumentStructure?

    public init(
        schemaVersion: String = "browser-text-handoff.v1",
        itemId: String? = nil,
        captureMode: BrowserTextCaptureMode,
        source: BrowserTextSource,
        text: String,
        contentFormat: BrowserTextContentFormat? = nil,
        selection: BrowserTextSelection? = nil,
        requestedContinuation: BrowserTextContinuation = BrowserTextContinuation(),
        documentStructure: PDFDocumentStructure? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.captureMode = captureMode
        self.source = source
        self.text = text
        self.contentFormat = contentFormat
        self.selection = selection
        self.requestedContinuation = requestedContinuation
        self.documentStructure = documentStructure
    }
}

public struct Chapter: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startChar: Int
    public var endChar: Int
    public var percent: Int

    public init(id: String, title: String, startChar: Int, endChar: Int, percent: Int) {
        self.id = id
        self.title = title
        self.startChar = startChar
        self.endChar = endChar
        self.percent = percent
    }
}

public struct ListeningMap: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var overview: String
    public var chapters: [Chapter]

    public init(id: String, itemId: String, overview: String, chapters: [Chapter]) {
        self.id = id
        self.itemId = itemId
        self.overview = overview
        self.chapters = chapters
    }
}

public struct MediaTimelineSegment: Codable, Equatable, Sendable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    public var startChar: Int?
    public var endChar: Int?
    public var text: String
    public var sourceLocator: SourceLocator?

    public init(id: String, startMs: Int, endMs: Int, startChar: Int? = nil, endChar: Int? = nil, text: String, sourceLocator: SourceLocator? = nil) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.startChar = startChar
        self.endChar = endChar
        self.text = text
        self.sourceLocator = sourceLocator
    }
}

public struct MediaTimelineChapter: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var startMs: Int
    public var transcriptSegmentId: String

    public init(id: String, title: String, description: String? = nil, startMs: Int, transcriptSegmentId: String) {
        self.id = id
        self.title = title
        self.description = description
        self.startMs = startMs
        self.transcriptSegmentId = transcriptSegmentId
    }
}

public struct MediaTimeline: Codable, Equatable, Sendable {
    public var segments: [MediaTimelineSegment]
    public var chapters: [MediaTimelineChapter]
    public var durationMs: Int?

    public init(segments: [MediaTimelineSegment], chapters: [MediaTimelineChapter], durationMs: Int? = nil) {
        self.segments = segments
        self.chapters = chapters
        self.durationMs = durationMs
    }
}

public typealias TranscriptTimeline = MediaTimeline

public struct SourceTranscriptTimeline: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var createdAt: Date
    public var timeline: TranscriptTimeline

    public init(id: String, itemId: String, createdAt: Date, timeline: TranscriptTimeline) {
        self.id = id
        self.itemId = itemId
        self.createdAt = createdAt
        self.timeline = timeline
    }
}

public struct MediaResolvedAnchor: Codable, Equatable, Sendable {
    public var mediaTimeMs: Int
    public var chapterId: String?
    public var transcriptSegmentId: String?
    public var startChar: Int
    public var endChar: Int
    public var anchorBefore: String
    public var anchorAfter: String
    public var playbackRateObserved: Double

    public init(
        mediaTimeMs: Int,
        chapterId: String?,
        transcriptSegmentId: String?,
        startChar: Int,
        endChar: Int,
        anchorBefore: String,
        anchorAfter: String,
        playbackRateObserved: Double
    ) {
        self.mediaTimeMs = mediaTimeMs
        self.chapterId = chapterId
        self.transcriptSegmentId = transcriptSegmentId
        self.startChar = startChar
        self.endChar = endChar
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.playbackRateObserved = playbackRateObserved
    }
}

public enum MediaTimelineAnchorResolver {
    public static func resolve(
        mediaTimeMs: Int,
        timeline: MediaTimeline,
        playbackRateObserved: Double = 1,
        boundaryToleranceMs: Int = 250
    ) -> MediaResolvedAnchor {
        let clampedTime = max(0, mediaTimeMs)
        let sortedSegments = timeline.segments.sorted { $0.startMs < $1.startMs }
        let segment = segment(containing: clampedTime, in: sortedSegments, toleranceMs: boundaryToleranceMs)
        let chapter = timeline.chapters
            .filter { $0.startMs <= clampedTime }
            .sorted { $0.startMs < $1.startMs }
            .last
        let segmentIndex = segment.flatMap { selected in sortedSegments.firstIndex(where: { $0.id == selected.id }) }
        let nextSegmentText = segmentIndex.flatMap { index -> String? in
            guard sortedSegments.indices.contains(index + 1) else { return nil }
            return sortedSegments[index + 1].text
        }
        return MediaResolvedAnchor(
            mediaTimeMs: clampedTime,
            chapterId: chapter?.id,
            transcriptSegmentId: segment?.id,
            startChar: segment?.startChar ?? 0,
            endChar: segment?.endChar ?? 0,
            anchorBefore: segment?.text ?? "",
            anchorAfter: nextSegmentText ?? "",
            playbackRateObserved: playbackRateObserved
        )
    }

    private static func segment(
        containing mediaTimeMs: Int,
        in segments: [MediaTimelineSegment],
        toleranceMs: Int
    ) -> MediaTimelineSegment? {
        if let exact = segments.first(where: { $0.startMs <= mediaTimeMs && mediaTimeMs < $0.endMs }) {
            return exact
        }
        if let next = segments.first(where: { abs($0.startMs - mediaTimeMs) <= toleranceMs }) {
            return next
        }
        return segments.last(where: { $0.startMs <= mediaTimeMs }) ?? segments.first
    }
}

public struct WatchPackageItem: Codable, Equatable, Sendable {
    public var title: String
    public var mediaType: String
    public var externalReference: String?

    public init(title: String, mediaType: String, externalReference: String? = nil) {
        self.title = title
        self.mediaType = mediaType
        self.externalReference = externalReference
    }
}

public struct WatchPackageAudioAsset: Codable, Equatable, Sendable {
    public var audioAssetId: String
    public var fileName: String
    public var durationMs: Int
    public var sha256: String?

    public init(audioAssetId: String, fileName: String, durationMs: Int, sha256: String? = nil) {
        self.audioAssetId = audioAssetId
        self.fileName = fileName
        self.durationMs = durationMs
        self.sha256 = sha256
    }
}

public struct WatchPackageTranscript: Codable, Equatable, Sendable {
    public var transcriptId: String
    public var segments: [MediaTimelineSegment]

    public init(transcriptId: String, segments: [MediaTimelineSegment]) {
        self.transcriptId = transcriptId
        self.segments = segments
    }
}

public struct WatchPackageSettings: Codable, Equatable, Sendable {
    public var rollbackUnit: String
    public var defaultPlaybackRate: Double

    public init(rollbackUnit: String, defaultPlaybackRate: Double) {
        self.rollbackUnit = rollbackUnit
        self.defaultPlaybackRate = defaultPlaybackRate
    }
}

public struct WatchAudioPackage: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var sessionId: String
    public var createdAt: Date
    public var expiresAt: Date?
    public var item: WatchPackageItem
    public var audioAssets: [WatchPackageAudioAsset]
    public var transcript: WatchPackageTranscript
    public var chapters: [MediaTimelineChapter]
    public var settings: WatchPackageSettings

    public init(
        schemaVersion: String = "watch-audio-package.v1",
        id: String,
        itemId: String,
        sessionId: String,
        createdAt: Date,
        expiresAt: Date? = nil,
        item: WatchPackageItem,
        audioAssets: [WatchPackageAudioAsset],
        transcript: WatchPackageTranscript,
        chapters: [MediaTimelineChapter],
        settings: WatchPackageSettings
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.itemId = itemId
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.item = item
        self.audioAssets = audioAssets
        self.transcript = transcript
        self.chapters = chapters
        self.settings = settings
    }

    public var timeline: MediaTimeline {
        MediaTimeline(
            segments: transcript.segments,
            chapters: chapters,
            durationMs: audioAssets.map(\.durationMs).max()
        )
    }

    public var primaryAudioAsset: WatchPackageAudioAsset? {
        audioAssets.first
    }
}

public struct WatchSyncEventPayload: Codable, Equatable, Sendable {
    public var mediaTimeMs: Int?
    public var chapterId: String?
    public var transcriptSegmentId: String?
    public var playbackRate: Double?
    public var audioFileName: String?
    public var audioDurationMs: Int?
    public var error: String?

    public init(
        mediaTimeMs: Int? = nil,
        chapterId: String? = nil,
        transcriptSegmentId: String? = nil,
        playbackRate: Double? = nil,
        audioFileName: String? = nil,
        audioDurationMs: Int? = nil,
        error: String? = nil
    ) {
        self.mediaTimeMs = mediaTimeMs
        self.chapterId = chapterId
        self.transcriptSegmentId = transcriptSegmentId
        self.playbackRate = playbackRate
        self.audioFileName = audioFileName
        self.audioDurationMs = audioDurationMs
        self.error = error
    }
}

public struct WatchSyncEvent: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var id: String
    public var watchPackageId: String
    public var sessionId: String
    public var itemId: String?
    public var eventType: String
    public var createdAt: Date
    public var payload: WatchSyncEventPayload

    public init(
        schemaVersion: String = "watch-sync-event.v1",
        id: String,
        watchPackageId: String,
        sessionId: String,
        itemId: String? = nil,
        eventType: String,
        createdAt: Date,
        payload: WatchSyncEventPayload
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.watchPackageId = watchPackageId
        self.sessionId = sessionId
        self.itemId = itemId
        self.eventType = eventType
        self.createdAt = createdAt
        self.payload = payload
    }
}

public enum WatchPackageLibraryStatus: String, Codable, Equatable, Sendable {
    case loadedOnWatch = "loaded_on_watch"
    case queuedForTransfer = "queued_for_transfer"
    case availableForTransfer = "available_for_transfer"
    case needsPrerender = "needs_prerender"
    case rendering
    case failed
    case expired
}

public struct WatchPackageLibraryRow: Codable, Equatable, Sendable {
    public var itemId: String
    public var title: String
    public var status: WatchPackageLibraryStatus
    public var packageId: String?
    public var progressPercent: Int?

    public init(
        itemId: String,
        title: String,
        status: WatchPackageLibraryStatus,
        packageId: String? = nil,
        progressPercent: Int? = nil
    ) {
        self.itemId = itemId
        self.title = title
        self.status = status
        self.packageId = packageId
        self.progressPercent = progressPercent
    }
}

public enum WatchPackageRequestType: String, Codable, Equatable, Sendable {
    case prerenderRequested = "prerender_requested"
    case watchTransferRequested = "watch_transfer_requested"
    case packageDeleteRequested = "package_delete_requested"
}

public struct WatchPackageRequestEvent: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var packageId: String?
    public var requestType: WatchPackageRequestType
    public var createdAt: Date

    public init(id: String, itemId: String, packageId: String? = nil, requestType: WatchPackageRequestType, createdAt: Date) {
        self.id = id
        self.itemId = itemId
        self.packageId = packageId
        self.requestType = requestType
        self.createdAt = createdAt
    }
}

public struct Position: Codable, Equatable, Sendable {
    public var charOffset: Int
    public var mediaTimeMs: Int?
    public var segmentIndex: Int?
    public var chapterId: String?
    public var sourceLocator: SourceLocator?

    public init(charOffset: Int = 0, mediaTimeMs: Int? = nil, segmentIndex: Int? = nil, chapterId: String? = nil, sourceLocator: SourceLocator? = nil) {
        self.charOffset = charOffset
        self.mediaTimeMs = mediaTimeMs
        self.segmentIndex = segmentIndex
        self.chapterId = chapterId
        self.sourceLocator = sourceLocator
    }
}

public struct Anchor: Codable, Equatable, Sendable {
    public var anchorType: AnchorType
    public var startChar: Int
    public var endChar: Int
    public var anchorBefore: String
    public var anchorAfter: String
    public var mediaTimeMs: Int?
    public var playbackRateObserved: Double
    public var transcriptSegmentId: String?
    public var turnSegmentIndex: Int?
    public var sourceLocator: SourceLocator?

    public init(
        anchorType: AnchorType,
        startChar: Int,
        endChar: Int,
        anchorBefore: String,
        anchorAfter: String,
        mediaTimeMs: Int? = nil,
        playbackRateObserved: Double = 1,
        transcriptSegmentId: String? = nil,
        turnSegmentIndex: Int? = nil,
        sourceLocator: SourceLocator? = nil
    ) {
        self.anchorType = anchorType
        self.startChar = startChar
        self.endChar = endChar
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.mediaTimeMs = mediaTimeMs
        self.playbackRateObserved = playbackRateObserved
        self.transcriptSegmentId = transcriptSegmentId
        self.turnSegmentIndex = turnSegmentIndex
        self.sourceLocator = sourceLocator
    }
}

public enum AnchorContextStatus: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case unavailable
}

public enum PodcastAnchorEvidenceCaptureStatus: String, Codable, Equatable, Sendable {
    case pendingPostResumeSample = "pending_post_resume_sample"
    case pendingExactLocalCapture = "pending_exact_local_capture"
    case ready
    case unavailable
}

public enum PodcastAnchorEvidenceProvenance: String, Codable, Equatable, Sendable {
    case decodedPlaybackStream = "decoded_playback_stream"
    case exactLocalPlaybackEdition = "exact_local_playback_edition"
    case observedDecodedPlayback = "observed_decoded_playback"
    case sourceWindowReference = "source_window_reference"
    case downloadedSourceReference = "downloaded_source_reference"
}

public enum PodcastAnchorEvidenceWindowRole: String, Codable, Equatable, Sendable {
    case preInterjection = "pre_interjection"
    case postResume = "post_resume"
    case sourceWindowBefore = "source_window_before"
    case sourceWindowAfter = "source_window_after"
}

public struct CapturedPodcastAnchorEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let localPath: String
    public let durationMs: Int
    public let anchorOffsetMs: Int
    public let provenance: PodcastAnchorEvidenceProvenance?
    public let windowRole: PodcastAnchorEvidenceWindowRole?

    public init(
        id: String,
        localPath: String,
        durationMs: Int,
        anchorOffsetMs: Int,
        provenance: PodcastAnchorEvidenceProvenance? = nil,
        windowRole: PodcastAnchorEvidenceWindowRole? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
        self.provenance = provenance
        self.windowRole = windowRole
    }
}

public struct Interjection: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var sessionId: String
    public var targetType: InterjectionTargetType
    public var targetId: String
    public var createdAt: Date
    public var roughPercent: Int
    public var anchor: Anchor
    public var audioPath: String?
    public var audioStatus: String
    public var transcriptionStatus: String
    public var transcript: String?
    public var cleanedTranscript: String?
    public var displayText: String?
    public var status: String
    public var anchorContextStatus: AnchorContextStatus? = nil
    /// Word/run timing retained from on-device recognition. Optional so records
    /// created before sharing support remain decodable without migration.
    public var alignedTranscript: AlignedInterjectionTranscript? = nil
    /// Non-playable signatures captured from decoded playback or an exact local
    /// playback edition when this Margin was recorded.
    public var podcastAnchorEvidence: [CapturedPodcastAnchorEvidence]? = nil
    public var sourceExactEditionSHA256: String? = nil
    public var podcastAnchorEvidenceCaptureStatus: PodcastAnchorEvidenceCaptureStatus? = nil
    public var podcastAnchorEvidenceFailureReason: String? = nil
    /// Local, private curation metadata. These fields help the owner shortlist
    /// Margins for sender review and are never copied into reviewed revisions
    /// or `.spokenmargins` packages.
    public var isStarredForSharing: Bool? = nil
    public var privateSharingNote: String? = nil
    /// Missing values predate written Margins and retain audio-recording semantics.
    public var captureKind: InterjectionCaptureKind? = nil
    /// Set when this Margin answers someone's shared Margin (#472). Build 29 ignores it.
    public var replyTo: MarginReplyLink? = nil
    /// The packets this Margin went out in, so replies that come back link to it. Never exported.
    public var sharedAs: [MarginPacketIdentity]? = nil

    public init(
        id: String,
        itemId: String,
        sessionId: String,
        targetType: InterjectionTargetType,
        targetId: String,
        createdAt: Date,
        roughPercent: Int,
        anchor: Anchor,
        audioPath: String?,
        audioStatus: String,
        transcriptionStatus: String,
        transcript: String?,
        cleanedTranscript: String?,
        displayText: String?,
        status: String,
        anchorContextStatus: AnchorContextStatus? = nil,
        alignedTranscript: AlignedInterjectionTranscript? = nil,
        podcastAnchorEvidence: [CapturedPodcastAnchorEvidence]? = nil,
        sourceExactEditionSHA256: String? = nil,
        podcastAnchorEvidenceCaptureStatus: PodcastAnchorEvidenceCaptureStatus? = nil,
        podcastAnchorEvidenceFailureReason: String? = nil,
        isStarredForSharing: Bool? = nil,
        privateSharingNote: String? = nil,
        captureKind: InterjectionCaptureKind? = nil,
        replyTo: MarginReplyLink? = nil,
        sharedAs: [MarginPacketIdentity]? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.sessionId = sessionId
        self.targetType = targetType
        self.targetId = targetId
        self.createdAt = createdAt
        self.roughPercent = roughPercent
        self.anchor = anchor
        self.audioPath = audioPath
        self.audioStatus = audioStatus
        self.transcriptionStatus = transcriptionStatus
        self.transcript = transcript
        self.cleanedTranscript = cleanedTranscript
        self.displayText = displayText
        self.status = status
        self.anchorContextStatus = anchorContextStatus
        self.alignedTranscript = alignedTranscript
        self.podcastAnchorEvidence = podcastAnchorEvidence
        self.sourceExactEditionSHA256 = sourceExactEditionSHA256
        self.podcastAnchorEvidenceCaptureStatus = podcastAnchorEvidenceCaptureStatus
        self.podcastAnchorEvidenceFailureReason = podcastAnchorEvidenceFailureReason
        self.isStarredForSharing = isStarredForSharing
        self.privateSharingNote = privateSharingNote
        self.captureKind = captureKind
        self.replyTo = replyTo
        self.sharedAs = sharedAs
    }
}

public struct WrittenInterjectionCapture: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let itemId: String
    public let targetType: InterjectionTargetType
    public let targetId: String
    public let anchor: Anchor
    public let roughPercent: Int
    public let wasPlaying: Bool
    /// The shared Margin this note answers (#473).
    public let replyTo: MarginReplyLink?

    public init(
        id: String,
        sessionId: String,
        itemId: String,
        targetType: InterjectionTargetType,
        targetId: String,
        anchor: Anchor,
        roughPercent: Int,
        wasPlaying: Bool,
        replyTo: MarginReplyLink? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.anchor = anchor
        self.roughPercent = roughPercent
        self.wasPlaying = wasPlaying
        self.replyTo = replyTo
    }

    /// The same capture answering `link`, or nothing: what the listener chose, which is what a journal must keep (#473).
    public func replying(to link: MarginReplyLink?) -> WrittenInterjectionCapture {
        WrittenInterjectionCapture(
            id: id, sessionId: sessionId, itemId: itemId, targetType: targetType, targetId: targetId,
            anchor: anchor, roughPercent: roughPercent, wasPlaying: wasPlaying, replyTo: link
        )
    }
}

public struct ConversationTurn: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var role: String
    public var turnType: String
    public var status: String
    public var summary: String?
    public var text: String?
    public var rawText: String?
    public var chapters: [Chapter]? = nil
    public var sourceInterjectionIds: [String]
}

public struct AIJob: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var itemId: String?
    public var sessionId: String
    public var turnId: String?
    public var providerType: String
    public var model: String
    public var status: String
    public var attempts: Int
    public var lastError: String?
    public var messages: [String]
    public var playbackMode: String?
}

public struct Session: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    /// Optional only so session payloads written by pre-timestamp builds remain decodable.
    public var createdAt: Date? = nil
    public var updatedAt: Date? = nil
    public var completedAt: Date? = nil
    public var status: String
    public var phase: SessionPhase
    public var currentTargetType: TargetType
    public var currentTargetId: String
    public var position: Position
    public var completionPercent: Int
    public var playbackRate: Double

    public init(
        id: String,
        itemId: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        status: String,
        phase: SessionPhase,
        currentTargetType: TargetType,
        currentTargetId: String,
        position: Position,
        completionPercent: Int,
        playbackRate: Double
    ) {
        self.id = id
        self.itemId = itemId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.status = status
        self.phase = phase
        self.currentTargetType = currentTargetType
        self.currentTargetId = currentTargetId
        self.position = position
        self.completionPercent = completionPercent
        self.playbackRate = playbackRate
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var itemId: String?
    public var targetType: String?
    public var targetId: String?
    public var status: PlaybackStatus
    public var phase: SessionPhase
    public var title: String?
    public var chapterTitle: String?
    public var progressPercent: Int
    public var sourceProgressPercent: Int
    public var currentPlaybackProgressPercent: Int
    public var currentMediaTimeMs: Int?
    public var currentPlaybackDurationMs: Int?
    public var currentTextStart: Int?
    public var currentTextEnd: Int?
    public var currentTranscriptSegmentId: String?
    public var currentAnchorConfidence: AnchorConfidence?
    public var playbackRate: Double
    public var isRecording: Bool
    public var activeInterjectionCount: Int
    public var pendingAiJobCount: Int
    public var lastInterjectionAnchorType: AnchorType?
    public var lastInterjectionTargetType: InterjectionTargetType?
    public var recordingTargetId: String?
    public var pendingAiJobKind: String?
    public var pendingAiJobStatus: String?
    public var providerCallStarted: Bool
    public var turnStatus: String?
    public var lastUserTurnType: String?
    public var spokenUnits: [String]
    public var lastFailure: String?
    public var linkResolutionStatus: String?
    public var linkResolutionFailureReason: String?
    public var preparedTextAudioStatus: String?
    public var sourceTranscriptStatus: String?
    public var skimBridgeState: SkimBridgeState?
    public var canSkimForward: Bool
    public var canSkimBackward: Bool
    /// When the listener's request behind the latest playback start reached the engine, before any audio work, so the
    /// time from tap to first audio can be measured (#357). Optional, so older decoders ignore it.
    public var playbackRequestedAt: Date?

    public init() {
        sessionId = nil
        itemId = nil
        targetType = nil
        targetId = nil
        status = .idle
        phase = .idle
        title = nil
        chapterTitle = nil
        progressPercent = 0
        sourceProgressPercent = 0
        currentPlaybackProgressPercent = 0
        currentMediaTimeMs = nil
        currentPlaybackDurationMs = nil
        currentTextStart = nil
        currentTextEnd = nil
        currentTranscriptSegmentId = nil
        currentAnchorConfidence = nil
        playbackRate = 1
        isRecording = false
        activeInterjectionCount = 0
        pendingAiJobCount = 0
        lastInterjectionAnchorType = nil
        lastInterjectionTargetType = nil
        recordingTargetId = nil
        pendingAiJobKind = nil
        pendingAiJobStatus = nil
        providerCallStarted = false
        turnStatus = nil
        lastUserTurnType = nil
        spokenUnits = []
        lastFailure = nil
        linkResolutionStatus = nil
        linkResolutionFailureReason = nil
        preparedTextAudioStatus = nil
        sourceTranscriptStatus = nil
        skimBridgeState = nil
        canSkimForward = false
        canSkimBackward = false
    }
}

extension LinkResolutionResult {
    /// The link reached a page or feed, but nothing there is playable audio. The page may be a readable article.
    public var foundNoAudio: Bool {
        status != .playable
            && selectedCandidate?.audioURL == nil
            && !candidates.contains { $0.audioURL != nil }
            && ["audio_enclosure_not_found", "unsupported_link_type"].contains(failureReason ?? "")
    }

    /// The failure reason for a link whose body is a PDF document rather than a web page or feed (#758).
    public static let pdfDocumentFailureReason = "pdf_document"

    /// The link serves a PDF. The app imports it with its PDF reader, as it does a PDF shared from Safari, instead
    /// of sending it to the HTML article reader.
    public var isPDFDocument: Bool {
        status != .playable && failureReason == Self.pdfDocumentFailureReason
    }
}
