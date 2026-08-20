import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSupertonic
#if KOKORO_DEVICE && !targetEnvironment(simulator)
import SessionKitKokoro
#endif
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

enum Gate1Screen: Hashable {
    case home
    case item
    case playback
    case settings
    case export
    case batchExport
}

enum AIDataSharingConsent: String {
    case unknown
    case grantedV1
    case declined
}

private struct PendingProviderJob {
    let kind: String
    let turnId: String
    let messages: [String]
    let force: Bool
}

struct LibraryItemRow: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let canDelete: Bool
    let hasContinuationSession: Bool
    let continuationProgressPercent: Int?

    init(
        id: String,
        title: String,
        status: String,
        canDelete: Bool,
        hasContinuationSession: Bool = false,
        continuationProgressPercent: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.canDelete = canDelete
        self.hasContinuationSession = hasContinuationSession
        self.continuationProgressPercent = continuationProgressPercent
    }
}

struct TrashUndoState: Identifiable, Equatable {
    let id = UUID()
    let itemId: String
    let title: String
}

struct SourceLinkCandidateReviewState: Identifiable, Equatable {
    let request: LinkResolutionRequest
    let result: LinkResolutionResult
    let startSession: Bool

    var id: String { request.id }
}

struct UserFeedbackEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    var overview = ""
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var mediaDurationMs: Int?
    var isNativeAudio = false
    var sessions: [Session] = []
    var sessionRows: [SessionPresentation] = []
    var interjections: [Interjection] = []
    var turns: [ConversationTurn] = []
}

struct SessionPresentation: Identifiable {
    let session: Session
    let interjectionCount: Int
    let interjectionPreview: String?

    var id: String { session.id }
}

enum BatchSessionExportFilter: String, CaseIterable, Identifiable {
    case withInterjections = "with_interjections"
    case all = "all"

    var id: String { rawValue }
}

struct BatchSessionExportRow: Identifiable {
    let session: Session
    let itemTitle: String
    let interjectionCount: Int

    var id: String { session.id }
}

struct BatchSessionExportResult: Equatable {
    let exportedFileNames: [String]
    let failures: [String]
    let destinationName: String
}

enum OnboardingStep: String, CaseIterable, Identifiable, Hashable {
    case firstInterjection = "first_interjection"
    case reviewedTimeline = "reviewed_timeline"
    case exportedSession = "exported_session"
    case addedOwnSource = "added_own_source"
    case addedFromSafari = "added_from_safari"
    case addedFromFiles = "added_from_files"
    case addedPodcast = "added_podcast"

    var id: String { rawValue }

    static let core: [OnboardingStep] = [
        .firstInterjection,
        .reviewedTimeline,
        .exportedSession
    ]

    static let sourceExploration: [OnboardingStep] = [
        .addedOwnSource,
        .addedFromSafari,
        .addedFromFiles,
        .addedPodcast
    ]
}

enum GuidedOnboardingStage: String, Equatable {
    case inactive
    case practiceInterjection = "practice_interjection"
    case reviewTimeline = "review_timeline"
    case optionalAI = "optional_ai"
    case exportSession = "export_session"
    case complete
}

struct SpeechVoiceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

enum AppTTSVoiceSelection: String, CaseIterable, Identifiable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .james: "James"
        case .lily: "Lily"
        case .system: "iOS System Voice"
        }
    }

    var detail: String {
        switch self {
        case .james: "Deep, calm · M2"
        case .lily: "Bright, cheerful · F2"
        case .system: "Uses the selected voice installed in iOS"
        }
    }

    var supertonicVoice: SupertonicVoiceID? {
        switch self {
        case .james: .m2
        case .lily: .f2
        case .system: nil
        }
    }
}

struct PiperVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let modelURL: URL
    let configURL: URL?

    var displayName: String {
        language.isEmpty ? name : "\(name) · \(language)"
    }
}

struct QuickAccessFile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAtDescription: String
}

private struct ObsidianImportRequest: Sendable {
    let url: URL
    let itemId: String
}

private struct PreparedObsidianImport: Sendable {
    let item: Item
    let listeningMap: ListeningMap?
}

private struct ObsidianImportBatch: Sendable {
    let prepared: [PreparedObsidianImport]
    let failures: [String]
}

private enum SourceFileImportError: LocalizedError {
    case pdfHasNoExtractableText
    case pdfImportUnavailable

    var errorDescription: String? {
        switch self {
        case .pdfHasNoExtractableText:
            return "This PDF has no extractable text. Scanned PDFs need OCR before they can be imported."
        case .pdfImportUnavailable:
            return "PDF text extraction is unavailable in this build."
        }
    }
}

private struct QuickAccessFileCandidate: Sendable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAt: Date
}

private struct QuickAccessFolderScan: Sendable {
    let files: [QuickAccessFileCandidate]
    let errorDescription: String?
}

struct ImportInboxEntry: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case sourceLink
        case browserText
    }

    let id: String
    let payloadID: String
    let kind: Kind
    let title: String
    let source: String
    let reason: String
}

private enum AppSpeechPreviewMode {
    case spokenContent
    case appVoice(voiceIdentifier: String?, rate: Float)
    case assistiveTechnology
}

typealias PreparedTextAudioPrewarmHandler = @Sendable (
    _ itemId: String,
    _ title: String,
    _ text: String,
    _ outputDirectory: URL,
    _ voiceIdentifier: String?,
    _ speechRate: Float
) async -> Result<PreparedTextAudio?, Error>

typealias InterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> String

private struct UITestingAmbiguousSourceLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .needsReview,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            candidates: [
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-one",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode One",
                    showTitle: "UI Test Show",
                    durationMs: 1_800_000,
                    publishedAt: "2026-08-01T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-one.mp3",
                    confidence: 0.71
                ),
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-two",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode Two",
                    showTitle: "UI Test Show",
                    durationMs: 2_400_000,
                    publishedAt: "2026-08-02T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-two.mp3",
                    confidence: 0.70
                )
            ],
            failureReason: "spotify_episode_match_ambiguous"
        )
    }
}

@MainActor
final class Gate1AppModel: ObservableObject {
    static let welcomeSampleItemId = "item-spoken-margins-overview"
    private static let welcomeSampleSeedVersion = 2
    private static let welcomeSampleSeedVersionKey = "welcomeSampleSeedVersion"
    private static let onboardingStepsKey = "onboardingCompletedStepsV1"
    private static let guidedOnboardingStageKey = "guidedOnboardingStageV1"
    private static let onboardingCardDismissedKey = "onboardingCardDismissedV1"
    private static let supertonicTTSMigrationKey = "supertonicTTSMigrationV1"
    private static let supertonicVoicePendingTermsKey = "supertonicVoicePendingTermsV1"
    static let exportPreviewCharacterLimit = 24_000
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @Published var screen: Gate1Screen = .home
    @Published var snapshot = SessionSnapshot() {
        didSet {
            preparedTextAudioStatus = snapshot.preparedTextAudioStatus ?? preparedTextAudioStatus
            if let snapshotSourceTranscriptStatus = snapshot.sourceTranscriptStatus,
               !(sourceTranscriptStatus == "transcribing" && snapshotSourceTranscriptStatus == "not_started") {
                sourceTranscriptStatus = snapshotSourceTranscriptStatus
            }
            reconcilePlaybackProgressTicker()
            reconcileTextPlaybackStartupBackgroundTask()
            updateGate2CompactState()
        }
    }
    @Published var gate2CompactSnapshot: CompactControlSnapshot?
    @Published var diagnostics: [String: String] = [:]
    @Published var statusMessage = "Ready."
    @Published var lastError: String?
    @Published private(set) var feedbackEvent: UserFeedbackEvent?
    @Published var exportPreview = ""
    @Published private(set) var exportFileURL: URL?
    @Published var exportSessionId: String?
    @Published var exportFormat = UserDefaults.standard.string(forKey: "exportFormat") ?? "markdown"
    @Published var exportScope = UserDefaults.standard.string(forKey: "exportScope") ?? "full_session"
    @Published var exportIncludesSourceText = UserDefaults.standard.object(forKey: "exportIncludesSourceText") as? Bool ?? true
    @Published var exportIncludesReference = UserDefaults.standard.object(forKey: "exportIncludesReference") as? Bool ?? true
    @Published var exportIncludesListeningMap = UserDefaults.standard.object(forKey: "exportIncludesListeningMap") as? Bool ?? true
    @Published var exportIncludesInterjections = UserDefaults.standard.object(forKey: "exportIncludesInterjections") as? Bool ?? true
    @Published var exportIncludesTurns = UserDefaults.standard.object(forKey: "exportIncludesTurns") as? Bool ?? true
    @Published private(set) var batchExportRows: [BatchSessionExportRow] = []
    @Published var batchExportFilter: BatchSessionExportFilter = .withInterjections
    @Published var selectedBatchExportSessionIds: Set<String> = []
    @Published private(set) var batchExportFolderName = UserDefaults.standard.string(forKey: "batchExportFolderName") ?? "No folder selected"
    @Published private(set) var batchExportResult: BatchSessionExportResult?
    @Published private(set) var isWritingBatchExport = false
    @Published private(set) var retryingInterjectionTranscriptionIds: Set<String> = []
    @Published private(set) var playingInterjectionAudioId: String?
    @Published var libraryItems: [LibraryItemRow] = []
    @Published var recentlyDeletedItems: [LibraryItemRow] = []
    @Published var trashUndo: TrashUndoState?
    @Published var selectedItem = ItemDetailState()
    @Published var pastedAssistantResponse = ""

    var displayedExportPreview: String {
        guard exportPreview.count > Self.exportPreviewCharacterLimit else { return exportPreview }
        return String(exportPreview.prefix(Self.exportPreviewCharacterLimit))
            + "\n\n… Preview truncated. Copy or Share uses the complete export."
    }

    var exportPreviewIsTruncated: Bool {
        exportPreview.count > Self.exportPreviewCharacterLimit
    }

    var exportPreviewSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(exportPreview.utf8.count),
            countStyle: .file
        )
    }
    @Published var quickAccessFolderName = UserDefaults.standard.string(forKey: "quickAccessFolderName") ?? "No folder selected"
    @Published var quickAccessRecentFiles: [QuickAccessFile] = []
    @Published private(set) var sourceImportProgressMessage: String?
    @Published private(set) var isRefreshingQuickAccessFolder = false
    @Published var importInbox: [ImportInboxEntry] = []
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = ""
    @Published var importText = ""
    @Published var sourceLinkURL = ""
    @Published var isResolvingSourceLink = false
    @Published var sourceLinkCandidateReview: SourceLinkCandidateReviewState?
    @Published private(set) var sourceLinkImportState = "idle"
    @Published private(set) var sourceLinkImportMessage: String?
    @Published var listeningMapJSON = ""
    @Published var isGeneratingListeningMap = false
    @Published private(set) var localFoundationModelAvailability: LocalFoundationModelAvailability = .unavailable("Checking availability")
    @Published private(set) var providerBaseURL = "https://api.openai.com/v1"
    @Published var listeningMapModel = UserDefaults.standard.string(forKey: "listeningMapModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summaryModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var conversationModel = UserDefaults.standard.string(forKey: "conversationModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var skipUnit = UserDefaults.standard.string(forKey: "skipUnit") ?? "paragraph"
    @Published var mediaSkipBackSeconds = Gate1AppModel.storedMediaSkipSeconds(forKey: "mediaSkipBackSeconds")
    @Published var mediaSkipForwardSeconds = Gate1AppModel.storedMediaSkipSeconds(forKey: "mediaSkipForwardSeconds")
    @Published var speechRate = UserDefaults.standard.double(forKey: "speechRate") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "speechRate")
    @Published var mediaPlaybackRate = UserDefaults.standard.double(forKey: "mediaPlaybackRate") == 0 ? 1.0 : UserDefaults.standard.double(forKey: "mediaPlaybackRate")
    @Published var podcastCacheLimitGB = PodcastCacheLimitGB(
        rawValue: UserDefaults.standard.integer(forKey: "podcastCacheLimitGB")
    )?.rawValue ?? PodcastCacheLimitGB.defaultValue.rawValue
    @Published var renderedSpeechCacheLimitMB = Gate1AppModel.storedRenderedSpeechCacheLimitMB()
    @Published private(set) var podcastDownloadRecords: [String: PodcastDownloadRecord] = [:]
    @Published var preparedTextAudioStatus = "Not started"
    @Published private(set) var onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.inactive.rawValue
    @Published var sourceTranscriptStatus = "Not started"
    @Published var pendingPreparedTextStartItemId: String?
    @Published var speechVoiceOptions: [SpeechVoiceChoice] = []
    @Published var speechVoiceIdentifier = UserDefaults.standard.string(forKey: "speechVoiceIdentifier") ?? ""
    @Published var ttsVoiceSelection = AppTTSVoiceSelection(
        rawValue: UserDefaults.standard.string(forKey: "ttsVoiceSelection") ?? ""
    ) ?? .james
    @Published var ttsMode = UserDefaults.standard.string(forKey: "ttsMode") ?? "supertonic"
    @Published var kokoroVoiceName = UserDefaults.standard.string(forKey: "kokoroVoiceName") ?? "am_echo"
    @Published var kokoroChunkCharacters = min(140, max(80, UserDefaults.standard.double(forKey: "kokoroChunkCharacters") == 0 ? 110 : UserDefaults.standard.double(forKey: "kokoroChunkCharacters")))
    @Published var kokoroStatus = "Not checked"
    @Published var piperVoiceId = UserDefaults.standard.string(forKey: "piperVoiceId") ?? ""
    @Published var piperVoiceOptions: [PiperVoiceOption] = []
    @Published var piperStatus = "Not checked"
    @Published var isRenderingKokoroPreview = false
    @Published var isRunningKokoroMemoryCheck = false
    @Published var isRenderingSupertonicPreview = false
    #if SPOKEN_MARGINS_WATCH
    @Published var isRenderingWatchPackage = false
    @Published var watchPackageRenderStatus = "Not rendered"
    #endif
    @Published var providerAPIKey = KeychainStore.load(service: "SpokenMargins", account: "OpenAICompatibleAPIKey") ?? ""
    @Published var providerProbeStatus = "Not checked"
    @Published var aiDataSharingConsent = AIDataSharingConsent(
        rawValue: UserDefaults.standard.string(forKey: "aiDataSharingConsent") ?? ""
    ) ?? .unknown
    @Published var isAIDataSharingConsentPresented = false
    @Published var isAISetupNeededPresented = false
    @Published private(set) var hasAcceptedCurrentTerms = SpokenMarginsTerms.hasAcceptedCurrentVersion()
        && SpokenMarginsTerms.hasBundledText()
    @Published private(set) var acceptedTermsVersion = SpokenMarginsTerms.acceptedVersion()
    @Published var isTermsOfUsePresented = false
    @Published var isHelpPresented = false
    @Published private(set) var completedOnboardingSteps = Gate1AppModel.loadOnboardingSteps()
    @Published private(set) var guidedOnboardingStage = Gate1AppModel.loadGuidedOnboardingStage()
    @Published private(set) var isOnboardingCardDismissed = UserDefaults.standard.bool(forKey: Gate1AppModel.onboardingCardDismissedKey)
    @Published private(set) var legacyLibraryResetNotice: String?
    @Published var knownIssues = [
        "Physical-device product validation remains pending.",
        "Now Playing lock-screen controls require signed real-device validation.",
        "Source link, public podcast, and share-extension intake are experimental until they have their own human validation record."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private var databaseURLOverride: URL?
    private let gate2CompactControls: Gate2CompactControlController
    private let featureFlags: SpokenMarginsFeatureFlags
    private let localFoundationModelClient: any LocalFoundationModelClient
    #if SPOKEN_MARGINS_WATCH
    private let gate3WatchConnectivity = Gate3WatchConnectivityController()
    #endif
    private let openAIResponsesClient = OpenAIResponsesClient()
    private let streamingSpeechQueue = StreamingSpeechQueue()
    private var speechPlaybackClient: AudioPlaybackClient?
    private var supertonicRenderer: SupertonicNarrationRenderer?
    private var renderedSpeechDiskCache: RenderedSpeechDiskCache?
    private let sourceLinkResolver: LinkResolutionClient?
    private let sourceLinkHandoffStore: SourceLinkHandoffStore?
    private let browserTextHandoffStore: Gate5BrowserTextHandoffStore?
    private let audioPlaybackClientOverride: AudioPlaybackClient?
    private var mediaPlaybackClient: AVPlayerStreamPlaybackClient?
    private var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    private let recordingClientOverride: RecordingClient?
    private let forcePreparedTextGate: Bool
    private let sourceTranscriptionClient: SourceTranscriptionClient
    private let interjectionTranscriptionHandler: InterjectionTranscriptionHandler
    private let preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler?
    private let trashUndoDismissDelay: Duration
    #if SPOKEN_MARGINS_WATCH
    private var gate3WatchDispatcher: CompactControlDispatcher?
    #endif
    private var activeItemId = "item-pill"
    private var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    private var playbackProgressTask: Task<Void, Never>?
    private var trashUndoDismissTask: Task<Void, Never>?
    #if canImport(UIKit) && os(iOS)
    private var textPlaybackStartupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    #if canImport(AVFoundation)
    private var interjectionAudioPlayer: AVPlayer?
    private var interjectionAudioCompletionTask: Task<Void, Never>?
    #endif
    private var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    private var sourceImportTask: Task<Void, Never>?
    private var quickAccessRefreshTask: Task<Void, Never>?
    private var quickAccessRefreshID = UUID()
    private var liveSpeechFallbackItemIds: Set<String> = []
    private var isImportingPendingSourceLinkHandoffs = false
    private var pendingAutoPlayQueue = Gate1PlaybackAutoplayQueue()
    private var completedStreamingTurnIds: Set<String> = []
    private var pendingSourceContextInterjectionIds: Set<String> = []
    private var defaultVoiceFallbackSessionIds: Set<String> = []
    private var pendingMapGenerationItemId: String?
    private var pendingProviderJobForConsent: PendingProviderJob?
    private var pendingMapGenerationAfterConsent = false
    private var pendingTermsVoiceSelection: AppTTSVoiceSelection?
    private var pendingPlaybackAfterTerms: PendingPlaybackAfterTerms?
    #if SPOKEN_MARGINS_WATCH
    private var activeWatchPackageRenderItemIds: Set<String> = []
    private var failedWatchPackageRenderItemIds: Set<String> = []
    #endif
    private let preparedTextAudioStarterDurationMs = 30_000
    static let substantiallyCompletedTextThreshold = 90
    private let sourceWindowContextBeforeMs = SourceAnchorContextResolver.windowBeforeMs
    private let sourceWindowContextAfterMs = SourceAnchorContextResolver.windowAfterMs
    private let quickAccessFolderBookmarkKey = "quickAccessFolderBookmark"
    private let batchExportFolderBookmarkKey = "batchExportFolderBookmark"
    #if canImport(AVFoundation)
    private let speechPreviewSynthesizer = AVSpeechSynthesizer()
    private var kokoroPreviewPlayer: AVAudioPlayer?
    private var supertonicPreviewPlayer: AVAudioPlayer?
    private var supertonicPreviewURL: URL?
    #endif
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private enum PendingPlaybackAfterTerms {
        case startCurrentItem
        case resumeSession(String)
        case jumpToChapter(String, fromTimeline: Bool)
        case playSourceFromBeginning(fromTimeline: Bool)
    }
    private static func availableSpeechVoiceOptions() -> [SpeechVoiceChoice] {
        #if canImport(AVFoundation)
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name < rhs.name
                }
                return lhs.language < rhs.language
            }
            .map { voice in
                SpeechVoiceChoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: voiceQualityName(voice)
                )
            }
        #else
        return []
        #endif
    }

    private static func loadOnboardingSteps() -> Set<OnboardingStep> {
        Set(
            (UserDefaults.standard.stringArray(forKey: onboardingStepsKey) ?? [])
                .compactMap(OnboardingStep.init(rawValue:))
        )
    }

    private static func loadGuidedOnboardingStage() -> GuidedOnboardingStage {
        guard let rawValue = UserDefaults.standard.string(forKey: guidedOnboardingStageKey) else {
            return .inactive
        }
        return GuidedOnboardingStage(rawValue: rawValue) ?? .inactive
    }

    var onboardingCoreCompletedCount: Int {
        OnboardingStep.core.filter(completedOnboardingSteps.contains).count
    }

    var onboardingSourceCompletedCount: Int {
        OnboardingStep.sourceExploration.filter(completedOnboardingSteps.contains).count
    }

    var hasCompletedCoreOnboarding: Bool {
        onboardingCoreCompletedCount == OnboardingStep.core.count
    }

    var shouldShowOnboardingCard: Bool {
        !Self.isRunningUnitTests
            && !CommandLine.arguments.contains("--ui-testing")
            && !hasCompletedCoreOnboarding
            && !isOnboardingCardDismissed
    }

    var shouldShowGuidedOnboardingCoach: Bool {
        guidedOnboardingStage != .inactive
            && selectedItem.id == Self.welcomeSampleItemId
    }

    func isOnboardingStepComplete(_ step: OnboardingStep) -> Bool {
        completedOnboardingSteps.contains(step)
    }

    private func markOnboardingSteps(_ steps: Set<OnboardingStep>) {
        let updated = completedOnboardingSteps.union(steps)
        guard updated != completedOnboardingSteps else { return }
        completedOnboardingSteps = updated
        UserDefaults.standard.set(updated.map(\.rawValue).sorted(), forKey: Self.onboardingStepsKey)
    }

    private func setGuidedOnboardingStage(_ stage: GuidedOnboardingStage) {
        guidedOnboardingStage = stage
        UserDefaults.standard.set(stage.rawValue, forKey: Self.guidedOnboardingStageKey)
    }

    private func reconcileOnboardingEvidence(store: SQLiteSessionStore) throws {
        let items = try store.listItems()
        var evidence: Set<OnboardingStep> = []
        if items.contains(where: { $0.id != Self.welcomeSampleItemId }) {
            evidence.insert(.addedOwnSource)
        }
        if items.contains(where: { $0.mediaType == "text" && $0.externalReferenceType == "url" }) {
            evidence.formUnion([.addedOwnSource, .addedFromSafari])
        }
        if items.contains(where: { $0.externalReferenceType == "file" }) {
            evidence.formUnion([.addedOwnSource, .addedFromFiles])
        }
        let hasSavedInterjection = try store.loadSessions().contains { session in
            ((try? store.loadInterjections(sessionId: session.id)) ?? [])
                .contains(where: { $0.status == "active" })
        }
        if hasSavedInterjection {
            evidence.insert(.firstInterjection)
        }
        markOnboardingSteps(evidence)
    }

    func dismissOnboardingCard() {
        isOnboardingCardDismissed = true
        UserDefaults.standard.set(true, forKey: Self.onboardingCardDismissedKey)
    }

    func restoreOnboardingCard() {
        isOnboardingCardDismissed = false
        UserDefaults.standard.set(false, forKey: Self.onboardingCardDismissedKey)
    }

    func pauseGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func continueGuidedOnboardingPastAI() {
        guard guidedOnboardingStage == .optionalAI else { return }
        setGuidedOnboardingStage(.exportSession)
    }

    func openAISettingsFromOnboarding() {
        continueGuidedOnboardingPastAI()
        isHelpPresented = false
        screen = .settings
    }

    func finishGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func recordTimelineInterjectionViewed(interjectionId: String) {
        guard selectedItem.interjections.contains(where: { $0.id == interjectionId }) else { return }
        recordTimelineReviewCompleted()
    }

    private func recordTimelineReviewCompleted() {
        markOnboardingSteps([.reviewedTimeline])
        if guidedOnboardingStage == .reviewTimeline {
            setGuidedOnboardingStage(.optionalAI)
        }
    }

    func recordSessionExported() {
        guard exportSessionId != nil else { return }
        markOnboardingSteps([.exportedSession])
        if guidedOnboardingStage == .exportSession {
            setGuidedOnboardingStage(.complete)
        }
    }

    func resetOnboardingProgressForTesting() {
        guard Self.isRunningUnitTests else { return }
        completedOnboardingSteps = []
        guidedOnboardingStage = .inactive
        isOnboardingCardDismissed = false
        UserDefaults.standard.removeObject(forKey: Self.onboardingStepsKey)
        UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingStageKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingCardDismissedKey)
    }

    init(
        sourceLinkResolver: LinkResolutionClient? = nil,
        sourceLinkHandoffStore: SourceLinkHandoffStore? = nil,
        browserTextHandoffStore: Gate5BrowserTextHandoffStore? = nil,
        audioPlaybackClient: AudioPlaybackClient? = nil,
        recordingClient: RecordingClient? = nil,
        forcePreparedTextGate: Bool = false,
        sourceTranscriptionClient: SourceTranscriptionClient = SystemSourceTranscriptionClient(),
        interjectionTranscriptionHandler: InterjectionTranscriptionHandler? = nil,
        preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler? = nil,
        gate2CompactControls: Gate2CompactControlController = Gate2CompactControlController(),
        featureFlags: SpokenMarginsFeatureFlags = .release,
        localFoundationModelClient: any LocalFoundationModelClient = AppleFoundationModelClient(),
        databaseURLOverride: URL? = nil,
        trashUndoDismissDelay: Duration = .seconds(5)
    ) {
        if sourceLinkResolver == nil,
           CommandLine.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK"] == "1" {
            self.sourceLinkResolver = UITestingAmbiguousSourceLinkResolver()
        } else {
            self.sourceLinkResolver = sourceLinkResolver
        }
        self.sourceLinkHandoffStore = sourceLinkHandoffStore
        self.browserTextHandoffStore = browserTextHandoffStore
        self.audioPlaybackClientOverride = audioPlaybackClient
        self.recordingClientOverride = recordingClient
        self.forcePreparedTextGate = forcePreparedTextGate
        self.sourceTranscriptionClient = sourceTranscriptionClient
        self.gate2CompactControls = gate2CompactControls
        self.featureFlags = featureFlags
        if CommandLine.arguments.contains("--ui-testing"),
           let rawMode = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_LOCAL_SUMMARY"],
           let mode = UITestingLocalFoundationModelClient.Mode(rawValue: rawMode) {
            self.localFoundationModelClient = UITestingLocalFoundationModelClient(mode: mode)
        } else {
            self.localFoundationModelClient = localFoundationModelClient
        }
        self.databaseURLOverride = databaseURLOverride
        self.trashUndoDismissDelay = trashUndoDismissDelay
        if let interjectionTranscriptionHandler {
            self.interjectionTranscriptionHandler = interjectionTranscriptionHandler
        } else {
            let transcriptionClient = SystemSpeechTranscriptionClient()
            self.interjectionTranscriptionHandler = { audioPath in
                try await transcriptionClient.transcribe(audioPath: audioPath)
            }
        }
        self.preparedTextAudioPrewarmHandler = preparedTextAudioPrewarmHandler
        localFoundationModelAvailability = localFoundationModelClient.availability()
        if CommandLine.arguments.contains("--ui-testing") {
            speechVoiceIdentifier = ""
            UserDefaults.standard.removeObject(forKey: "speechVoiceIdentifier")
            if let rawRate = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SPEECH_RATE"],
               let testRate = Double(rawRate) {
                speechRate = testRate
                UserDefaults.standard.set(testRate, forKey: "speechRate")
            }
            if ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SUPERTONIC"] == "1" {
                SpokenMarginsTerms.recordAcceptance()
                ttsVoiceSelection = .james
                UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
            }
        }
        migrateTTSSettingsIfNeeded()
        enforceTermsGateForStoredVoice()
        UserDefaults.standard.removeObject(forKey: "aiExecutionMode")
        refreshSpeechVoiceOptions()
        sanitizeTTSMode()
        settingsValueChanged()
        refreshQuickAccessFolder()
        streamingSpeechQueue.onTurnDrained = { [weak self] turnId in
            self?.finishStreamingTurnIfReady(turnId)
        }
        streamingSpeechQueue.onPlaybackObservation = { [weak self] observation in
            self?.applyStreamingSpeechObservation(observation)
        }
    }

    private func migrateTTSSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.supertonicTTSMigrationKey) else {
            synchronizeTTSModeFromSelection()
            return
        }

        // This is intentionally a one-way pre-1.0 migration. Legacy Piper,
        // Kokoro, and system-only modes all move to the bundled default voice;
        // the prior Apple voice identifier remains available for fallback.
        ttsVoiceSelection = .james
        ttsMode = "supertonic"
        defaults.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        defaults.set(ttsMode, forKey: "ttsMode")
        defaults.set(true, forKey: Self.supertonicTTSMigrationKey)
    }

    private func synchronizeTTSModeFromSelection() {
        ttsMode = ttsVoiceSelection == .system ? "systemImmediate" : "supertonic"
    }

    private func enforceTermsGateForStoredVoice() {
        let defaults = UserDefaults.standard
        hasAcceptedCurrentTerms = SpokenMarginsTerms.hasAcceptedCurrentVersion()
            && SpokenMarginsTerms.hasBundledText()
        acceptedTermsVersion = SpokenMarginsTerms.acceptedVersion()
        if hasAcceptedCurrentTerms {
            defaults.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
            return
        }
        if ttsVoiceSelection.supertonicVoice != nil {
            pendingTermsVoiceSelection = ttsVoiceSelection
            defaults.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
        } else if let rawValue = defaults.string(forKey: Self.supertonicVoicePendingTermsKey),
                  let pendingVoice = AppTTSVoiceSelection(rawValue: rawValue),
                  pendingVoice.supertonicVoice != nil {
            pendingTermsVoiceSelection = pendingVoice
        }
        guard pendingTermsVoiceSelection != nil else { return }
        ttsVoiceSelection = .system
        synchronizeTTSModeFromSelection()
        defaults.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        defaults.set(ttsMode, forKey: "ttsMode")
    }

    var termsAcceptanceDescription: String {
        if hasAcceptedCurrentTerms {
            return "Accepted version \(SpokenMarginsTerms.currentVersion)"
        }
        if let acceptedTermsVersion {
            return "Version \(acceptedTermsVersion) expired"
        }
        return "Not accepted · iOS voice only"
    }

    func acceptCurrentTermsAndEnableOnDeviceVoice() {
        guard SpokenMarginsTerms.hasBundledText() else {
            pendingTermsVoiceSelection = nil
            isTermsOfUsePresented = false
            ttsVoiceSelection = .system
            saveSpeechSettings()
            reportFailure(SpokenMarginsTermsError.bundledTermsUnavailable, context: "Terms acceptance failed")
            return
        }
        let pendingPlayback = pendingPlaybackAfterTerms
        pendingPlaybackAfterTerms = nil
        SpokenMarginsTerms.recordAcceptance()
        hasAcceptedCurrentTerms = true
        acceptedTermsVersion = SpokenMarginsTerms.currentVersion
        isTermsOfUsePresented = false
        ttsVoiceSelection = pendingTermsVoiceSelection ?? .james
        pendingTermsVoiceSelection = nil
        UserDefaults.standard.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
        saveSpeechSettings()
        if let engine {
            snapshot = (try? engine.stopPlayback()) ?? snapshot
            refreshSelectedItem()
        }
        _ = rebuildEngineForCurrentSettings()
        diagnostics["termsAcceptedVersion"] = SpokenMarginsTerms.currentVersion
        reportConfirmation("Terms accepted. \(ttsVoiceSelection.displayName) is enabled.")
        continuePlaybackAfterTerms(pendingPlayback)
    }

    func declineCurrentTerms() {
        let pendingPlayback = pendingPlaybackAfterTerms
        pendingPlaybackAfterTerms = nil
        pendingTermsVoiceSelection = nil
        UserDefaults.standard.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
        isTermsOfUsePresented = false
        ttsVoiceSelection = .system
        saveSpeechSettings()
        reportSuccess("The iOS system voice remains enabled.")
        continuePlaybackAfterTerms(pendingPlayback)
    }

    private func requireTermsDecisionBeforePlayback(_ action: PendingPlaybackAfterTerms) -> Bool {
        guard !hasAcceptedCurrentTerms, pendingTermsVoiceSelection?.supertonicVoice != nil else {
            return false
        }
        pendingPlaybackAfterTerms = action
        isTermsOfUsePresented = true
        diagnostics["termsGate"] = "presented_for_first_playback"
        statusMessage = "Choose whether to enable the improved on-device voice before playback begins."
        return true
    }

    private func continuePlaybackAfterTerms(_ action: PendingPlaybackAfterTerms?) {
        guard let action else { return }
        switch action {
        case .startCurrentItem:
            start()
        case .resumeSession(let sessionId):
            guard let session = try? store?.loadSession(id: sessionId) else {
                reportFailure("The listening session could not be restored after choosing a voice.")
                return
            }
            resumeSession(session)
        case .jumpToChapter(let chapterId, let fromTimeline):
            guard let chapter = selectedItem.chapters.first(where: { $0.id == chapterId }) else {
                reportFailure("The selected chapter could not be restored after choosing a voice.")
                return
            }
            jumpToChapter(chapter, fromTimeline: fromTimeline)
        case .playSourceFromBeginning(let fromTimeline):
            playSourceFromBeginning(fromTimeline: fromTimeline)
        }
    }

    var aiDataSharingConsentDescription: String {
        switch aiDataSharingConsent {
        case .unknown: return "Not decided"
        case .grantedV1: return "Allowed for live OpenAI requests"
        case .declined: return "Not allowed"
        }
    }

    var remoteProviderExperienceEnabled: Bool {
        featureFlags.remoteProviderExperienceEnabled
    }

    var localFoundationModelAvailable: Bool {
        localFoundationModelAvailability.isAvailable
    }

    var localFoundationModelAvailabilityDescription: String {
        localFoundationModelAvailability.description
    }

    var aiSummaryExperienceAvailable: Bool {
        remoteProviderExperienceEnabled || localFoundationModelAvailable
    }

    var canGenerateListeningMap: Bool {
        guard selectedItem.chapters.isEmpty, selectedItem.mediaChapters.isEmpty else { return false }
        guard let item = try? store?.loadItem(id: activeItemId) else { return false }
        return remoteProviderExperienceEnabled || item.media == nil
    }

    var listeningMapGenerationAvailabilityDescription: String {
        if !selectedItem.chapters.isEmpty || !selectedItem.mediaChapters.isEmpty {
            return "This item already has a Listening Map."
        }
        guard let item = try? store?.loadItem(id: activeItemId) else {
            return "Listening Map generation is unavailable."
        }
        if item.media != nil, !remoteProviderExperienceEnabled {
            return "Publisher chapters appear when available. AI-generated podcast maps are not included in this release."
        }
        return "Listening Map generation is unavailable."
    }

    static let supportedMediaSkipSeconds = [10, 15, 30, 45, 60]
    static let supportedPodcastCacheLimitsGB = PodcastCacheLimitGB.allCases.map(\.rawValue)
    static let supportedRenderedSpeechCacheLimitsMB = [128, 256, 512, 1_024]

    var selectedPodcastDownloadState: PodcastDownloadState? {
        podcastDownloadRecords[selectedItem.id]?.state
    }

    var selectedPodcastDownloadDescription: String? {
        guard let record = podcastDownloadRecords[selectedItem.id] else { return nil }
        if record.state == .downloading, let progress = record.progress {
            return "Downloading \(Int((progress * 100).rounded()))%"
        }
        if record.state == .failed, let reason = record.failureReason {
            return "Failed: \(reason)"
        }
        return record.state.displayName
    }

    private static func storedMediaSkipSeconds(forKey key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return supportedMediaSkipSeconds.contains(value) ? value : 15
    }

    private static func storedRenderedSpeechCacheLimitMB() -> Int {
        let value = UserDefaults.standard.integer(forKey: "renderedSpeechCacheLimitMB")
        return supportedRenderedSpeechCacheLimitsMB.contains(value) ? value : 256
    }

    func grantAIDataSharingConsent() {
        aiDataSharingConsent = .grantedV1
        UserDefaults.standard.set(aiDataSharingConsent.rawValue, forKey: "aiDataSharingConsent")
        isAIDataSharingConsentPresented = false
        diagnostics["aiDataSharingConsent"] = aiDataSharingConsent.rawValue

        let pendingJob = pendingProviderJobForConsent
        pendingProviderJobForConsent = nil
        let shouldGenerateMap = pendingMapGenerationAfterConsent
        pendingMapGenerationAfterConsent = false
        if shouldGenerateMap {
            generateListeningMap()
        }
        if let pendingJob {
            submitProviderJobIfNeeded(
                kind: pendingJob.kind,
                turnId: pendingJob.turnId,
                messages: pendingJob.messages,
                force: pendingJob.force
            )
        }
    }

    func declineAIDataSharingConsent() {
        aiDataSharingConsent = .declined
        UserDefaults.standard.set(aiDataSharingConsent.rawValue, forKey: "aiDataSharingConsent")
        isAIDataSharingConsentPresented = false
        pendingMapGenerationAfterConsent = false
        if pendingProviderJobForConsent != nil {
            markProviderFailure("ai_data_sharing_not_allowed", userMessage: "Live AI request cancelled. No content was sent.")
        } else {
            reportConfirmation("Live AI request cancelled. No content was sent.")
        }
        pendingProviderJobForConsent = nil
    }

    func revokeAIDataSharingConsent() {
        aiDataSharingConsent = .unknown
        UserDefaults.standard.removeObject(forKey: "aiDataSharingConsent")
        pendingProviderJobForConsent = nil
        pendingMapGenerationAfterConsent = false
        diagnostics["aiDataSharingConsent"] = aiDataSharingConsent.rawValue
        reportConfirmation("OpenAI data-sharing permission revoked.")
    }

    func deleteProviderAPIKey() {
        let existingKey = providerAPIKey
        providerAPIKey = ""
        let status = KeychainStore.save("", service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        guard status == errSecSuccess else {
            providerAPIKey = existingKey
            diagnostics["keychainStatus"] = "delete_failed:\(status)"
            reportFailure("The OpenAI API key could not be deleted from Keychain (\(status)).")
            return
        }
        diagnostics["apiKeyConfigured"] = "false"
        diagnostics["keychainStatus"] = "deleted"
        _ = rebuildEngineForCurrentSettings()
        reportConfirmation("OpenAI API key deleted from Keychain.")
    }

    deinit {
        playbackProgressTask?.cancel()
        trashUndoDismissTask?.cancel()
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        sourceImportTask?.cancel()
        quickAccessRefreshTask?.cancel()
        interjectionAudioCompletionTask?.cancel()
    }

    private func reconcilePlaybackProgressTicker() {
        if snapshot.status.isPlaybackActive {
            startPlaybackProgressTicker()
        } else {
            stopPlaybackProgressTicker()
        }
    }

    private func startPlaybackProgressTicker() {
        guard playbackProgressTask == nil else { return }
        playbackProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    guard let self else { return }
                    guard self.snapshot.status.isPlaybackActive else {
                        self.stopPlaybackProgressTicker()
                        return
                    }
                    guard let engine = self.engine else { return }
                    do {
                        self.synchronizeStreamingSpeechAnchorIfNeeded()
                        let previousStatus = self.snapshot.status
                        let previousTargetId = self.snapshot.targetId
                        let updated = self.snapshotReflectingTextAudioPrewarmStatus(
                            try engine.syncPlaybackProgress(),
                            itemId: self.activeItemId
                        )
                        let completedCurrentAudio = previousStatus.isPlaybackActive &&
                            updated.status == .paused &&
                            previousTargetId == updated.targetId &&
                            updated.currentPlaybackProgressPercent >= 100
                        if let fallbackSnapshot = self.retryWithDefaultVoiceIfNeeded(updated, engine: engine) {
                            self.snapshot = fallbackSnapshot
                            return
                        }
                        if updated != self.snapshot {
                            self.snapshot = updated
                        }
                        let playedPendingTurn = self.playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
                        if completedCurrentAudio && !playedPendingTurn {
                            self.closeCompletedSessionIfReady()
                        }
                    } catch {
                        self.diagnostics["playbackProgressSyncError"] = String(describing: error)
                    }
                }
            }
        }
    }

    private func stopPlaybackProgressTicker() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
    }

    private func retryWithDefaultVoiceIfNeeded(_ failedSnapshot: SessionSnapshot, engine: SessionEngine) -> SessionSnapshot? {
        guard failedSnapshot.status == .failed,
              failedSnapshot.targetType == TargetType.itemTextTTS.rawValue,
              let sessionId = failedSnapshot.sessionId,
              !speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !defaultVoiceFallbackSessionIds.contains(sessionId) else {
            return nil
        }
        defaultVoiceFallbackSessionIds.insert(sessionId)
        do {
            _ = try engine.updateSpeechPlaybackSettings(voiceIdentifier: nil, rate: Float(speechRate))
            let resumed = try engine.resumePlayback()
            diagnostics["speechVoiceFallback:\(sessionId)"] = "default_voice_from_confirmed_offset"
            reportWarning("The selected voice was unavailable offline. Continuing with the installed default voice.")
            return resumed
        } catch {
            diagnostics["speechVoiceFallback:\(sessionId)"] = "failed:\(error.localizedDescription)"
            return nil
        }
    }

    func syncPlaybackProgressForLifecycle() {
        guard snapshot.status.isPlaybackActive, let engine else { return }
        do {
            synchronizeStreamingSpeechAnchorIfNeeded()
            let previousStatus = snapshot.status
            let previousTargetId = snapshot.targetId
            let updated = snapshotReflectingTextAudioPrewarmStatus(
                try engine.syncPlaybackProgress(),
                itemId: activeItemId
            )
            let completedCurrentAudio = previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
            if updated != snapshot {
                snapshot = updated
            }
            let playedPendingTurn = playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
            if completedCurrentAudio && !playedPendingTurn {
                closeCompletedSessionIfReady()
            }
            refreshSelectedItem()
            diagnostics["playbackLifecycleSync"] = "saved"
        } catch {
            diagnostics["playbackLifecycleSyncError"] = String(describing: error)
        }
    }

    func refreshLockScreenSurfacesForLifecycle() {
        gate2CompactControls.reconcileLiveActivities()
        diagnostics["lockScreenLifecycleRefresh"] = snapshot.targetType ?? "none"
    }

    func handleAppBecameInactiveOrBackground() {
        if snapshot.status == .starting,
           let supertonic = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
           supertonic.ensurePlaybackStartsBeforeBackgrounding() {
            diagnostics["textAudioBackgroundStartup"] = "system_fallback_started"
        }
        syncPlaybackProgressForLifecycle()
        refreshLockScreenSurfacesForLifecycle()
    }

    private func reflectTextAudioPrewarmStatusIfActive(itemId: String) {
        let updated = snapshotReflectingTextAudioPrewarmStatus(snapshot, itemId: itemId)
        guard updated != snapshot else { return }
        snapshot = updated
    }

    private func snapshotReflectingTextAudioPrewarmStatus(_ snapshot: SessionSnapshot, itemId: String) -> SessionSnapshot {
        guard textAudioPrewarmTasks[itemId] != nil else { return snapshot }
        guard snapshot.preparedTextAudioStatus == nil || snapshot.preparedTextAudioStatus == "live_fallback" else { return snapshot }
        var updated = snapshot
        updated.preparedTextAudioStatus = "rendering"
        return updated
    }

    func bootstrapLibraryIfNeeded() {
        guard libraryItems.isEmpty, store == nil else { return }
        do {
            let store = try requireStore()
            if let fixtureText = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"],
               CommandLine.arguments.contains("--ui-testing") {
                try resetAndSeedUITestingText(
                    store: store,
                    title: ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] ?? "UI Test Text",
                    text: fixtureText,
                    reference: ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] ?? "ui-test"
                )
                return
            }
            if CommandLine.arguments.contains("--ui-testing") {
                resetAndSeed()
                return
            }
            var rows = try loadLibraryRows(store: store)
            let storedWelcomeSampleVersion = UserDefaults.standard.integer(
                forKey: Self.welcomeSampleSeedVersionKey
            )
            if Self.shouldSeedWelcomeSample(
                libraryIsEmpty: rows.isEmpty,
                storedVersion: storedWelcomeSampleVersion,
                isUITesting: CommandLine.arguments.contains("--ui-testing")
            ) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                rows = try loadLibraryRows(store: store)
                diagnostics["welcomeSample"] = "seeded:v\(Self.welcomeSampleSeedVersion)"
            }
            if !CommandLine.arguments.contains("--ui-testing"),
               storedWelcomeSampleVersion < Self.welcomeSampleSeedVersion {
                UserDefaults.standard.set(
                    Self.welcomeSampleSeedVersion,
                    forKey: Self.welcomeSampleSeedVersionKey
                )
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            try reconcileOnboardingEvidence(store: store)
            try recoverInterruptedAIJobs(store: store, rows: rows)
            libraryItems = rows
            recentlyDeletedItems = try loadDeletedLibraryRows(store: store)
            let availableItemIDs = Set(rows.map(\.id))
            if let restoredSession = try store.loadSessions().first(where: {
                Self.isResumableSession($0) && availableItemIDs.contains($0.itemId)
            }), let engine {
                activeItemId = restoredSession.itemId
                snapshot = try engine.inspectSession(sessionId: restoredSession.id)
                selectedItem = try loadItemDetail(id: restoredSession.itemId, store: store)
                diagnostics["restoredSession"] = restoredSession.id
                diagnostics["restoredSessionMode"] = "paused_without_autoplay"
            } else if let first = rows.first {
                activeItemId = first.id
                selectedItem = try loadItemDetail(id: first.id, store: store)
            } else {
                selectedItem = ItemDetailState()
            }
            diagnostics["libraryBootstrap"] = "loaded:\(rows.count)"
            reportSuccess(rows.isEmpty ? "Add a source to begin." : "Library ready.")
        } catch {
            reportFailure(error, context: "Library bootstrap failed")
        }
    }

    private func resetAndSeedUITestingText(
        store: SQLiteSessionStore,
        title: String,
        text: String,
        reference: String
    ) throws {
        try store.reset()
        let item = Item(
            id: "item-ui-text-regression",
            title: title,
            mediaType: "text",
            text: text,
            externalReference: reference,
            status: "needs_listening_map"
        )
        try store.seed(item: item)
        self.store = store
        try configurePodcastDownloads(store: store)
        installEngine(try makeEngine(store: store))
        activeItemId = item.id
        liveSpeechFallbackItemIds.insert(item.id)
        snapshot = SessionSnapshot()
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = []
        dismissTrashUndo()
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics = [
            "runtimeProfile": selectedProfileId,
            "uiTestFixture": item.id,
            "speechRate": String(format: "%.2f", speechRate)
        ]
        reportSuccess("Loaded simulator speech regression article.")
    }

    static func shouldSeedWelcomeSample(
        libraryIsEmpty: Bool,
        storedVersion: Int,
        isUITesting: Bool
    ) -> Bool {
        libraryIsEmpty && storedVersion < welcomeSampleSeedVersion && !isUITesting
    }

    func handleAppBecameActive() {
        let refreshedAvailability = localFoundationModelClient.availability()
        if refreshedAvailability != localFoundationModelAvailability {
            localFoundationModelAvailability = refreshedAvailability
            diagnostics["localFoundationModelAvailability"] = refreshedAvailability.description
            _ = rebuildEngineForCurrentSettings()
        }
        syncPlaybackProgressForLifecycle()
        gate2CompactControls.reconcileLiveActivities()
        importPendingSourceLinkHandoffs()
    }

    func handleApplicationWillTerminate() {
        syncPlaybackProgressForLifecycle()
        endTextPlaybackStartupBackgroundTask()
        gate2CompactControls.endLiveActivities()
    }

    func handleMemoryWarning() {
        guard let renderer = supertonicRenderer else { return }
        diagnostics["supertonicMemoryPressure"] = "sessions_unloaded"
        Task { await renderer.unload(removingGeneratedAudio: false) }
    }

    func resetAndSeed() {
        do {
            if Self.isRunningUnitTests, databaseURLOverride == nil {
                databaseURLOverride = FileManager.default.temporaryDirectory
                    .appending(path: "spoken-margins-tests-\(UUID().uuidString).sqlite")
            }
            let databaseURL = try databaseURL()
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.reset()
            let item = try loadFixtureItem(name: "text-with-listening-map")
            let map = try loadFixtureMap(name: "valid-listening-map")
            try store.seed(item: item)
            try store.seed(map: map)
            self.store = store
            try configurePodcastDownloads(store: store)
            installEngine(try makeEngine(store: store))
            activeItemId = item.id
            snapshot = SessionSnapshot()
            libraryItems = try loadLibraryRows(store: store)
            recentlyDeletedItems = []
            dismissTrashUndo()
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics = [
                "runtimeProfile": selectedProfileId,
                "seededItems": "1",
                "database": databaseURL.lastPathComponent
            ]
            exportPreview = ""
            reportSuccess("Listening queue ready.")
        } catch {
            reportFailure(error, context: "Reset and seed failed")
        }
    }

    func addSampleItem() {
        do {
            let store = try requireStore()
            let (item, map) = try makeAppOverviewSample()
            try store.saveItem(item)
            try store.saveListeningMap(map)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            activeItemId = item.id
            try refreshLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            screen = .item
            reportSuccess("Sample added.")
        } catch {
            reportFailure(error, context: "Add sample failed")
        }
    }

    func startGuidedOnboarding() {
        do {
            let store = try requireStore()
            if !(try store.listItems()).contains(where: { $0.id == Self.welcomeSampleItemId }) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                try refreshLibraryRows(store: store)
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            restoreOnboardingCard()
            isHelpPresented = false
            if hasCompletedCoreOnboarding {
                setGuidedOnboardingStage(.practiceInterjection)
            } else if !isOnboardingStepComplete(.firstInterjection) {
                setGuidedOnboardingStage(.practiceInterjection)
            } else if !isOnboardingStepComplete(.reviewedTimeline) {
                setGuidedOnboardingStage(.reviewTimeline)
            } else if !isOnboardingStepComplete(.exportedSession) {
                setGuidedOnboardingStage(.optionalAI)
            } else {
                setGuidedOnboardingStage(.complete)
            }
            startItem(id: Self.welcomeSampleItemId)
        } catch {
            reportFailure(error, context: "Guided tour setup failed")
        }
    }

    private func makeAppOverviewSample() throws -> (Item, ListeningMap) {
        let itemId = Self.welcomeSampleItemId
        let optionalAIOverview = remoteProviderExperienceEnabled
            ? "Summarize Notes synthesizes the interjections in this session. Discuss answers a question using relevant source and session context. Both are optional and require your OpenAI API key, network access, and separate permission to send content."
            : "Summarize Notes synthesizes the interjections in this session with Apple’s on-device model when available. Remote discussion and third-party API keys are disabled; you can copy your notes to another chatbot and paste its response back into Spoken Margins."
        let markdown = """
        # Welcome to Spoken Margins

        Spoken Margins is a structured listening workspace. It restores the headings, progress, margin notes, and easy navigation that ordinary audio loses, so reading can become an active listening session.

        ## Start with the Listening Map

        Tap Start Listening on this source. The overview plays first, and the Timeline shows the chapters below. Tap any chapter to jump directly to it while keeping your place in the source.

        ## Move forward and backward

        On Now Playing, use the backward and forward buttons around Play to move by paragraph. The progress slider can move farther through the source, and the speech-rate slider changes how quickly it is read.

        ## Interject while you listen

        This is your practice cue. Tap Interject now, say one thing you want to remember about this tour, then tap Done. Spoken Margins anchors the interjection near the passage you were hearing and resumes without losing your place. Open the Timeline and tap your note to review its recording or transcript.

        ## Load your own sources

        Return Home and tap Add Source. Paste text and choose Add and Listen; paste a podcast, RSS, or public audio link and choose Add Link and Listen; or choose Import Text or PDF Files to upload Markdown, plain-text, or text-based PDF files. In Safari, enable Spoken Margins Text under Manage Extensions to capture selected text or a readable article, or run the Add Article to Spoken Margins Shortcut from Safari’s Share menu. You can also share a PDF, Markdown file, or text file directly to Spoken Margins.

        ## Keep what matters

        \(optionalAIOverview) Listening, interjections, the Timeline, and export work without AI. Export the useful context for another writing or thinking tool. The goal is not passive playback; it is to help you retain and develop the ideas that mattered.
        """
        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "Welcome to Spoken Margins.md",
            contents: markdown
        )
        let item = Item(
            id: itemId,
            title: parsed.title,
            mediaType: "text",
            text: parsed.text,
            externalReference: "",
            status: "ready"
        )
        guard var map = parsed.deterministicListeningMap(itemId: itemId) else {
            throw SessionKitError.persistenceFailed("welcome_sample_listening_map_missing")
        }
        map.overview = "Take a guided tour of the Listening Map, playback navigation, spoken interjections, and the three ways to add your own sources."
        return (item, map)
    }

    func importTextItem() {
        do {
            let store = try requireStore()
            let itemId = "item-import-\(UUID().uuidString.lowercased())"
            let enteredTitle = importTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try ObsidianMarkdownParser.parse(
                fileName: enteredTitle.isEmpty ? "Imported Text.md" : "\(enteredTitle).md",
                contents: importText,
                titleOverride: enteredTitle.isEmpty ? nil : enteredTitle
            )
            let deterministicMap = parsed.deterministicListeningMap(itemId: itemId)
            let item = Item(
                id: itemId,
                title: enteredTitle.isEmpty ? parsed.title : enteredTitle,
                mediaType: "text",
                text: parsed.text,
                externalReference: "manual-import",
                status: deterministicMap == nil ? "needs_listening_map" : "ready",
                externalReferenceType: "manual"
            )
            try store.seed(item: item)
            if let deterministicMap {
                try store.saveListeningMap(deterministicMap)
                diagnostics["lastListeningMapMode"] = "deterministic_headings"
                diagnostics["lastGeneratedMapItem"] = item.id
            }
            installEngine(try makeEngine(store: store))
            activeItemId = item.id
            scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics["lastImport"] = item.id
            markOnboardingSteps([.addedOwnSource])
            importTitle = ""
            importText = ""
            startItem(id: item.id)
        } catch {
            reportFailure(error, context: "Import failed")
        }
    }

    func pasteImportTextFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain text.")
            return
        }
        importText = clipboardText
        reportSuccess("Pasted text from Clipboard.")
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    func importObsidianMarkdownFiles(urls: [URL]) {
        beginObsidianMarkdownImport(urls: urls, securityScopedURLs: urls)
    }

    var isImportingSources: Bool {
        sourceImportProgressMessage != nil
    }

    private func beginObsidianMarkdownImport(
        urls: [URL],
        securityScopedURLs: [URL],
        refreshQuickFolderWhenFinished: Bool = false
    ) {
        guard !urls.isEmpty else {
            reportFailure("Choose at least one Markdown, text, or PDF file to import.")
            return
        }
        guard sourceImportTask == nil else {
            reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            return
        }

        let requests = urls.enumerated().map { index, url in
            ObsidianImportRequest(
                url: url,
                itemId: obsidianItemId(fileName: url.lastPathComponent, index: index)
            )
        }
        let scopedAccess = securityScopedURLs.map { url in
            (url: url, didAccess: url.startAccessingSecurityScopedResource())
        }
        sourceImportProgressMessage = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…"
        statusMessage = sourceImportProgressMessage ?? "Importing sources…"
        lastError = nil

        sourceImportTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                Self.prepareObsidianImports(requests)
            }.value
            scopedAccess.forEach { entry in
                if entry.didAccess {
                    entry.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            self.completeObsidianMarkdownImport(batch, refreshQuickFolderWhenFinished: refreshQuickFolderWhenFinished)
        }
    }

    private nonisolated static func prepareObsidianImports(_ requests: [ObsidianImportRequest]) -> ObsidianImportBatch {
        var prepared: [PreparedObsidianImport] = []
        var failures: [String] = []
        for request in requests {
            do {
                let raw = try importableText(from: request.url)
                let parsed = try ObsidianMarkdownParser.parse(fileName: request.url.lastPathComponent, contents: raw)
                let deterministicMap = parsed.deterministicListeningMap(itemId: request.itemId)
                let item = Item(
                    id: request.itemId,
                    title: parsed.title,
                    mediaType: "text",
                    text: parsed.text,
                    externalReference: parsed.source ?? request.url.lastPathComponent,
                    status: deterministicMap == nil ? "needs_listening_map" : "ready",
                    externalReferenceType: "file"
                )
                prepared.append(PreparedObsidianImport(item: item, listeningMap: deterministicMap))
            } catch {
                failures.append("\(request.url.lastPathComponent): \(error)")
            }
        }
        return ObsidianImportBatch(prepared: prepared, failures: failures)
    }

    private nonisolated static func importableText(from url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "pdf" else {
            return try String(contentsOf: url, encoding: .utf8)
        }
        #if canImport(PDFKit)
        do {
            return try PDFStructuredTextExtractor.markdown(from: url)
        } catch PDFStructuredTextExtractor.ExtractionError.noExtractableText {
            throw SourceFileImportError.pdfHasNoExtractableText
        }
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    private func completeObsidianMarkdownImport(
        _ batch: ObsidianImportBatch,
        refreshQuickFolderWhenFinished: Bool
    ) {
        defer {
            sourceImportTask = nil
            sourceImportProgressMessage = nil
            if refreshQuickFolderWhenFinished {
                refreshQuickAccessFolder()
            }
        }
        do {
            let store = try requireStore()
            let preservesActiveSession = hasActiveSession && engine != nil
            let preservedActiveItemId = activeItemId
            let preservedSelectedItemId = selectedItem.id
            var imported: [Item] = []
            var failures = batch.failures
            for prepared in batch.prepared {
                do {
                    try store.saveItem(prepared.item)
                    if let listeningMap = prepared.listeningMap {
                        try store.saveListeningMap(listeningMap)
                    }
                    imported.append(prepared.item)
                } catch {
                    failures.append("\(prepared.item.title): \(error)")
                }
            }
            guard !imported.isEmpty else {
                reportFailure(failures.isEmpty ? "No source files were imported." : failures.joined(separator: "\n"))
                return
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            libraryItems = try loadLibraryRows(store: store)
            if preservesActiveSession {
                activeItemId = preservedActiveItemId
                if !preservedSelectedItemId.isEmpty {
                    selectedItem = try loadItemDetail(id: preservedSelectedItemId, store: store)
                }
            } else {
                activeItemId = imported.first?.id ?? activeItemId
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
                screen = .home
            }
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            markOnboardingSteps([.addedOwnSource, .addedFromFiles])
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportConfirmation("Imported \(imported.count) source file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            reportFailure(error, context: "File import failed")
        }
    }

    @discardableResult
    func importSourceLinkFromForm() -> Bool {
        let success = importSourceLink(
            urlString: sourceLinkURL,
            sourceSurface: "paste",
            startSession: true
        )
        if success {
            sourceLinkURL = ""
        }
        return success
    }

    @discardableResult
    func beginSourceLinkImportFromForm() -> Bool {
        guard !isResolvingSourceLink else { return false }
        let submittedURL = sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: submittedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host != nil else {
            sourceLinkImportState = "failure"
            sourceLinkImportMessage = submittedURL.isEmpty
                ? "Paste or enter a podcast, RSS, or audio URL first."
                : "Enter a valid HTTP or HTTPS podcast, RSS, or audio URL."
            reportFailure(sourceLinkImportMessage ?? "Enter a valid source URL.")
            return false
        }
        isResolvingSourceLink = true
        sourceLinkImportState = "resolving"
        sourceLinkImportMessage = "Resolving source link…"
        statusMessage = "Resolving source link..."
        lastError = nil
        diagnostics["lastSourceLinkButtonTap"] = "registered"
        Task { @MainActor in
            await Task.yield()
            let imported = await importSourceLinkAsync(
                urlString: parsedURL.absoluteString,
                sourceSurface: "paste",
                startSession: true
            )
            if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
                sourceLinkURL = ""
            }
            let awaitsCandidateReview = sourceLinkCandidateReview?.request.inputURL == parsedURL.absoluteString
            if awaitsCandidateReview {
                sourceLinkImportState = "review"
                sourceLinkImportMessage = "Choose the matching podcast episode."
            } else {
                sourceLinkImportState = imported ? "success" : "failure"
                sourceLinkImportMessage = imported ? "Source added." : (lastError ?? "This source could not be added.")
            }
        }
        return true
    }

    func pasteSourceLinkFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain a URL.")
            return
        }
        let pasted = Self.firstURL(in: clipboardText)?.absoluteString ?? clipboardText
        sourceLinkURL = pasted
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        reportSuccess("Pasted link from Clipboard.")
        diagnostics["lastSourceLinkClipboardPaste"] = pasted
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    func resetSourceLinkImportState() {
        guard !isResolvingSourceLink else { return }
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
    }

    @discardableResult
    func importSourceLink(_ handoff: SourceLinkHandoff) -> Bool {
        importSourceLink(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(_ handoff: SourceLinkHandoff) async -> Bool {
        await importSourceLinkAsync(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(urlString: String, sourceSurface: String, startSession: Bool = true) async -> Bool {
        guard sourceLinkResolver == nil else {
            return importSourceLink(urlString: urlString, sourceSurface: sourceSurface, startSession: startSession)
        }
        isResolvingSourceLink = true
        statusMessage = "Resolving source link..."
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        let request = LinkResolutionRequest(
            id: "source-link-\(Int(Date().timeIntervalSince1970))",
            inputURL: url.absoluteString,
            sourceSurface: sourceSurface,
            createdAt: Date()
        )
        do {
            let result = try await PublicPodcastLinkResolver().resolveAsync(request)
            return importResolvedSourceLink(request: request, result: result, startSession: startSession)
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    func importSourceLink(urlString: String, sourceSurface: String, startSession: Bool = true) -> Bool {
        isResolvingSourceLink = true
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        do {
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            statusMessage = "Resolving source link..."
            let request = LinkResolutionRequest(
                id: "source-link-\(Int(Date().timeIntervalSince1970))",
                inputURL: url.absoluteString,
                sourceSurface: sourceSurface,
                createdAt: Date()
            )
            let imported = try engine.importSourceLink(request, startSessionWhenPlayable: startSession)
            snapshot = startSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = engine.lastLinkResolutionResult?.originalLink.provider
                ?? engine.lastLinkResolutionResult?.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.needsReview.rawValue,
               let result = engine.lastLinkResolutionResult,
               presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: startSession) {
                return false
            }
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    let resolved = engine.lastLinkResolutionResult
                    scheduleSourceTranscriptImportIfAvailable(
                        resolved?.selectedCandidate?.transcriptLinks ?? resolved?.candidates.flatMap(\.transcriptLinks) ?? [],
                        itemId: itemId
                    )
                }
                reportConfirmation(startSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    private func importResolvedSourceLink(request: LinkResolutionRequest, result: LinkResolutionResult, startSession: Bool = true) -> Bool {
        do {
            if presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: startSession) {
                return false
            }
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            let imported = try engine.importResolvedSourceLink(request, result: result, startSessionWhenPlayable: startSession)
            snapshot = startSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    scheduleSourceTranscriptImportIfAvailable(
                        result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                        itemId: itemId
                    )
                }
                reportConfirmation(startSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    private func presentSourceLinkCandidateReviewIfAvailable(
        request: LinkResolutionRequest,
        result: LinkResolutionResult,
        startSession: Bool
    ) -> Bool {
        let playableCandidates = result.candidates.filter { candidate in
            guard let audioURL = candidate.audioURL,
                  let url = URL(string: audioURL) else { return false }
            return url.scheme?.lowercased() == "https"
        }
        guard result.status == .needsReview, playableCandidates.count > 1 else { return false }
        var reviewResult = result
        reviewResult.candidates = playableCandidates
        sourceLinkCandidateReview = SourceLinkCandidateReviewState(
            request: request,
            result: reviewResult,
            startSession: startSession
        )
        diagnostics["lastSourceLinkReviewCandidates"] = "\(playableCandidates.count)"
        reportSuccess("Choose the matching podcast episode. Nothing has been imported yet.")
        return true
    }

    func selectSourceLinkCandidate(_ candidate: LinkResolutionCandidate) {
        guard let review = sourceLinkCandidateReview,
              review.result.candidates.contains(candidate) else { return }
        sourceLinkCandidateReview = nil
        var selected = review.result
        selected.status = .playable
        selected.selectedCandidate = candidate
        selected.candidates = [candidate]
        selected.failureReason = nil
        let imported = importResolvedSourceLink(request: review.request, result: selected, startSession: review.startSession)
        sourceLinkImportState = imported ? "success" : "failure"
        sourceLinkImportMessage = imported ? "Source added." : (lastError ?? "This source could not be added.")
        if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == review.request.inputURL {
            sourceLinkURL = ""
        }
    }

    func cancelSourceLinkCandidateReview() {
        sourceLinkCandidateReview = nil
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = "Podcast import cancelled."
        reportSuccess("Podcast import cancelled. Nothing was added.")
    }

    private func importSourceLinkInBackground(_ handoff: SourceLinkHandoff) async throws {
        let trimmed = handoff.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SessionKitError.persistenceFailed("This share does not contain a valid podcast, RSS, or audio URL.")
        }
        let request = LinkResolutionRequest(
            id: handoff.id,
            inputURL: url.absoluteString,
            sourceSurface: handoff.sourceSurface,
            createdAt: Date()
        )
        let result: LinkResolutionResult
        if let sourceLinkResolver {
            result = try sourceLinkResolver.resolve(request)
        } else {
            result = try await PublicPodcastLinkResolver().resolveAsync(request)
        }
        guard result.status == .playable else {
            let provider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkFailureCategory"] = result.failureReason
                ?? result.status.rawValue
            throw SessionKitError.persistenceFailed(sourceLinkFailureMessage(
                status: result.status.rawValue,
                reason: result.failureReason,
                provider: provider
            ))
        }

        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(request, result: result) else {
            throw SessionKitError.persistenceFailed("The shared podcast did not expose playable audio.")
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        scheduleSourceTranscriptImportIfAvailable(
            result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
            itemId: item.id
        )
    }

    private func importBrowserTextInBackground(_ handoff: BrowserTextHandoff) throws {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine else {
            throw SessionKitError.persistenceFailed("Browser text importer is unavailable.")
        }
        let item = try engine.importBrowserTextInBackground(Self.sanitizedBrowserTextHandoff(handoff))
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundBrowserTextImport"] = item.id
        markOnboardingSteps(onboardingSteps(for: handoff))
    }

    private func onboardingSteps(for handoff: BrowserTextHandoff) -> Set<OnboardingStep> {
        switch handoff.captureMode {
        case .markdownFile, .plainTextFile:
            return [.addedOwnSource, .addedFromFiles]
        case .selectedText, .readablePage:
            return [.addedOwnSource, .addedFromSafari]
        }
    }

    func configureQuickAccessFolder(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: quickAccessFolderBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "quickAccessFolderName")
            quickAccessFolderName = url.lastPathComponent
            refreshQuickAccessFolder()
            reportSuccess("Quick folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Quick folder setup failed")
        }
    }

    func refreshQuickAccessFolder() {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            quickAccessRefreshID = UUID()
            quickAccessRefreshTask?.cancel()
            quickAccessRefreshTask = nil
            isRefreshingQuickAccessFolder = false
            quickAccessRecentFiles = []
            return
        }
        let refreshID = UUID()
        quickAccessRefreshID = refreshID
        quickAccessRefreshTask?.cancel()
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        isRefreshingQuickAccessFolder = true
        quickAccessRefreshTask = Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                Self.scanQuickAccessFolder(folderURL)
            }.value
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
            guard let self, self.quickAccessRefreshID == refreshID else { return }
            self.quickAccessRefreshTask = nil
            self.isRefreshingQuickAccessFolder = false
            if let errorDescription = scan.errorDescription {
                self.quickAccessRecentFiles = []
                self.diagnostics["quickAccessError"] = errorDescription
                return
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            self.quickAccessRecentFiles = scan.files.map { entry in
                QuickAccessFile(
                    id: entry.id,
                    name: entry.name,
                    relativePath: entry.relativePath,
                    modifiedAtDescription: formatter.localizedString(for: entry.modifiedAt, relativeTo: Date())
                )
            }
            self.quickAccessFolderName = folderURL.lastPathComponent
            self.diagnostics["quickAccessFolder"] = folderURL.lastPathComponent
            self.diagnostics["quickAccessRecentFiles"] = "\(self.quickAccessRecentFiles.count)"
        }
    }

    private nonisolated static func scanQuickAccessFolder(_ folderURL: URL) -> QuickAccessFolderScan {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let supported = files.compactMap { url -> QuickAccessFileCandidate? in
                let ext = url.pathExtension.lowercased()
                guard ["md", "markdown", "txt", "pdf"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return QuickAccessFileCandidate(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    relativePath: url.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            return QuickAccessFolderScan(
                files: Array(supported.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(2)),
                errorDescription: nil
            )
        } catch {
            return QuickAccessFolderScan(files: [], errorDescription: String(describing: error))
        }
    }

    func importQuickAccessFile(_ file: QuickAccessFile) {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        let fileURL = folderURL.appending(path: file.relativePath)
        beginObsidianMarkdownImport(
            urls: [fileURL],
            securityScopedURLs: [folderURL],
            refreshQuickFolderWhenFinished: true
        )
    }

    @discardableResult
    func importBrowserText(_ handoff: BrowserTextHandoff) -> Bool {
        do {
            let store = try requireStore()
            let engine = try makeEngine(store: store)
            installEngine(engine)
            let shouldStart = handoff.requestedContinuation.startSession
            var importOnlyHandoff = Self.sanitizedBrowserTextHandoff(handoff)
            importOnlyHandoff.requestedContinuation.startSession = false
            snapshot = try engine.importBrowserText(importOnlyHandoff)
            guard let importedItemId = snapshot.itemId ?? handoff.itemId else {
                throw SessionKitError.persistenceFailed("browser_text_item_id")
            }
            activeItemId = importedItemId
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: importedItemId, store: store)
            scheduleTextAudioPrewarmIfNeeded(itemId: importedItemId)
            diagnostics["lastBrowserTextImport"] = importedItemId
            diagnostics["lastBrowserTextSource"] = handoff.source.url
            markOnboardingSteps(onboardingSteps(for: handoff))
            if shouldStart {
                startItem(id: importedItemId)
            } else {
                screen = .item
                reportConfirmation("Imported browser text from \(handoff.source.title).")
            }
            return true
        } catch {
            reportFailure(error, context: "Browser text import failed")
            return false
        }
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
    }

    func importKokoroAssets(urls: [URL]) {
        guard !urls.isEmpty else {
            reportFailure("No Kokoro asset files were selected.")
            return
        }

        do {
            let assetsDirectory = try kokoroAssetsDirectory()
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

            var copiedModel = false
            var copiedVoices = false
            var ignored: [String] = []

            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let lowercasedName = url.lastPathComponent.lowercased()
                let destinationName: String?
                if lowercasedName == "kokoro-v1_0.safetensors" || url.pathExtension.lowercased() == "safetensors" {
                    destinationName = "kokoro-v1_0.safetensors"
                } else if lowercasedName == "voices.npz" || url.pathExtension.lowercased() == "npz" {
                    destinationName = "voices.npz"
                } else {
                    destinationName = nil
                }

                guard let destinationName else {
                    ignored.append(url.lastPathComponent)
                    continue
                }

                let destinationURL = assetsDirectory.appending(path: destinationName)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                copiedModel = copiedModel || destinationName == "kokoro-v1_0.safetensors"
                copiedVoices = copiedVoices || destinationName == "voices.npz"
            }

            refreshKokoroAssetStatus()
            let ignoredSuffix = ignored.isEmpty ? "" : " Ignored: \(ignored.joined(separator: ", "))."
            if copiedModel || copiedVoices {
                reportConfirmation("Imported Kokoro asset\(copiedModel && copiedVoices ? "s" : "").\(ignoredSuffix)")
            } else {
                reportFailure("No Kokoro assets were imported. Select kokoro-v1_0.safetensors and voices.npz.\(ignoredSuffix)")
            }
        } catch {
            reportFailure(error, context: "Kokoro asset import failed")
        }
    }

    func importPiperVoiceAssets(urls: [URL]) {
        guard !urls.isEmpty else {
            reportFailure("No Piper voice files were selected.")
            return
        }

        do {
            let assetsDirectory = try piperAssetsDirectory()
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

            var copied: [String] = []
            var ignored: [String] = []

            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard isSupportedPiperVoiceAsset(url) else {
                    ignored.append(url.lastPathComponent)
                    continue
                }

                let destinationURL = assetsDirectory.appending(path: url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                copied.append(url.lastPathComponent)
            }

            refreshPiperVoiceStatus()
            let ignoredSuffix = ignored.isEmpty ? "" : " Ignored: \(ignored.joined(separator: ", "))."
            if copied.isEmpty {
                reportFailure("No Piper assets were imported. Select a .onnx voice model and its .onnx.json config.\(ignoredSuffix)")
            } else {
                reportConfirmation("Imported Piper asset\(copied.count == 1 ? "" : "s").\(ignoredSuffix)")
            }
        } catch {
            reportFailure(error, context: "Piper voice import failed")
        }
    }

    func start() {
        guard !requireTermsDecisionBeforePlayback(.startCurrentItem) else { return }
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
        preparePodcastPlayback(itemId: activeItemId)
        beginTextPlaybackStartupBackgroundTaskIfNeeded(itemId: activeItemId)
        run { engine in
            let started = try engine.startSession(itemId: activeItemId)
            snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
            if let store, let sessionId = snapshot.sessionId {
                try seedUITestingSummaryInterjectionIfNeeded(sessionId: sessionId, engine: engine, store: store)
                try seedUITestingGeneratedTimelineIfNeeded(sessionId: sessionId, engine: engine, store: store)
            }
            if let store {
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
                try refreshLibraryRows(store: store)
            }
            reflectTextAudioPrewarmStatusIfActive(itemId: activeItemId)
            screen = .playback
            reportSuccess("Started \(snapshot.title ?? "session").")
        }
        reconcileTextPlaybackStartupBackgroundTask()
    }

    private func beginTextPlaybackStartupBackgroundTaskIfNeeded(itemId: String) {
        #if canImport(UIKit) && os(iOS)
        guard textPlaybackStartupBackgroundTask == .invalid,
              ttsVoiceSelection.supertonicVoice != nil,
              let item = try? store?.loadItem(id: itemId),
              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        textPlaybackStartupBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Start native text audio"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.diagnostics["textAudioBackgroundStartup"] = "expired"
                self?.endTextPlaybackStartupBackgroundTask()
            }
        }
        diagnostics["textAudioBackgroundStartup"] = textPlaybackStartupBackgroundTask == .invalid
            ? "unavailable"
            : "protected"
        #endif
    }

    private func reconcileTextPlaybackStartupBackgroundTask() {
        guard snapshot.status != .starting else { return }
        endTextPlaybackStartupBackgroundTask()
    }

    private func endTextPlaybackStartupBackgroundTask() {
        #if canImport(UIKit) && os(iOS)
        guard textPlaybackStartupBackgroundTask != .invalid else { return }
        let identifier = textPlaybackStartupBackgroundTask
        textPlaybackStartupBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        if diagnostics["textAudioBackgroundStartup"] != "expired" {
            diagnostics["textAudioBackgroundStartup"] = "completed"
        }
        #endif
    }

    func playPause() {
        if snapshot.status.isPlaybackActive {
            pause()
        } else if hasActiveSession {
            resumePlayback()
        } else {
            start()
        }
    }

    func pause() {
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.pause()
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Paused.")
        }
    }

    func stopOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else {
            reportFailure("On-device voice generation is not active for this item.")
            return
        }
        do {
            guard try client.stopOnDeviceRenderingAndUseSystemSpeech() else {
                reportFailure("There is no active native-text generation to stop.")
                return
            }
            onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.stopped.rawValue
            diagnostics["onDeviceSpeechGeneration"] = "stopped_by_user"
            reportConfirmation("Stopped on-device voice generation. Playback is continuing with the iOS system voice.")
        } catch {
            reportFailure(error, context: "Stop on-device voice generation failed")
        }
    }

    func resumePlayback() {
        guard let sessionId = snapshot.sessionId else {
            reportFailure("There is no listening session to resume.")
            return
        }
        guard !requireTermsDecisionBeforePlayback(.resumeSession(sessionId)) else { return }
        stopSpeechPreviews()
        streamingSpeechQueue.relinquishToCanonicalPlayback()
        run { engine in
            snapshot = try engine.resumePlayback()
            refreshSelectedItem()
            reportSuccess("Resumed.")
        }
    }

    func generateListeningMap() {
        guard !isGeneratingListeningMap else { return }
        guard selectedItem.chapters.isEmpty, selectedItem.mediaChapters.isEmpty else {
            reportSuccess("This item already has a Listening Map.")
            return
        }
        isGeneratingListeningMap = true
        let selectedItemRecord = try? store?.loadItem(id: activeItemId)
        if !remoteProviderExperienceEnabled {
            guard selectedItemRecord?.media == nil else {
                diagnostics["lastListeningMapMode"] = "on_device_generation_disabled"
                isGeneratingListeningMap = false
                reportFailure("Publisher chapters appear when available. AI-generated podcast maps are reserved for a future server-hosted option.")
                return
            }
            generateLocalListeningMap()
            isGeneratingListeningMap = false
            return
        }
        if let item = selectedItemRecord,
           item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            item.media?.url != nil {
            if sourceTranscriptStatus == "transcribing" || sourceTranscriptStatus == "queued" || sourceTranscriptStatus == "downloading" {
                pendingMapGenerationItemId = item.id
                isGeneratingListeningMap = false
                reportSuccess("Preparing the podcast transcript. Listening Map generation will continue when it is ready.")
                return
            }
            pendingMapGenerationItemId = item.id
            isGeneratingListeningMap = false
            scheduleFullSourceTranscriptionForListeningMap(for: item)
            reportSuccess("Preparing the podcast transcript for its Listening Map. Playback remains available.")
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            run { engine in
                snapshot = try engine.generateListeningMap(itemId: activeItemId)
                if let store {
                    libraryItems = try loadLibraryRows(store: store)
                }
                refreshSelectedItem()
                diagnostics["lastGeneratedMapItem"] = activeItemId
                diagnostics["lastListeningMapMode"] = "local_deterministic"
                scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
                reportConfirmation("Generated local Listening Map.")
            }
            isGeneratingListeningMap = false
            return
        }

        guard aiDataSharingConsent == .grantedV1 else {
            pendingMapGenerationAfterConsent = true
            isGeneratingListeningMap = false
            isAIDataSharingConsentPresented = true
            reportSuccess("Review how live AI uses this source before continuing.")
            return
        }

        statusMessage = "Calling \(modelForAIJob(kind: "listening_map")) for Listening Map."
        lastError = nil
        Task {
            await generateProviderListeningMap()
        }
    }

    private func generateProviderListeningMap() async {
        defer { isGeneratingListeningMap = false }
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.itemHasNoText
            }
            let model = modelForAIJob(kind: "listening_map")
            diagnostics["lastListeningMapModel"] = model
            let firstPrompt = listeningMapPrompt(sourceText: text)
            let firstResponse = try await callProvider(messages: [firstPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
            do {
                try saveProviderListeningMapResponse(firstResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "0"
                reportConfirmation("Generated Listening Map with \(model).")
            } catch {
                let repairPrompt = listeningMapRepairPrompt(sourceText: text, invalidResponse: firstResponse, error: String(describing: error))
                let repairedResponse = try await callProvider(messages: [repairPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
                try saveProviderListeningMapResponse(repairedResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "1"
                diagnostics["lastListeningMapInitialError"] = String(describing: error)
                reportConfirmation("Generated repaired Listening Map with \(model).")
            }
        } catch {
            reportFailure(error, context: "Listening Map generation failed")
        }
    }

    private func saveProviderListeningMapResponse(_ response: String, item: inout Item, store: SQLiteSessionStore) throws {
        let map = try parseListeningMapJSON(response, item: item)
        if let engine {
            snapshot = try engine.attachListeningMap(map)
        } else {
            try store.saveListeningMap(map)
        }
        item.status = "ready"
        try store.saveItem(item)
        libraryItems = try loadLibraryRows(store: store)
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics["lastGeneratedMapItem"] = item.id
        diagnostics["lastListeningMapMode"] = "provider"
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
    }

    private func generateLocalListeningMap() {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            diagnostics["lastListeningMapMode"] = "local_deterministic"
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportConfirmation("Generated Listening Map.")
        }
    }

    func applyListeningMapJSON() {
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            let map = try parseListeningMapJSON(listeningMapJSON, item: item)
            if let engine {
                snapshot = try engine.attachListeningMap(map)
            } else {
                try store.saveListeningMap(map)
            }
            item.status = "ready"
            try store.saveItem(item)
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: activeItemId, store: store)
            diagnostics["lastAppliedMap"] = map.id
            diagnostics["lastAppliedMapChapters"] = "\(map.chapters.count)"
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportSuccess("Applied Listening Map.")
        } catch {
            reportFailure(error, context: "Listening Map validation failed")
        }
    }

    func jumpToChapter(_ chapter: Chapter, fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.jumpToChapter(chapter.id, fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try engine.jumpToChapter(chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    func playSourceFromBeginning(fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.playSourceFromBeginning(fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            let startedSelectedItem = try ensureSessionForSelectedItem(engine)
            if !startedSelectedItem {
                snapshot = try engine.playSourceFromBeginning()
            }
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Playing source from the beginning.")
        }
    }

    /// Item Detail can be opened while another item remains in the mini player. Chapter
    /// actions belong to the item being viewed, not merely to whichever session happens
    /// to be restored in the engine.
    @discardableResult
    private func ensureSessionForSelectedItem(_ engine: SessionEngine) throws -> Bool {
        guard engine.currentSession?.itemId != activeItemId else { return false }
        if engine.currentSession != nil {
            snapshot = try engine.endSession()
        }
        let started = try engine.startSession(itemId: activeItemId)
        snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
        return true
    }

    func openHome() {
        syncPlaybackProgressForLifecycle()
        if let store {
            do {
                try refreshLibraryRows(store: store)
            } catch {
                diagnostics["homeLibraryRefreshError"] = String(describing: error)
            }
        }
        screen = .home
    }

    func openSettings() {
        screen = .settings
    }

    func openHelp() {
        isHelpPresented = true
    }

    func openAISettingsFromSummaryPrompt() {
        isAISetupNeededPresented = false
        screen = .settings
    }

    func openPlayback() {
        guard hasActiveSession else { return }
        if let itemId = snapshot.itemId, let store {
            activeItemId = itemId
            if let detail = try? loadItemDetail(id: itemId, store: store) {
                selectedItem = detail
            }
        }
        screen = .playback
    }

    func openExport() {
        openExport(sessionId: nil)
    }

    func openExport(sessionId: String?) {
        exportSessionId = sessionId
            ?? snapshot.sessionId
            ?? selectedItem.sessions.first?.id
        screen = .export
        refreshExportPreview(reportStatus: false)
    }

    func openBatchExport() {
        syncPlaybackProgressForLifecycle()
        exportSessionId = nil
        exportPreview = ""
        batchExportFilter = .withInterjections
        selectedBatchExportSessionIds = []
        batchExportResult = nil
        do {
            let store = try requireStore()
            try refreshBatchExportRows(store: store)
            screen = .batchExport
        } catch {
            reportFailure(error, context: "Session export setup failed")
        }
    }

    var visibleBatchExportRows: [BatchSessionExportRow] {
        switch batchExportFilter {
        case .withInterjections:
            batchExportRows.filter { $0.interjectionCount > 0 }
        case .all:
            batchExportRows
        }
    }

    var hasBatchExportFolder: Bool {
        UserDefaults.standard.data(forKey: batchExportFolderBookmarkKey) != nil
    }

    func toggleBatchExportSelection(sessionId: String) {
        if selectedBatchExportSessionIds.contains(sessionId) {
            selectedBatchExportSessionIds.remove(sessionId)
        } else {
            selectedBatchExportSessionIds.insert(sessionId)
        }
        batchExportResult = nil
    }

    func selectAllVisibleBatchExportSessions() {
        selectedBatchExportSessionIds.formUnion(visibleBatchExportRows.map(\.id))
        batchExportResult = nil
    }

    func clearBatchExportSelection() {
        selectedBatchExportSessionIds = []
        batchExportResult = nil
    }

    func openItem(id: String) {
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            scheduleTextAudioPrewarmIfNeeded(itemId: id)
            listeningMapJSON = ""
            screen = .item
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    func startItem(id: String) {
        do {
            let store = try requireStore()
            if let continuation = Self.preferredContinuationSession(in: try store.loadSessions(itemId: id)) {
                resumeSession(continuation)
            } else {
                startNewSession(id: id)
            }
        } catch {
            reportFailure(error, context: "Continue listening failed")
        }
    }

    func startNewSession(id: String) {
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if hasActiveSession, let engine {
            _ = try? engine.endSession()
            snapshot = engine.snapshot
        }
        activeItemId = id
        start()
    }

    func playLiveSpeechInstead() {
        guard canPlayLiveSpeechInstead else { return }
        liveSpeechFallbackItemIds.insert(activeItemId)
        pendingPreparedTextStartItemId = nil
        preparedTextAudioStatus = "live_fallback"
        snapshot.preparedTextAudioStatus = "live_fallback"
        diagnostics["textAudioFallback:\(activeItemId)"] = "explicit_user_action"
        start()
    }

    func openSession(_ session: Session) {
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            let inspected = try engine.inspectSession(sessionId: session.id)
            snapshot = try applyPreferredPlaybackRate(to: inspected, engine: engine)
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            try refreshLibraryRows(store: store)
            screen = .playback
            reportSuccess("Opened session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Open session failed")
        }
    }

    func resumeSession(_ session: Session) {
        guard !requireTermsDecisionBeforePlayback(.resumeSession(session.id)) else { return }
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            _ = try engine.inspectSession(sessionId: session.id)
            do {
                if session.completionPercent >= 100 {
                    let inspected = try engine.inspectSession(sessionId: session.id)
                    snapshot = try applyPreferredPlaybackRate(to: inspected, engine: engine)
                } else {
                    let resumed = try engine.resumePlayback()
                    snapshot = try applyPreferredPlaybackRate(to: resumed, engine: engine)
                }
            } catch SessionKitError.invalidCommandForState("playback_text_empty") {
                snapshot = try engine.playSourceFromBeginning()
            }
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            try refreshLibraryRows(store: store)
            screen = .playback
            reportSuccess(session.completionPercent >= 100
                ? "Opened completed session. Use Play from Beginning to restart."
                : "Resumed session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Resume session failed")
        }
    }

    func deleteItem(id: String) {
        moveItemToTrash(id: id)
    }

    func moveItemToTrash(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if snapshot.itemId == id {
                _ = try? engine?.stopPlayback()
            }
            try store.moveItemToTrash(id: id)
            try refreshLibraryRows(store: store)
            if activeItemId == id {
                activeItemId = libraryItems.first?.id ?? "item-pill"
                snapshot = SessionSnapshot()
                exportPreview = ""
                selectedItem = libraryItems.first.map { (try? loadItemDetail(id: $0.id, store: store)) ?? ItemDetailState() } ?? ItemDetailState()
            }
            screen = .home
            presentTrashUndo(itemId: id, title: item.title)
            reportSuccess("Moved \(item.title) to Recently Deleted.")
        } catch {
            reportFailure(error, context: "Move to Recently Deleted failed")
        }
    }

    func undoLastTrash() {
        guard let trashUndo else { return }
        restoreItem(id: trashUndo.itemId)
    }

    func dismissTrashUndo() {
        dismissTrashUndo(id: nil)
    }

    private func presentTrashUndo(itemId: String, title: String) {
        trashUndoDismissTask?.cancel()
        let undo = TrashUndoState(itemId: itemId, title: title)
        trashUndo = undo
        trashUndoDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: trashUndoDismissDelay)
                dismissTrashUndo(id: undo.id)
            } catch {
                // Manual dismissal, Undo, replacement, and teardown cancel this timer.
            }
        }
    }

    private func dismissTrashUndo(id: UUID?) {
        guard id == nil || trashUndo?.id == id else { return }
        trashUndoDismissTask?.cancel()
        trashUndoDismissTask = nil
        trashUndo = nil
    }

    func dismissError() {
        lastError = nil
        if feedbackEvent?.kind == .error {
            feedbackEvent = nil
        }
        if statusMessage == "Error" {
            statusMessage = "Ready."
        }
    }

    func dismissFeedback(id: UUID? = nil) {
        guard id == nil || feedbackEvent?.id == id else { return }
        feedbackEvent = nil
    }

    func dismissLegacyLibraryResetNotice() {
        legacyLibraryResetNotice = nil
    }

    func restoreItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            try store.restoreItem(id: id)
            try refreshLibraryRows(store: store)
            dismissTrashUndo()
            reportSuccess("Restored \(item.title).")
        } catch {
            reportFailure(error, context: "Restore failed")
        }
    }

    func permanentlyDeleteItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            guard item.deletedAt != nil else {
                reportFailure("Move the item to Recently Deleted before deleting it permanently.")
                return
            }
            podcastDownloadCoordinator?.removeItem(id)
            try store.deleteItem(id: id)
            try refreshLibraryRows(store: store)
            guard !libraryItems.contains(where: { $0.id == id }),
                  !recentlyDeletedItems.contains(where: { $0.id == id }),
                  (try? store.loadItem(id: id)) == nil,
                  (try? store.loadSessions(itemId: id))?.isEmpty != false else {
                throw SessionKitError.persistenceFailed("permanent_delete_verification_failed")
            }
            if trashUndo?.itemId == id {
                dismissTrashUndo()
            }
            reportSuccess("Permanently deleted \(item.title).")
        } catch {
            reportFailure(error, context: "Permanent delete failed")
        }
    }

    func permanentlyDeleteRecentlyDeletedItems() {
        do {
            let store = try requireStore()
            let ids = recentlyDeletedItems.map(\.id)
            guard !ids.isEmpty else {
                reportSuccess("Recently Deleted is already empty.")
                return
            }
            for id in ids {
                guard try store.loadItem(id: id).deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            ids.forEach { podcastDownloadCoordinator?.removeItem($0) }
            try store.deleteItems(ids: ids)
            try refreshLibraryRows(store: store)
            guard recentlyDeletedItems.isEmpty,
                  ids.allSatisfy({ (try? store.loadItem(id: $0)) == nil }) else {
                throw SessionKitError.persistenceFailed("bulk_permanent_delete_verification_failed")
            }
            if let undoItemId = trashUndo?.itemId, ids.contains(undoItemId) {
                dismissTrashUndo()
            }
            reportSuccess("Permanently deleted \(ids.count) item\(ids.count == 1 ? "" : "s") from Recently Deleted.")
        } catch {
            reportFailure(error, context: "Empty Recently Deleted failed")
        }
    }

    func skipBack() {
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.skipBack(unit: skipUnitForCurrentTarget())
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipBackMedia() {
        run { engine in
            snapshot = try engine.skipBack(unit: mediaSkipUnit(seconds: mediaSkipBackSeconds))
            refreshSelectedItem()
        }
    }

    func skipForward() {
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            let unit = skipUnitForCurrentTarget()
            if ttsMode == "kokoro" {
                snapshot = try engine.skipForward(unit: unit, minimumDistance: kokoroSkipForwardMinimumDistance)
            } else {
                snapshot = try engine.skipForward(unit: unit)
            }
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped forward.")
        }
    }

    func skipForwardMedia() {
        run { engine in
            snapshot = try engine.skipForward(unit: mediaSkipUnit(seconds: mediaSkipForwardSeconds))
            refreshSelectedItem()
        }
    }

    func mediaSkipSettingsChanged() {
        mediaSkipBackSeconds = Self.validatedMediaSkipSeconds(mediaSkipBackSeconds)
        mediaSkipForwardSeconds = Self.validatedMediaSkipSeconds(mediaSkipForwardSeconds)
        UserDefaults.standard.set(mediaSkipBackSeconds, forKey: "mediaSkipBackSeconds")
        UserDefaults.standard.set(mediaSkipForwardSeconds, forKey: "mediaSkipForwardSeconds")
        mediaPlaybackClient?.setPreferredSkipIntervals(
            backSeconds: mediaSkipBackSeconds,
            forwardSeconds: mediaSkipForwardSeconds
        )
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
    }

    func setMediaPlaybackRate(_ rate: Double) {
        let clamped = max(0.75, min(2.0, rate))
        mediaPlaybackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "mediaPlaybackRate")
        run { engine in
            snapshot = try engine.setPlaybackRate(clamped)
            refreshSelectedItem()
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
        }
    }

    func seekMedia(toMediaTimeMs mediaTimeMs: Int) {
        run { engine in
            snapshot = try engine.seekMedia(toMediaTimeMs: mediaTimeMs)
            refreshSelectedItem()
        }
    }

    func seekText(toCharOffset charOffset: Int) {
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.seekText(toCharOffset: charOffset)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
        }
    }

    func playbackSpeechRateChanged() {
        saveSpeechSettings()
        guard !isMediaPlaybackSnapshot else {
            return
        }
        if ttsVoiceSelection.supertonicVoice != nil, audioPlaybackClientOverride == nil {
            applySupertonicPlaybackRate()
            return
        }
        run { engine in
            snapshot = try engine.updateSpeechPlaybackSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            refreshSelectedItem()
            diagnostics["speechRateApplied"] = String(format: "%.2f", speechRate)
        }
    }

    private func applySupertonicPlaybackRate() {
        let transportRate = max(0.7, min(2.0, speechRate / 0.5))
        do {
            try speechPlaybackClient?.configureSpeechSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            if let engine, hasActiveSession {
                snapshot = try engine.setPlaybackRate(transportRate)
                refreshSelectedItem()
            }
            diagnostics["speechRateApplied"] = String(format: "%.2f", transportRate)
        } catch {
            reportFailure(error, context: "Speaking rate update failed")
        }
    }

    private func applyPreferredPlaybackRate(
        to started: SessionSnapshot,
        engine: SessionEngine
    ) throws -> SessionSnapshot {
        switch started.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return started.playbackRate == mediaPlaybackRate
                ? started
                : try engine.setPlaybackRate(mediaPlaybackRate)
        case TargetType.itemTextTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue where ttsVoiceSelection.supertonicVoice != nil:
            let transportRate = max(0.7, min(2.0, speechRate / 0.5))
            return started.playbackRate == transportRate
                ? started
                : try engine.setPlaybackRate(transportRate)
        default:
            return started
        }
    }

    func podcastCacheLimitChanged() {
        guard let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) else {
            podcastCacheLimitGB = PodcastCacheLimitGB.defaultValue.rawValue
            return
        }
        UserDefaults.standard.set(limit.rawValue, forKey: "podcastCacheLimitGB")
        podcastDownloadCoordinator?.setCacheLimit(limit)
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
        reportSuccess("Podcast cache limit set to \(limit.rawValue) GB.")
    }

    func renderedSpeechCacheLimitChanged() {
        guard Self.supportedRenderedSpeechCacheLimitsMB.contains(renderedSpeechCacheLimitMB) else {
            renderedSpeechCacheLimitMB = 256
            return
        }
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        renderedSpeechDiskCache?.setLimitBytes(renderedSpeechCacheLimitMB * 1024 * 1024)
        diagnostics["renderedSpeechCacheLimitMB"] = "\(renderedSpeechCacheLimitMB)"
        reportSuccess("Rendered speech cache limit set to \(renderedSpeechCacheLimitMB) MB.")
    }

    func retrySelectedPodcastDownload() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download retry is unavailable.")
            return
        }
        podcastDownloadCoordinator?.retry(itemId: selectedItem.id)
        reportSuccess("Retrying podcast download.")
    }

    func clearPodcastDownloads() {
        podcastDownloadCoordinator?.clearDownloads()
        reportConfirmation("Cleared downloaded podcast audio. Remote sources remain available.")
    }

    private func skipUnitForCurrentTarget() -> String {
        switch snapshot.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return skipUnit
        }
    }

    private func mediaSkipUnit(seconds: Int) -> String {
        "time_\(Self.validatedMediaSkipSeconds(seconds))s"
    }

    private static func validatedMediaSkipSeconds(_ seconds: Int) -> Int {
        supportedMediaSkipSeconds.contains(seconds) ? seconds : 15
    }

    func beginInterjection() {
        statusMessage = "Starting interjection..."
        lastError = nil
        diagnostics["lastInterjectionTap"] = "begin"
        let requestedAt = Date()
        #if canImport(AVFoundation) && os(iOS)
        let recordPermissionIsGranted: Bool
        if #available(iOS 17.0, *) {
            recordPermissionIsGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            recordPermissionIsGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        }
        if recordPermissionIsGranted {
            diagnostics["lastMicrophonePermissionResult"] = "granted"
            startInterjectionRecording(requestedAt: requestedAt)
            return
        }
        #endif
        Task {
            let granted = await requestMicrophonePermission()
            guard granted else {
                reportFailure("Microphone access is required to record interjections. Enable microphone access in Settings and try again.")
                return
            }
            startInterjectionRecording(requestedAt: requestedAt)
        }
    }

    private func startInterjectionRecording(requestedAt: Date) {
        synchronizeStreamingSpeechAnchorIfNeeded()
        streamingSpeechQueue.pauseForInterjection()
        run { engine in
            snapshot = try engine.beginInterjection()
            refreshSelectedItem()
            if snapshot.isRecording {
                let latencyMs = max(0, Int(Date().timeIntervalSince(requestedAt) * 1000))
                diagnostics["lastInterjectionRecordingStartLatencyMs"] = "\(latencyMs)"
                reportSuccess("Recording interjection.")
            }
        }
    }

    private func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await SystemRecordingClient.requestRecordPermission()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let granted = await group.next() ?? false
            group.cancelAll()
            diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied_or_timeout"
            return granted
        }
    }

    func finishInterjection() {
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            if let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            reportConfirmation("Interjection saved. Transcription is continuing in the background.")
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    private func recordSavedInterjectionForOnboarding() {
        markOnboardingSteps([.firstInterjection])
        if guidedOnboardingStage == .practiceInterjection {
            setGuidedOnboardingStage(.reviewTimeline)
        }
    }

    func cancelInterjection() {
        run { engine in
            snapshot = try engine.cancelInterjection()
            refreshSelectedItem()
            reportSuccess("Cancelled interjection.")
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func endSession() {
        closeCurrentSession(navigateHome: true)
    }

    func dismissMiniPlayer() {
        closeCurrentSession(navigateHome: false)
    }

    private func closeCurrentSession(
        navigateHome: Bool,
        successMessage: String = "Session saved. You can resume it later."
    ) {
        let closedItemId = snapshot.itemId ?? activeItemId
        run { engine in
            snapshot = try engine.endSession()
            activeItemId = closedItemId
            refreshSelectedItem()
            if let store {
                try refreshLibraryRows(store: store)
            }
            reportConfirmation(successMessage)
        }
        streamingSpeechQueue.stopAndClear()
        gate2CompactControls.endLiveActivities()
        if let renderer = supertonicRenderer {
            Task { await renderer.unload() }
        }
        if navigateHome {
            screen = .home
        }
    }

    #if SPOKEN_MARGINS_WATCH
    func renderSelectedItemForWatchPackage() {
        renderWatchPackage(itemId: selectedItem.id, transferAfterRender: false)
    }
    #endif

    func summarize() {
        if !remoteProviderExperienceEnabled {
            guard localFoundationModelAvailable else {
                diagnostics["summaryPreflight"] = "local_model_unavailable"
                reportFailure(localFoundationModelAvailabilityDescription)
                return
            }
            guard pendingSourceContextInterjectionIds.isEmpty else {
                reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
                return
            }
            guard canSummarizeInterjections else {
                reportFailure("An interjection summary already exists for this session.")
                return
            }
            syncPlaybackProgressForLifecycle()
            run { engine in
                snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
                let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
                let contexts = localSummaryContexts(interjections: engine.lastSummaryCandidates)
                submitLocalSummary(turnId: turnId, contexts: contexts)
                refreshSelectedItem()
                reportSuccess("On-device summary started.")
            }
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isAISetupNeededPresented = true
            diagnostics["summaryPreflight"] = "api_key_missing"
            return
        }
        guard pendingSourceContextInterjectionIds.isEmpty else {
            reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
            return
        }
        guard canSummarizeInterjections else {
            reportFailure("An interjection summary already exists for this session.")
            return
        }
        syncPlaybackProgressForLifecycle()
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
            let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
            submitProviderJobIfNeeded(kind: "interjection_summary", turnId: turnId, messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
            refreshSelectedItem()
            reportConfirmation(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
        }
    }

    func discuss(followUp: String) {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Discuss is disabled in this release. Copy your notes to another chatbot and paste its response back here instead.")
            return
        }
        guard pendingSourceContextInterjectionIds.isEmpty else {
            reportFailure("Source context is still being prepared. Try again when the podcast context is ready.")
            return
        }
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentInterjections = currentDiscussionInterjections()
        let request = Gate1DiscussionContext.primaryRequest(explicitFollowUp: trimmed, currentInterjections: currentInterjections)
        submitDiscussionFollowUp(request, explicitFollowUp: trimmed, primaryInterjections: currentInterjections)
    }

    func playTurn(_ turn: ConversationTurn, fromTimeline: Bool = false) {
        stopSpeechPreviews()
        run { engine in
            try playTurn(turn.id, engine: engine)
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Playing \(turnTitleText(turn)).")
        }
    }

    func jumpToTurnChapter(turn: ConversationTurn, chapter: Chapter, fromTimeline: Bool = false) {
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            snapshot = try engine.jumpToTurnChapter(turnId: turn.id, chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    private func playTurn(_ turnId: String, engine: SessionEngine) throws {
        try playTurn(turnId, engine: engine, clearsPendingQueue: true)
    }

    private func playTurn(_ turnId: String, engine: SessionEngine, clearsPendingQueue: Bool) throws {
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if clearsPendingQueue {
            clearPendingAutoPlayTurns()
        }
        snapshot = try engine.playTurn(turnId: turnId)
        refreshSelectedItem()
        screen = .playback
    }

    private func autoPlayCompletedTurn(
        kind: String,
        turnId: String,
        engine: SessionEngine,
        completedCurrentAudio: Bool = false
    ) throws {
        guard kind == "interjection_summary" || kind == "assistant_response" else { return }
        if shouldDeferGeneratedTurnPlayback(turnId: turnId, completedCurrentAudio: completedCurrentAudio) {
            enqueuePendingAutoPlayTurn(turnId)
            return
        }
        try playTurn(turnId, engine: engine)
    }

    @discardableResult
    private func playPendingTurnIfReady(completedCurrentAudio: Bool = false) -> Bool {
        guard let engine,
              let turnId = pendingAutoPlayQueue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: completedCurrentAudio) else {
            return false
        }
        do {
            updatePendingAutoPlayDiagnostics(reason: "draining_queue")
            try playTurn(turnId, engine: engine, clearsPendingQueue: false)
            reportSuccess("Playing generated response.")
            return true
        } catch {
            reportFailure(error, context: "Auto-play generated response failed")
            return false
        }
    }

    private func closeCompletedSessionIfReady() {
        guard snapshot.sourceProgressPercent >= 100,
              snapshot.currentPlaybackProgressPercent >= 100,
              pendingAutoPlayQueue.count == 0,
              !selectedItem.turns.contains(where: { $0.status == "pending" || $0.status == "streaming" }) else {
            return
        }
        closeCurrentSession(
            navigateHome: true,
            successMessage: "Session complete and saved."
        )
    }

    private func shouldDeferGeneratedTurnPlayback(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: turnId,
            completedCurrentAudio: completedCurrentAudio
        )
    }

    private func shouldPlayPendingTurnNow(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldPlayPendingTurnNow(snapshot: snapshot, turnId: turnId, completedCurrentAudio: completedCurrentAudio)
    }

    private func enqueuePendingAutoPlayTurn(_ turnId: String) {
        pendingAutoPlayQueue.enqueue(turnId)
        updatePendingAutoPlayDiagnostics(reason: "waiting_for_current_audio")
    }

    private func clearPendingAutoPlayTurns() {
        pendingAutoPlayQueue.clear()
        diagnostics["pendingAutoPlayTurnId"] = nil
        diagnostics["pendingAutoPlayQueue"] = "0"
        diagnostics["pendingAutoPlayReason"] = nil
    }

    private func updatePendingAutoPlayDiagnostics(reason: String) {
        diagnostics["pendingAutoPlayTurnId"] = pendingAutoPlayQueue.first
        diagnostics["pendingAutoPlayQueue"] = "\(pendingAutoPlayQueue.count)"
        diagnostics["pendingAutoPlayReason"] = reason
    }

    private func latestPendingJob(kind: String) -> AIJob? {
        guard let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else {
            return nil
        }
        return jobs.last {
            $0.kind == kind && ($0.status == "pending" || $0.status == "deferred")
        }
    }

    func followUp(_ text: String) {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Remote discussion is disabled in this release.")
            return
        }
        submitDiscussionFollowUp(text, explicitFollowUp: text, primaryInterjections: currentDiscussionInterjections())
    }

    private func submitDiscussionFollowUp(_ text: String, explicitFollowUp: String, primaryInterjections: [Interjection]) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
            let turnId = latestPendingJob(kind: "assistant_response")?.turnId ?? "turn-response-001"
            submitProviderJobIfNeeded(
                kind: "assistant_response",
                turnId: turnId,
                messages: [conversationPrompt(
                    followUp: text,
                    explicitFollowUp: explicitFollowUp,
                    primaryInterjections: primaryInterjections
                )]
            )
            refreshSelectedItem()
            reportConfirmation(snapshot.pendingAiJobStatus == "deferred" ? "Follow-up queued for later." : "Follow-up submitted.")
        }
    }

    func retryPendingAI() {
        guard remoteProviderExperienceEnabled else {
            summarize()
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isAISetupNeededPresented = true
            diagnostics["aiRetryPreflight"] = "api_key_missing"
            return
        }
        run { engine in
            guard let sessionId = snapshot.sessionId,
                  let job = try store?.loadAIJobs(sessionId: sessionId)
                    .last(where: { $0.status == "retryable" || $0.status == "pending" || $0.status == "deferred" }) else {
                reportFailure("No retryable AI job is available.")
                return
            }
            snapshot = try engine.retryAIJob(jobId: job.id)
            let turnId = job.turnId ?? (job.kind == "interjection_summary" ? "turn-summary-001" : "turn-response-001")
            let messages = job.messages.isEmpty ? [job.kind == "interjection_summary" ? summaryPrompt(interjections: engine.lastSummaryCandidates) : "Continue the discussion."] : job.messages
            submitProviderJobIfNeeded(kind: job.kind, turnId: turnId, messages: messages, force: true)
            refreshSelectedItem()
            reportConfirmation("Retrying \(job.kind).")
        }
    }

    func buildExport() {
        refreshExportPreview(reportStatus: true)
    }

    func exportOptionsChanged() {
        persistExportSettings()
        refreshExportPreview(reportStatus: false)
    }

    private func refreshExportPreview(reportStatus: Bool) {
        guard exportSessionId != nil else {
            exportPreview = ""
            exportFileURL = nil
            return
        }
        run { engine in
            let export = try engine.buildExport(options: currentExportOptions())
            exportPreview = try renderExport(export)
            exportFileURL = exportFormat == "markdown"
                ? try prepareIndividualMarkdownExportFile(markdown: exportPreview, export: export)
                : nil
            screen = .export
            if reportStatus {
                reportSuccess("Built session export.")
            }
        }
    }

    func copyPlainTextExport() {
        guard !exportPreview.isEmpty else {
            reportFailure("No export text is available yet.")
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = exportPreview
        recordSessionExported()
        reportConfirmation("Copied \(exportFormat == "json" ? "JSON" : "Markdown") export.")
        #else
        reportFailure("Clipboard is unavailable on this platform.")
        #endif
    }

    func configureBatchExportFolder(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(
                options: quickAccessBookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: batchExportFolderBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "batchExportFolderName")
            batchExportFolderName = url.lastPathComponent
            batchExportResult = nil
            reportSuccess("Export folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Export folder setup failed")
        }
    }

    func reportBatchExportFolderFailure(_ error: Error) {
        reportFailure(error, context: "Export folder selection failed")
    }

    func exportSelectedSessionsToFolder() {
        guard !selectedBatchExportSessionIds.isEmpty else {
            reportFailure("Choose at least one session to export.")
            return
        }
        guard let folderURL = resolvedBatchExportFolderURL() else {
            reportFailure("Choose an export folder first.")
            return
        }
        do {
            if engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let engine else {
                reportFailure("Session export is unavailable.")
                return
            }

            persistExportSettings()
            isWritingBatchExport = true
            defer { isWritingBatchExport = false }

            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            let writer = SessionMarkdownFileWriter()
            let selectedRows = batchExportRows.filter { selectedBatchExportSessionIds.contains($0.id) }
            var exportedFileNames: [String] = []
            var failures: [String] = []
            for row in selectedRows {
                do {
                    let export = try engine.buildExport(options: currentExportOptions(sessionId: row.id))
                    let markdown = SessionExportMarkdownRenderer.render(export)
                    let fileURL = try writer.write(
                        markdown: markdown,
                        itemTitle: row.itemTitle,
                        sessionDate: row.session.createdAt ?? row.session.updatedAt,
                        sessionId: row.id,
                        to: folderURL
                    )
                    exportedFileNames.append(fileURL.lastPathComponent)
                } catch {
                    failures.append("\(row.itemTitle): \(error.localizedDescription)")
                }
            }

            batchExportResult = BatchSessionExportResult(
                exportedFileNames: exportedFileNames,
                failures: failures,
                destinationName: folderURL.lastPathComponent
            )
            if !exportedFileNames.isEmpty {
                markOnboardingSteps([.exportedSession])
            }
            diagnostics["batchExportLastResult"] = "exported=\(exportedFileNames.count);failed=\(failures.count)"
            if failures.isEmpty {
                reportConfirmation("Exported \(exportedFileNames.count) Markdown file\(exportedFileNames.count == 1 ? "" : "s") to \(folderURL.lastPathComponent).")
            } else if exportedFileNames.isEmpty {
                reportFailure("No sessions were exported. Review the export result for details.")
            } else {
                reportFailure("Exported \(exportedFileNames.count) session\(exportedFileNames.count == 1 ? "" : "s"); \(failures.count) failed.")
            }
        } catch {
            isWritingBatchExport = false
            reportFailure(error, context: "Batch export failed")
        }
    }

    func copyTargetInterjections(targetType: String, targetId: String, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: snapshot.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                includeTurns: targetType != InterjectionTargetType.item.rawValue,
                scope: "target",
                targetType: targetType,
                targetId: targetId
            ))
            guard !export.interjections.isEmpty else {
                reportFailure("No interjections are available for that target.")
                return
            }
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied target interjections.")
            #else
            exportPreview = text
            reportSuccess("Built target interjection export.")
            #endif
        }
    }

    func copyInterjectionWithContext(_ interjection: Interjection, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: interjection.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                includeTurns: interjection.targetType != .item,
                scope: "selected_interjections",
                interjectionIds: [interjection.id]
            ))
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied interjection with its anchors.")
            #else
            exportPreview = text
            reportSuccess("Built interjection export.")
            #endif
        }
    }

    func retryAnchorContext(_ interjection: Interjection) {
        guard !pendingSourceContextInterjectionIds.contains(interjection.id) else { return }
        scheduleSourceWindowContextIfNeeded(for: interjection)
        reportConfirmation("Retrying source context.")
    }

    func retryInterjectionTranscription(_ interjection: Interjection) {
        guard interjection.audioPath != nil else {
            reportFailure("The saved interjection audio is unavailable.")
            return
        }
        guard retryingInterjectionTranscriptionIds.insert(interjection.id).inserted else { return }
        scheduleTranscription(for: interjection)
        reportConfirmation("Retranscribing the saved interjection audio.")
    }

    func toggleInterjectionAudioPlayback(_ interjection: Interjection) {
        #if canImport(AVFoundation)
        if playingInterjectionAudioId == interjection.id {
            stopInterjectionAudioPlayback()
            return
        }
        guard let audioPath = interjection.audioPath,
              let url = resolvedInterjectionAudioURL(for: audioPath),
              FileManager.default.fileExists(atPath: url.path) else {
            reportFailure("The saved interjection recording is unavailable.")
            return
        }
        if snapshot.status.isPlaybackActive {
            pause()
        }
        stopInterjectionAudioPlayback()
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            interjectionAudioPlayer = player
            playingInterjectionAudioId = interjection.id
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self?.stopInterjectionAudioPlayback()
                        return
                    }
                }
            }
            player.play()
        } catch {
            stopInterjectionAudioPlayback()
            reportFailure(error, context: "Interjection playback failed")
        }
        #else
        reportFailure("Interjection playback is unavailable on this device.")
        #endif
    }

    func stopInterjectionAudioPlayback() {
        #if canImport(AVFoundation)
        interjectionAudioPlayer?.pause()
        interjectionAudioPlayer?.replaceCurrentItem(with: nil)
        interjectionAudioPlayer = nil
        interjectionAudioCompletionTask?.cancel()
        interjectionAudioCompletionTask = nil
        #endif
        playingInterjectionAudioId = nil
    }

    func importPastedAssistantResponse(autoPlay: Bool = true) {
        let text = pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            reportFailure("Paste a response before importing.")
            return
        }
        stopSpeechPreviews()
        run { engine in
            if !hasActiveSession {
                let started = try engine.startSession(itemId: activeItemId)
                snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
            }
            snapshot = try engine.importAssistantResponse(text: text, autoPlay: autoPlay)
            pastedAssistantResponse = ""
            refreshSelectedItem()
            screen = .playback
            reportSuccess(autoPlay ? "Imported and playing pasted response." : "Imported pasted response.")
        }
    }

    func deleteTranscript(interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, representation: "transcript")
            refreshSelectedItem()
            reportSuccess("Deleted transcript.")
        }
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id)
            refreshSelectedItem()
            reportSuccess("Deleted interjection.")
        }
    }

    func refreshDiagnostics() {
        run { engine in
            diagnostics = try engine.diagnostics()
            diagnostics["providerProbe"] = providerProbeStatus
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
            settingsValueChanged()
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            refreshImportInbox()
            reportSuccess("Diagnostics refreshed.")
        }
    }

    func refreshImportInbox() {
        var entries: [ImportInboxEntry] = []
        do {
            for failed in try resolvedSourceLinkHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "source:\(failed.id)",
                    payloadID: failed.id,
                    kind: .sourceLink,
                    title: "Podcast or audio link",
                    source: failed.handoff.inputURL,
                    reason: failed.reason
                ))
            }
        } catch {
            diagnostics["sourceLinkImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        do {
            for failed in try resolvedBrowserTextHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "text:\(failed.id)",
                    payloadID: failed.id,
                    kind: .browserText,
                    title: failed.handoff.source.title,
                    source: failed.handoff.source.url,
                    reason: failed.reason
                ))
            }
        } catch {
            diagnostics["browserTextImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        importInbox = entries
    }

    func retryImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().retryFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().retryFailed(payloadID: entry.payloadID)
            }
            importPendingSourceLinkHandoffs()
            reportConfirmation("Import retry queued.")
        } catch {
            reportFailure(error, context: "Import retry failed")
        }
    }

    func deleteImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().deleteFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().deleteFailed(payloadID: entry.payloadID)
            }
            refreshImportInbox()
            reportSuccess("Removed failed import.")
        } catch {
            reportFailure(error, context: "Import removal failed")
        }
    }

    func copyDiagnosticsExport() {
        var safe = diagnostics
            .filter { !Self.diagnosticKeyMayContainUserContent($0.key) }
            .mapValues(Self.redactedDiagnosticValue)
        safe["schemaVersion"] = "spoken-margins.diagnostics.v1"
        safe["exportedAt"] = ISO8601DateFormatter().string(from: Date())
        safe["playbackStatus"] = snapshot.status.rawValue
        safe["sessionPhase"] = snapshot.phase.rawValue
        safe["targetType"] = snapshot.targetType ?? "none"
        safe["pendingAIJobs"] = "\(snapshot.pendingAiJobCount)"
        do {
            let data = try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else { return }
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied privacy-safe diagnostics.")
            #else
            exportPreview = text
            reportSuccess("Built privacy-safe diagnostics.")
            #endif
        } catch {
            reportFailure(error, context: "Diagnostics export failed")
        }
    }

    private static func redactedDiagnosticValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
            .replacingOccurrences(of: #"/(?:private|Users|var)/[^\s]+"#, with: "<redacted-path>", options: .regularExpression)
    }

    private static func diagnosticKeyMayContainUserContent(_ key: String) -> Bool {
        [
            "lastStatus",
            "recentFailure",
            "quickAccessFolder",
            "lastSourceLinkClipboardPaste",
            "lastBrowserTextSource"
        ].contains(key)
    }

    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        if command == .beginInterjection {
            if recordingClientOverride != nil {
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
                return
            }
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    reportFailure("Microphone access is required to record interjections from compact controls.")
                    return
                }
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url),
              let command = CompactControlCommand(rawValue: rawCommand) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        dispatchGate2CompactCommand(
            command,
            chapterId: Gate2CompactCommandURL.chapterId(from: url),
            origin: "compact_url"
        )
    }

    func importPendingSourceLinkHandoffs() {
        Task { @MainActor in
            await importPendingHandoffsAsync()
        }
    }

    private func importPendingHandoffsAsync() async {
        guard !isImportingPendingSourceLinkHandoffs else { return }
        isImportingPendingSourceLinkHandoffs = true
        defer {
            isImportingPendingSourceLinkHandoffs = false
            refreshImportInbox()
        }

        do {
            let handoffStore = try resolvedSourceLinkHandoffStore()
            let payloadIDs = try handoffStore.pendingPayloadIDs()
            diagnostics["pendingSourceLinkPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                do {
                    let handoff = try handoffStore.handoff(payloadID: payloadID)
                    try await importSourceLinkInBackground(handoff)
                    try handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "imported"
                } catch SourceLinkHandoffStoreError.invalidPayload {
                    try? handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch SourceLinkHandoffStoreError.missingPayload {
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "missing"
                } catch {
                    try? handoffStore.quarantine(payloadID: payloadID, reason: error.localizedDescription)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "quarantined:\(error.localizedDescription)"
                }
            }
        } catch {
            diagnostics["pendingSourceLinkImport"] = "unavailable:\(error.localizedDescription)"
        }

        do {
            let handoffStore = try resolvedBrowserTextHandoffStore()
            let payloadIDs = try handoffStore.pendingPayloadIDs()
            diagnostics["pendingBrowserTextPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                do {
                    let handoff = try handoffStore.handoff(payloadID: payloadID)
                    try importBrowserTextInBackground(handoff)
                    try handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "imported"
                } catch Gate5BrowserTextHandoffStoreError.invalidPayload {
                    try? handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch Gate5BrowserTextHandoffStoreError.missingPayload {
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "missing"
                } catch {
                    try? handoffStore.quarantine(payloadID: payloadID, reason: error.localizedDescription)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantined:\(error.localizedDescription)"
                }
            }
        } catch {
            diagnostics["pendingBrowserTextImport"] = "unavailable:\(error.localizedDescription)"
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.scheme == Gate5BrowserTextHandoffURL.scheme, url.host == "open" {
            screen = hasActiveSession ? .playback : .home
            return
        }
        if SourceLinkHandoffURL.isSourceLinkURL(url) {
            do {
                if let payloadID = SourceLinkHandoffURL.payloadID(from: url) {
                    let handoffStore = try resolvedSourceLinkHandoffStore()
                    _ = try SourceLinkHandoffURL.handoff(from: url, store: handoffStore)
                    diagnostics["lastSourceLinkPayloadCleanup"] = "queued:\(payloadID)"
                    importPendingSourceLinkHandoffs()
                } else if let handoff = SourceLinkHandoffURL.handoff(from: url) {
                    if sourceLinkResolver == nil {
                        Task { @MainActor in
                            await importSourceLinkAsync(handoff)
                        }
                    } else {
                        importSourceLink(handoff)
                    }
                } else {
                    reportFailure("Unsupported source link URL.")
                }
            } catch SourceLinkHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastSourceLinkPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Source link import failed")
            }
            return
        }
        guard !Gate5BrowserTextHandoffURL.isBrowserTextURL(url) else {
            do {
                if let payloadID = Gate5BrowserTextHandoffURL.payloadID(from: url) {
                    let handoffStore = try resolvedBrowserTextHandoffStore()
                    let handoff = try Gate5BrowserTextHandoffURL.handoff(from: url, store: handoffStore)
                    if screen == .playback {
                        try importBrowserTextInBackground(handoff)
                        try? handoffStore.deletePayload(payloadID: payloadID)
                        diagnostics["lastBrowserTextPayloadCleanup"] = "imported_without_session_replacement"
                    } else if importBrowserText(handoff) {
                        try? handoffStore.deletePayload(payloadID: payloadID)
                    }
                } else if let handoff = Gate5BrowserTextHandoffURL.handoff(from: url) {
                    importBrowserText(handoff)
                } else {
                    reportFailure("Unsupported browser text URL.")
                }
            } catch Gate5BrowserTextHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastBrowserTextPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Browser text import failed")
            }
            return
        }
        handleGate2CompactURL(url)
    }

    @discardableResult
    func handleGate2CompactApplicationCommand(_ command: String) -> Bool {
        switch command {
        case Gate2CompactApplicationCommand.summarizeInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.generateInterjectionSummary) == true else {
                reportFailure("Summary is unavailable for the current compact surface state.")
                return false
            }
            summarize()
            return true
        case Gate2CompactApplicationCommand.discussInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.submitFollowup) == true else {
                reportFailure("Discuss is unavailable for the current compact surface state.")
                return false
            }
            discuss(followUp: "")
            return true
        default:
            reportFailure("Unsupported compact application command.")
            return false
        }
    }

    func saveProviderSettings() {
        guard remoteProviderExperienceEnabled else {
            reportFailure("Remote provider settings are disabled in this release.")
            return
        }
        sanitizeTTSMode()
        providerModel = fallbackProviderModel()
        UserDefaults.standard.set(providerModel, forKey: "providerModel")
        UserDefaults.standard.set(listeningMapModel, forKey: "listeningMapModel")
        UserDefaults.standard.set(summaryModel, forKey: "summaryModel")
        UserDefaults.standard.set(conversationModel, forKey: "conversationModel")
        UserDefaults.standard.set(skipUnit, forKey: "skipUnit")
        UserDefaults.standard.set(mediaSkipBackSeconds, forKey: "mediaSkipBackSeconds")
        UserDefaults.standard.set(mediaSkipForwardSeconds, forKey: "mediaSkipForwardSeconds")
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(kokoroVoiceName, forKey: "kokoroVoiceName")
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        let keychainStatus = KeychainStore.save(providerAPIKey, service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        guard keychainStatus == errSecSuccess else {
            diagnostics["keychainStatus"] = "save_failed:\(keychainStatus)"
            reportFailure("Provider settings were not saved because Keychain returned \(keychainStatus).")
            return
        }
        diagnostics["keychainStatus"] = providerAPIKey.isEmpty ? "empty" : "saved"
        cancelTextAudioPrewarmTasks()
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = providerModel
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
        diagnostics["apiKeyConfigured"] = providerAPIKey.isEmpty ? "false" : "true"
        if rebuildEngineForCurrentSettings() {
            screen = .settings
            reportConfirmation("Provider settings saved.")
        }
    }

    func saveSpeechSettings() {
        sanitizeTTSMode()
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(kokoroVoiceName, forKey: "kokoroVoiceName")
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        cancelTextAudioPrewarmTasks()
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
        diagnostics["speechTranscriptionEngine"] = systemSpeechTranscriptionEngineDescription()
    }

    func refreshSpeechVoiceOptions() {
        speechVoiceOptions = Self.availableSpeechVoiceOptions()
        diagnostics["speechVoiceCount"] = "\(speechVoiceOptions.count)"
        diagnostics["speechVoice"] = speechVoiceDescription
        let selected = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics["speechVoiceAvailability"] = selected.isEmpty || speechVoiceOptions.contains(where: { $0.id == selected })
            ? "available"
            : "unavailable"
    }

    func speechSettingsChanged() {
        let changed = sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        if changed {
            _ = rebuildEngineForCurrentSettings()
        } else if ttsVoiceSelection.supertonicVoice != nil, audioPlaybackClientOverride == nil {
            applySupertonicPlaybackRate()
        } else if !isMediaPlaybackSnapshot {
            run { engine in
                snapshot = try engine.updateSpeechPlaybackSettings(
                    voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                    rate: Float(speechRate)
                )
                refreshSelectedItem()
                diagnostics["speechSettingsApplied"] = snapshot.status.rawValue
                reportConfirmation("Speech settings saved.")
            }
        }
    }

    func ttsVoiceSelectionChanged() {
        if ttsVoiceSelection.supertonicVoice != nil, !hasAcceptedCurrentTerms {
            pendingTermsVoiceSelection = ttsVoiceSelection
            UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            diagnostics["termsGate"] = "presented_for_on_device_voice"
            statusMessage = "Review the Terms of Use to enable an on-device voice."
            return
        }
        sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        if let engine {
            snapshot = (try? engine.stopPlayback()) ?? snapshot
            refreshSelectedItem()
        }
        _ = rebuildEngineForCurrentSettings()
        if ttsVoiceSelection == .system, let renderer = supertonicRenderer {
            supertonicRenderer = nil
            Task { await renderer.unload() }
        }
        reportSuccess("Voice changed to \(ttsVoiceSelection.displayName). Press play when you are ready.")
    }

    func previewSpokenContentVoice() {
        previewSpeech(label: "Spoken Content settings", mode: .spokenContent)
    }

    func previewAppVoice() {
        saveSpeechSettings()
        if let voice = ttsVoiceSelection.supertonicVoice {
            previewSupertonicVoice(voice)
            return
        }
        previewSpeech(
            label: "app voice and rate",
            mode: .appVoice(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
        )
    }

    private func previewSupertonicVoice(_ voice: SupertonicVoiceID) {
        guard hasAcceptedCurrentTerms else {
            pendingTermsVoiceSelection = ttsVoiceSelection.supertonicVoice == nil ? .james : ttsVoiceSelection
            UserDefaults.standard.set(pendingTermsVoiceSelection?.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
            ttsVoiceSelection = .system
            saveSpeechSettings()
            isTermsOfUsePresented = true
            return
        }
        guard !isRenderingSupertonicPreview else { return }
        isRenderingSupertonicPreview = true
        statusMessage = "Preparing \(ttsVoiceSelection.displayName)…"
        let speed = Float(speechRate / 0.5)
        Task { [weak self] in
            guard let self else { return }
            do {
                let renderer = try self.makeSupertonicRenderer()
                let result = try await renderer.render(
                    text: "Spoken Margins is ready to read with your selected on-device voice.",
                    voice: voice,
                    speed: speed,
                    synthesisSteps: 8
                )
                try Task.checkCancellation()
                try self.playSupertonicPreview(url: result.audioURL)
                self.diagnostics["supertonicPreviewRenderSeconds"] = String(format: "%.3f", result.renderDuration)
                self.diagnostics["supertonicPreviewDurationSeconds"] = String(format: "%.3f", result.duration)
                self.diagnostics["supertonicSessionLoadCount"] = "\(result.sessionLoadCount)"
                self.reportSuccess("Playing \(self.ttsVoiceSelection.displayName).")
            } catch {
                self.reportFailure(error, context: "On-device voice preview failed")
            }
            self.isRenderingSupertonicPreview = false
        }
    }

    func verifyCurrentTermsForOnDeviceVoice() throws {
        guard SpokenMarginsTerms.hasBundledText() else {
            throw SpokenMarginsTermsError.bundledTermsUnavailable
        }
        guard hasAcceptedCurrentTerms else {
            throw SpokenMarginsTermsError.acceptanceRequired
        }
    }

    func previewAssistiveTechnologyVoice() {
        previewSpeech(label: "assistive technology settings", mode: .assistiveTechnology)
    }

    func refreshKokoroAssetStatus() {
        #if KOKORO_DEVICE && !targetEnvironment(simulator)
        do {
            let applicationSupportURL = try applicationSupportDirectory()
            let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
            let hasModel = assets.modelURL != nil
            let hasVoices = assets.voicesURL != nil
            diagnostics["kokoroModel"] = hasModel ? "installed" : "missing"
            diagnostics["kokoroVoices"] = hasVoices ? "installed" : "missing"
            if hasModel && hasVoices {
                kokoroStatus = "Assets installed."
            } else if hasModel {
                kokoroStatus = "Model installed; voices.npz missing."
            } else if hasVoices {
                kokoroStatus = "Voices installed; kokoro-v1_0.safetensors missing."
            } else {
                kokoroStatus = "Import kokoro-v1_0.safetensors and voices.npz."
            }
            diagnostics["kokoroStatus"] = kokoroStatus
        } catch {
            kokoroStatus = "Asset check failed: \(error.localizedDescription)"
            diagnostics["kokoroStatus"] = kokoroStatus
        }
        #else
        kokoroStatus = "Kokoro renderer is not linked in this build."
        diagnostics["kokoroStatus"] = kokoroStatus
        #endif
    }

    func refreshPiperVoiceStatus() {
        do {
            piperVoiceOptions = try discoverPiperVoiceOptions()
            if piperVoiceId.isEmpty, let first = piperVoiceOptions.first {
                piperVoiceId = first.id
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            } else if !piperVoiceId.isEmpty, !piperVoiceOptions.contains(where: { $0.id == piperVoiceId }) {
                piperVoiceId = piperVoiceOptions.first?.id ?? ""
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            }
            if piperVoiceOptions.isEmpty {
                piperStatus = "No Piper voices installed. Import a .onnx model and .onnx.json config."
            } else if let selected = piperVoiceOptions.first(where: { $0.id == piperVoiceId }) {
                piperStatus = "Selected \(selected.displayName). Piper renderer not linked in this build; playback will fail instead of falling back to system speech."
            } else {
                piperStatus = "\(piperVoiceOptions.count) Piper voice\(piperVoiceOptions.count == 1 ? "" : "s") installed."
            }
            diagnostics["piperVoices"] = "\(piperVoiceOptions.count)"
            diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
            diagnostics["piperStatus"] = piperStatus
        } catch {
            piperVoiceOptions = []
            piperStatus = "Piper voice check failed: \(error.localizedDescription)"
            diagnostics["piperStatus"] = piperStatus
        }
    }

    func previewKokoroVoice() {
        guard !isRenderingKokoroPreview else { return }
        saveSpeechSettings()
        isRenderingKokoroPreview = true
        kokoroStatus = "Preparing Kokoro preview..."
        diagnostics["kokoroStatus"] = kokoroStatus

        let voiceName = kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName
        let cacheLimitBytes = kokoroCacheLimitBytes
        let kokoroSpeed = Float(speechRate / 0.5)
        let itemId = selectedItem.id.isEmpty ? activeItemId : selectedItem.id
        let sourceText = "Spoken Margins Kokoro preview. This is a short on-device voice test."

        Task.detached { [voiceName, cacheLimitBytes, kokoroSpeed, itemId, sourceText] in
            #if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
            do {
                guard KokoroNarrationRenderer.isRuntimeSupported else {
                    throw KokoroNarrationError.unavailableOnSimulator
                }
                let applicationSupportURL = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
                guard let modelURL = assets.modelURL else {
                    throw KokoroNarrationError.missingModel
                }
                guard let voicesURL = assets.voicesURL else {
                    throw KokoroNarrationError.missingVoices
                }
                await MainActor.run {
                    self.kokoroStatus = "Kokoro assets found. Rendering short preview..."
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let cachesURL = try FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let outputDirectory = cachesURL.appending(path: "KokoroPreview", directoryHint: .isDirectory)
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                NSLog("SpokenMargins Kokoro preview memory configured %@", configured.description)
                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )
                let before = KokoroNarrationRenderer.memorySnapshot()
                let result = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "preview",
                    voiceName: voiceName,
                    speed: kokoroSpeed
                )
                let after = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog("SpokenMargins Kokoro preview memory before=%@ after=%@ final=%@", before.description, after.description, final.description)
                await MainActor.run {
                    do {
                        self.kokoroStatus = "Kokoro rendered. Starting playback..."
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.diagnostics["kokoroMemory.preview.configured"] = configured.description
                        self.diagnostics["kokoroMemory.preview.before"] = before.description
                        self.diagnostics["kokoroMemory.preview.after"] = after.description
                        self.diagnostics["kokoroMemory.preview.final"] = final.description
                        try self.playKokoroPreview(url: result.audioURL)
                        self.kokoroStatus = "Rendered \(String(format: "%.1f", result.duration))s with \(voiceName)"
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.diagnostics["lastSpeechPreview"] = "Kokoro \(voiceName)"
                        self.reportSuccess("Previewing Kokoro \(voiceName).")
                    } catch {
                        self.kokoroStatus = "Playback failed: \(error.localizedDescription)"
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.reportFailure(error, context: "Kokoro preview playback failed")
                    }
                    self.isRenderingKokoroPreview = false
                }
            } catch {
                await MainActor.run {
                    self.kokoroStatus = error.localizedDescription
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRenderingKokoroPreview = false
                    self.reportFailure(error, context: "Kokoro preview failed")
                }
            }
            #else
            await MainActor.run {
                self.kokoroStatus = "Kokoro renderer is not linked in this build."
                self.diagnostics["kokoroStatus"] = self.kokoroStatus
                self.isRenderingKokoroPreview = false
                self.reportFailure("Kokoro renderer is not linked in this build.")
            }
            #endif
        }
    }

    func runKokoroMemoryCheck() {
        guard !isRunningKokoroMemoryCheck else { return }
        saveSpeechSettings()
        isRunningKokoroMemoryCheck = true
        kokoroStatus = "Starting Kokoro memory check..."
        diagnostics["kokoroStatus"] = kokoroStatus

        let voiceName = kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName
        let cacheLimitBytes = kokoroCacheLimitBytes
        let itemId = selectedItem.id.isEmpty ? activeItemId : selectedItem.id
        let sourceText = "Spoken Margins Kokoro memory check. This renders twice without playback."

        Task.detached { [voiceName, cacheLimitBytes, itemId, sourceText] in
            #if KOKORO_DEVICE && !targetEnvironment(simulator)
            do {
                guard KokoroNarrationRenderer.isRuntimeSupported else {
                    throw KokoroNarrationError.unavailableOnSimulator
                }
                let applicationSupportURL = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
                guard let modelURL = assets.modelURL else {
                    throw KokoroNarrationError.missingModel
                }
                guard let voicesURL = assets.voicesURL else {
                    throw KokoroNarrationError.missingVoices
                }
                let cachesURL = try FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let outputDirectory = cachesURL.appending(path: "KokoroMemoryCheck", directoryHint: .isDirectory)
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                NSLog("SpokenMargins Kokoro memory check configured %@", configured.description)
                await MainActor.run {
                    self.kokoroStatus = "Memory check configured: \(configured)"
                    self.diagnostics["kokoroMemory.configured"] = configured.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }

                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )

                await MainActor.run {
                    self.kokoroStatus = "Memory check rendering pass 1 of 2..."
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let first = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "memory-check-1",
                    voiceName: voiceName,
                    speed: 1.0
                )
                let afterFirst = KokoroNarrationRenderer.memorySnapshot()
                await MainActor.run {
                    self.kokoroStatus = "Pass 1 rendered \(String(format: "%.1f", first.duration))s. Clearing cache..."
                    self.diagnostics["kokoroMemory.afterFirst"] = afterFirst.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }

                let afterClear = KokoroNarrationRenderer.clearMemoryCache()
                await MainActor.run {
                    self.kokoroStatus = "Memory check rendering pass 2 of 2..."
                    self.diagnostics["kokoroMemory.afterClear"] = afterClear.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let second = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "memory-check-2",
                    voiceName: voiceName,
                    speed: 1.0
                )
                let afterSecond = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()

                await MainActor.run {
                    self.kokoroStatus = "Memory check passed. Passes: \(String(format: "%.1f", first.duration))s, \(String(format: "%.1f", second.duration))s. Final \(final)"
                    self.diagnostics["kokoroMemory.afterSecond"] = afterSecond.description
                    self.diagnostics["kokoroMemory.final"] = final.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRunningKokoroMemoryCheck = false
                    self.reportSuccess("Kokoro memory check completed.")
                }
            } catch {
                await MainActor.run {
                    self.kokoroStatus = "Memory check failed: \(error.localizedDescription)"
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRunningKokoroMemoryCheck = false
                    self.reportFailure(error, context: "Kokoro memory check failed")
                }
            }
            #else
            await MainActor.run {
                self.kokoroStatus = "Kokoro renderer is not linked in this build."
                self.diagnostics["kokoroStatus"] = self.kokoroStatus
                self.isRunningKokoroMemoryCheck = false
                self.reportFailure("Kokoro renderer is not linked in this build.")
            }
            #endif
        }
    }

    func runtimeProfileChanged() {
        diagnostics["runtimeProfile"] = selectedProfileId
        if rebuildEngineForCurrentSettings() {
            reportSuccess("Runtime profile set to \(selectedProfileId).")
        }
    }

    func settingsValueChanged() {
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = fallbackProviderModel()
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["mediaSkipBackSeconds"] = "\(mediaSkipBackSeconds)"
        diagnostics["mediaSkipForwardSeconds"] = "\(mediaSkipForwardSeconds)"
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
    }

    func probeProvider() {
        guard remoteProviderExperienceEnabled else {
            providerProbeStatus = "Disabled by release feature flag"
            reportFailure("Remote provider access is disabled in this release.")
            return
        }
        saveProviderSettings()
        providerProbeStatus = "Checking..."
        guard let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            providerProbeStatus = "Invalid URL"
            reportFailure("Invalid provider URL.")
            return
        }
        var request = URLRequest(url: url)
        if !providerAPIKey.isEmpty {
            request.setValue("Bearer \(providerAPIKey)", forHTTPHeaderField: "Authorization")
        }
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    providerProbeStatus = (200..<300).contains(status) ? "Reachable (\(status))" : "HTTP \(status)"
                    diagnostics["providerProbe"] = providerProbeStatus
                    reportSuccess("Provider probe completed: \(providerProbeStatus).")
                }
            } catch {
                await MainActor.run {
                    providerProbeStatus = "Failed: \(error.localizedDescription)"
                    reportFailure(error, context: "Provider probe failed")
                }
            }
        }
    }

    var hasActiveSession: Bool {
        snapshot.sessionId != nil
    }

    static func isResumableSession(_ session: Session) -> Bool {
        session.status == "in_progress" && session.phase != .abandoned
    }

    static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        sessions.first { session in
            isResumableSession(session)
                || (session.status == "finished" && session.completionPercent >= 100)
        }
    }

    var selectedItemPreferredContinuationSession: Session? {
        Self.preferredContinuationSession(in: selectedItem.sessions)
    }

    var shouldShowMiniPlayer: Bool {
        hasActiveSession && screen != .playback && snapshot.phase != .finished && snapshot.phase != .abandoned
    }

    var isMediaPlaybackSnapshot: Bool {
        snapshot.targetType == TargetType.transcriptBackedMedia.rawValue ||
            snapshot.targetType == TargetType.browserOwnedMedia.rawValue
    }

    var displayPlaybackProgressPercent: Int {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue,
            TargetType.transcriptBackedMedia.rawValue,
            TargetType.browserOwnedMedia.rawValue:
            return snapshot.sourceProgressPercent
        default:
            return snapshot.currentPlaybackProgressPercent
        }
    }

    var canPlayLiveSpeechInstead: Bool {
        pendingPreparedTextStartItemId == activeItemId
    }

    var canFinishInterjection: Bool {
        snapshot.isRecording
    }

    var canSummarizeInterjections: Bool {
        aiSummaryExperienceAvailable && hasActiveSession && !unsummarizedInterjectionsForCurrentTarget().isEmpty
    }

    var isSummarizingInterjections: Bool {
        latestPendingJob(kind: "interjection_summary") != nil
    }

    var canRetryLocalSummary: Bool {
        guard !remoteProviderExperienceEnabled,
              hasActiveSession,
              let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else { return false }
        return jobs.contains { $0.kind == "interjection_summary" && $0.status == "retryable" }
    }

    var summaryActionTitle: String {
        if isSummarizingInterjections { return "Summarizing" }
        return canRetryLocalSummary ? "Retry Summary" : "Summarize Notes"
    }

    var interjectionButtonTitle: String {
        "Interject"
    }

    var speechVoiceDescription: String {
        if ttsVoiceSelection != .system {
            return "\(ttsVoiceSelection.displayName) (Supertonic \(ttsVoiceSelection.supertonicVoice?.rawValue ?? ""))"
        }
        guard !speechVoiceIdentifier.isEmpty else {
            return "System Spoken Content Voice (Siri falls back)"
        }
        if let voice = speechVoiceOptions.first(where: { $0.id == speechVoiceIdentifier }) {
            return "\(voice.name) (\(voice.language), \(voice.quality))"
        }
        return speechVoiceIdentifier
    }

    var speechRateDescription: String {
        if ttsVoiceSelection.supertonicVoice != nil {
            return String(format: "Supertonic %.2fx", max(0.7, min(2.0, speechRate / 0.5)))
        }
        if ttsMode == "kokoro", isKokoroDeviceBuild {
            return String(format: "Kokoro %.2fx", max(0.65, min(1.75, speechRate / 0.5)))
        }
        return String(format: "System %.2f", speechRate)
    }

    var mediaPlaybackRateDescription: String {
        String(format: "%.2fx", mediaPlaybackRate)
    }

    var compactPlaybackRateDescription: String {
        if isMediaPlaybackSnapshot {
            return String(format: "%.2f×", mediaPlaybackRate)
        }
        let effectiveRate = max(0.5, speechRate / 0.5)
        return String(format: "%.2f×", effectiveRate)
    }

    var playbackHeaderTitle: String {
        let itemTitle = selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotTitle = (snapshot.chapterTitle ?? snapshot.title ?? itemTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshotTitle.isEmpty else { return itemTitle }
        guard snapshotTitle.caseInsensitiveCompare(itemTitle) != .orderedSame else { return itemTitle }

        let chapterTitles = playbackChapterTitles
        guard let chapterIndex = chapterTitles.firstIndex(where: {
            $0.caseInsensitiveCompare(snapshotTitle) == .orderedSame
        }) else {
            return snapshotTitle
        }
        return "Ch. \(chapterIndex + 1): \(snapshotTitle)"
    }

    var playbackItemHeaderTitle: String {
        selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var playbackChapterHeaderTitle: String? {
        let itemTitle = playbackItemHeaderTitle
        let combined = playbackHeaderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty,
              combined.caseInsensitiveCompare(itemTitle) != .orderedSame else {
            return nil
        }
        return combined
    }

    var exportSourceTextAvailable: Bool {
        !selectedItem.isNativeAudio
    }

    func openCurrentPlaybackItem() {
        guard let itemId = snapshot.itemId ?? (selectedItem.id.isEmpty ? nil : selectedItem.id) else { return }
        openItem(id: itemId)
    }

    func isCurrentTimelineChapter(_ chapter: Chapter, turnId: String? = nil) -> Bool {
        if turnId == nil {
            let sourceTargetTypes = [
                TargetType.itemTextTTS.rawValue,
                TargetType.transcriptBackedMedia.rawValue,
                TargetType.browserOwnedMedia.rawValue
            ]
            guard let targetType = snapshot.targetType, sourceTargetTypes.contains(targetType) else { return false }
            if let currentChapterId = engine?.currentSession?.position.chapterId,
               selectedItem.chapters.contains(where: { $0.id == currentChapterId }) {
                return currentChapterId == chapter.id
            }
            if let currentTitle = snapshot.chapterTitle,
               selectedItem.chapters.contains(where: { $0.title.caseInsensitiveCompare(currentTitle) == .orderedSame }) {
                return currentTitle.caseInsensitiveCompare(chapter.title) == .orderedSame
            }
            return currentChapter?.id == chapter.id
        }

        let expectedTargetType = selectedItem.turns.first(where: { $0.id == turnId })?.turnType == "interjection_summary"
            ? TargetType.summaryTurnTTS.rawValue
            : TargetType.assistantTurnTTS.rawValue
        guard snapshot.targetType == expectedTargetType else { return false }
        if let turnId, snapshot.targetId != turnId { return false }
        if let currentChapterId = engine?.currentSession?.position.chapterId {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    var hasConfiguredProviderAPIKey: Bool {
        !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var playbackChapterTitles: [String] {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return selectedItem.chapters.map(\.title)
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return selectedItem.turns
                .first(where: { $0.id == snapshot.targetId })?
                .chapters?
                .map(\.title) ?? []
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
        default:
            return []
        }
    }

    var preparedTextAudioStatusDescription: String {
        humanReadableStatus(preparedTextAudioStatus)
    }

    var shouldShowOnDeviceSpeechGenerationStatus: Bool {
        snapshot.targetType == TargetType.itemTextTTS.rawValue
            && ttsVoiceSelection.supertonicVoice != nil
            && onDeviceSpeechGenerationStatus != RenderedSpeechGenerationState.inactive.rawValue
    }

    var canStopOnDeviceSpeechGeneration: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
            || onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.ready.rawValue
    }

    var isOnDeviceSpeechGenerating: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var onDeviceSpeechGenerationStatusDescription: String {
        switch onDeviceSpeechGenerationStatus {
        case RenderedSpeechGenerationState.rendering.rawValue:
            return "Generating the next audio section on this iPhone"
        case RenderedSpeechGenerationState.ready.rawValue:
            return "The next audio section is ready"
        case RenderedSpeechGenerationState.stopped.rawValue:
            return "Generation stopped · using the iOS system voice"
        default:
            return "On-device voice generation is inactive"
        }
    }

    var sourceTranscriptStatusDescription: String {
        humanReadableStatus(sourceTranscriptStatus)
    }

    var isKokoroDeviceBuild: Bool {
        #if KOKORO_DEVICE && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var kokoroCacheLimitBytes: Int {
        kokoroCacheLimitMB * 1024 * 1024
    }

    var kokoroCacheLimitMB: Int {
        256
    }

    var kokoroChunkCharacterLimit: Int {
        Int(max(80, min(140, kokoroChunkCharacters)).rounded())
    }

    var kokoroSkipForwardMinimumDistance: Int {
        max(220, kokoroChunkCharacterLimit * 2)
    }

    private func humanReadableStatus(_ status: String) -> String {
        switch status {
        case "not_started":
            return "not started"
        case "rendering":
            return "rendering"
        case "starter_ready":
            return "starter ready"
        case "ready", "complete":
            return "ready"
        case "failed":
            return "failed"
        case "live_fallback":
            return "live fallback"
        case "queued":
            return "queued"
        case "downloading":
            return "downloading"
        case "transcribing":
            return "transcribing"
        case "unavailable":
            return "unavailable"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    var currentChapter: Chapter? {
        selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
    }

    private func installEngine(_ engine: SessionEngine) {
        self.engine = engine
        for record in podcastDownloadRecords.values where record.state == .availableOffline {
            guard let path = record.localRelativePath,
                  let url = try? applicationSupportDirectory()
                    .appending(path: "PodcastAudio", directoryHint: .isDirectory)
                    .appending(path: path) else { continue }
            _ = try? engine.updatePlaybackTransport(itemId: record.itemId, playbackURL: url.absoluteString)
        }
        configureGate2CompactControls(for: engine)
    }

    private func configureGate2CompactControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "lock-screen-widget")
            gate2CompactControls.configure(
                canonicalRuntime: engine,
                surfaceProfile: surfaceProfile,
                skipUnit: mediaSkipUnit(seconds: mediaSkipForwardSeconds)
            ) { [weak self] command, origin, chapterId, mediaTimeMs, playbackRate in
                self?.dispatchGate2CompactCommand(
                    command,
                    chapterId: chapterId,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: origin
                )
            } applicationCommandHandler: { [weak self] command in
                self?.handleGate2CompactApplicationCommand(command) ?? false
            }
            updateGate2CompactState()
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
        } catch {
            diagnostics["gate2CompactSurface"] = "configuration_failed"
            diagnostics["gate2CompactError"] = String(describing: error)
        }
    }

    private func updateGate2CompactState() {
        gate2CompactControls.update(snapshot: snapshot)
        gate2CompactSnapshot = gate2CompactControls.snapshot
        diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
    }

    #if SPOKEN_MARGINS_WATCH
    private func configureGate3WatchControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "watch-tethered")
            gate3WatchDispatcher = CompactControlDispatcher(
                surfaceProfile: surfaceProfile,
                canonicalRuntime: engine,
                defaultSkipUnit: skipUnit
            )
            updateGate3WatchState()
        } catch {
            diagnostics["gate3WatchSurface"] = "configuration_failed"
            diagnostics["gate3WatchError"] = String(describing: error)
        }
    }

    private func gate3WatchSnapshot() -> CompactControlSnapshot? {
        gate3WatchDispatcher?.snapshot()
    }

    private func updateGate3WatchState() {
        gate3WatchConnectivity.publish(snapshot: gate3WatchSnapshot())
        diagnostics.merge(gate3WatchConnectivity.diagnostics(), uniquingKeysWith: { _, new in new })
    }

    private func gate4WatchPackageLibraryRows() -> [WatchPackageLibraryRow] {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            let items = try store.listItems()
            return try items.flatMap { item -> [WatchPackageLibraryRow] in
                let packages = try store.loadWatchAudioPackages(itemId: item.id)
                let requests = try store.loadWatchPackageRequests(itemId: item.id)
                if let package = packages.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    let hasTransferRequest = requests.contains { $0.packageId == package.id && $0.requestType == .watchTransferRequested }
                    return [
                        WatchPackageLibraryRow(
                            itemId: item.id,
                            title: package.item.title.isEmpty ? item.title : package.item.title,
                            status: hasTransferRequest ? .queuedForTransfer : .availableForTransfer,
                            packageId: package.id,
                            progressPercent: hasTransferRequest ? 0 : nil
                        )
                    ]
                }
                let hasPrerenderRequest = requests.contains { $0.requestType == .prerenderRequested }
                let status: WatchPackageLibraryStatus
                if activeWatchPackageRenderItemIds.contains(item.id) {
                    status = .rendering
                } else if failedWatchPackageRenderItemIds.contains(item.id) {
                    status = .failed
                } else if hasPrerenderRequest {
                    status = .rendering
                } else {
                    status = .needsPrerender
                }
                return [
                    WatchPackageLibraryRow(
                        itemId: item.id,
                        title: item.title,
                        status: status,
                        packageId: nil,
                        progressPercent: status == .rendering ? 0 : nil
                    )
                ]
            }
        } catch {
            diagnostics["gate4WatchPackageLibraryError"] = String(describing: error)
            return []
        }
    }

    private func gate4WatchPackage(packageId: String) throws -> WatchAudioPackage? {
        let store = try requireStore()
        try seedGate4WatchPackageFixture(store: store)
        return try store.loadWatchAudioPackage(id: packageId)
    }

    private func handleGate4WatchPackageRequest(_ request: WatchPackageRequestEvent) {
        do {
            let store = try requireStore()
            try store.saveWatchPackageRequest(request)
            diagnostics["gate4WatchLastPackageRequest"] = "\(request.requestType.rawValue):\(request.itemId)"
            if request.requestType == .prerenderRequested {
                renderWatchPackage(itemId: request.itemId, transferAfterRender: true)
            } else if request.requestType == .watchTransferRequested, let packageId = request.packageId {
                gate3WatchConnectivity.transferWatchPackage(packageId: packageId)
            }
            gate3WatchConnectivity.publishPackageLibrary()
        } catch {
            diagnostics["gate4WatchPackageRequestError"] = String(describing: error)
            reportFailure(error, context: "Watch package request failed")
        }
    }

    private func handleGate4WatchSyncEvent(_ event: WatchSyncEvent) {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            try store.saveWatchSyncEvent(event)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            _ = try engine?.importWatchSyncEvent(eventId: event.id)
            if let engine {
                snapshot = engine.snapshot
            }
            libraryItems = try loadLibraryRows(store: store)
            let importedItemId: String?
            if let itemId = event.itemId {
                importedItemId = itemId
            } else {
                importedItemId = try store.loadWatchAudioPackage(id: event.watchPackageId)?.itemId
            }
            if let itemId = importedItemId {
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["gate4WatchLastImportedEvent"] = event.id
            reportSuccess("Imported Watch event \(event.id).")
        } catch {
            diagnostics["gate4WatchSyncEventError"] = String(describing: error)
            reportFailure(error, context: "Watch sync import failed")
        }
    }

    private func renderWatchPackage(itemId: String, transferAfterRender: Bool) {
        guard !itemId.isEmpty else {
            reportFailure("Choose an item before rendering Watch audio.")
            return
        }
        guard !activeWatchPackageRenderItemIds.contains(itemId) else {
            reportFailure("Watch audio is already rendering for this item.")
            return
        }
        activeWatchPackageRenderItemIds.insert(itemId)
        failedWatchPackageRenderItemIds.remove(itemId)
        isRenderingWatchPackage = true
        watchPackageRenderStatus = "Rendering"
        diagnostics["gate4WatchRenderItem"] = itemId
        gate3WatchConnectivity.publishPackageLibrary()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let item = try store.loadItem(id: itemId)
                let map = try store.loadListeningMap(itemId: itemId)
                let coordinator = WatchPackageRenderCoordinator(
                    applicationSupportDirectory: try self.applicationSupportDirectory()
                )
                let output = try await coordinator.renderSystemSpeechPackage(
                    item: item,
                    map: map,
                    voiceIdentifier: self.speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self.speechVoiceIdentifier,
                    rate: Float(self.speechRate)
                )
                try store.saveWatchAudioPackage(output.package)
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.remove(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.libraryItems = try self.loadLibraryRows(store: store)
                if itemId == self.selectedItem.id || itemId == self.activeItemId {
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                }
                self.diagnostics["gate4WatchLastRenderedPackage"] = output.package.id
                self.diagnostics["gate4WatchLastRenderedAudio"] = output.audioURL.lastPathComponent
                self.watchPackageRenderStatus = "Available"
                self.reportSuccess("Rendered Watch package \(output.package.item.title).")
                self.gate3WatchConnectivity.publishPackageLibrary()
                if transferAfterRender {
                    self.gate3WatchConnectivity.transferWatchPackage(packageId: output.package.id)
                }
            } catch {
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.insert(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.watchPackageRenderStatus = "Failed"
                self.diagnostics["gate4WatchRenderError"] = String(describing: error)
                self.reportFailure(error, context: "Watch package render failed")
                self.gate3WatchConnectivity.publishPackageLibrary()
            }
        }
    }

    private func dispatchGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        diagnostics["gate2LastCommandOrigin"] = "watch_connectivity_legacy"
        if request.command == .beginInterjection {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "disabled_until_watch_recording"
            updateGate3WatchState()
            reportFailure("Watch interjection is disabled until Watch-owned or background-safe recording is available.")
            return
        }
        guard gate3WatchSnapshot()?.availableCommands.contains(request.command) == true else {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "unavailable"
            updateGate3WatchState()
            reportFailure("Watch command \(request.command.rawValue) is unavailable for the current session state.")
            return
        }
        if request.command == .generateInterjectionSummary {
            summarize()
            updateGate3WatchState()
            return
        }
        if request.command == .submitFollowup {
            discuss(followUp: request.followUpText ?? "Can you respond to my interjection?")
            updateGate3WatchState()
            return
        }
        if request.command == .beginInterjection {
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    reportFailure("Microphone access is required to record interjections from Watch.")
                    updateGate3WatchState()
                    return
                }
                performGate3WatchCommand(request)
            }
            return
        }
        performGate3WatchCommand(request)
    }

    private func performGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        do {
            if engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let dispatcher = gate3WatchDispatcher else {
                throw SessionKitError.invalidCommandForState("watch_tethered_unconfigured")
            }
            let result = try dispatcher.dispatch(
                request.command,
                chapterId: request.chapterId,
                unit: request.unit,
                followUpText: request.followUpText
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate3WatchState()
            }
            refreshSelectedItem()
            if request.command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
            updateGate3WatchState()
            reportSuccess("Watch control \(request.command.rawValue) delegated.")
        } catch {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "failed"
            updateGate3WatchState()
            reportFailure(error, context: "Watch control failed")
        }
    }
    #endif

    private func performGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        let canonicalTransportCommands: Set<CompactControlCommand> = [
            .play, .pause, .togglePlayPause, .skipBack, .skipForward, .jumpToChapter
        ]
        if command == .beginInterjection || canonicalTransportCommands.contains(command) {
            synchronizeStreamingSpeechAnchorIfNeeded()
        }
        if command == .beginInterjection {
            streamingSpeechQueue.pauseForInterjection()
        }
        do {
            let result = try gate2CompactControls.dispatch(
                command,
                chapterId: chapterId,
                unit: compactSkipUnit(for: command),
                mediaTimeMs: mediaTimeMs,
                playbackRate: playbackRate,
                origin: origin
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate2CompactState()
            }
            if command == .setPlaybackRate,
               let playbackRate {
                if isMediaPlaybackSnapshot {
                    mediaPlaybackRate = max(0.75, min(2.0, playbackRate))
                    UserDefaults.standard.set(mediaPlaybackRate, forKey: "mediaPlaybackRate")
                    diagnostics["mediaPlaybackRate"] = String(format: "%.2f", mediaPlaybackRate)
                } else {
                    speechRate = max(0.35, min(0.85, playbackRate * 0.5))
                    UserDefaults.standard.set(speechRate, forKey: "speechRate")
                }
            }
            refreshSelectedItem()
            if command == .finishInterjection {
                recordSavedInterjectionForOnboarding()
            }
            if command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            if command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
            }
            if canonicalTransportCommands.contains(command) {
                streamingSpeechQueue.relinquishToCanonicalPlayback()
            }
            reportSuccess("Compact control \(command.rawValue) \(result.delegatedToCanonicalRuntime ? "delegated" : "handled").")
        } catch {
            if command == .beginInterjection || command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
            }
            reportFailure(error, context: "Compact control failed")
        }
    }

    private func compactSkipUnit(for command: CompactControlCommand) -> String? {
        guard isMediaPlaybackSnapshot else { return nil }
        switch command {
        case .skipBack:
            return mediaSkipUnit(seconds: mediaSkipBackSeconds)
        case .skipForward:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return nil
        }
    }

    private func synchronizeStreamingSpeechAnchorIfNeeded() {
        guard let engine,
              let turnId = streamingSpeechQueue.currentTurnId,
              let presentationOffset = streamingSpeechQueue.currentPresentationOffset else {
            return
        }
        do {
            snapshot = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: presentationOffset)
            diagnostics["streamingInterjectionTurnId"] = turnId
            diagnostics["streamingPresentationOffset"] = "\(presentationOffset)"
            diagnostics["streamingRecoveryOffset"] = "\(streamingSpeechQueue.currentRecoveryOffset ?? presentationOffset)"
        } catch {
            diagnostics["streamingAnchorSyncError"] = String(describing: error)
        }
    }

    private func applyStreamingSpeechObservation(_ observation: StreamingSpeechQueue.PlaybackObservation) {
        guard let engine, snapshot.targetId == observation.turnId else { return }
        do {
            switch observation.event {
            case .started:
                snapshot = try engine.streamingTurnPlaybackStarted(
                    turnId: observation.turnId,
                    charOffset: observation.charOffset
                )
            case .progressed:
                snapshot = try engine.updateStreamingTurnPosition(
                    turnId: observation.turnId,
                    charOffset: observation.charOffset
                )
            case .failed:
                diagnostics["streamingSpeechFailure:\(observation.turnId)"] = "offset:\(observation.charOffset)"
            }
        } catch {
            diagnostics["streamingSpeechObservationError"] = String(describing: error)
        }
    }

    private func run(_ operation: (SessionEngine) throws -> Void) {
        if engine == nil {
            do {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            } catch {
                reportFailure(error, context: "Playback setup failed")
            }
        }
        guard let engine else { return }
        do {
            try operation(engine)
        } catch {
            reportFailure(error)
        }
    }

    private func previewSpeech(label: String, mode: AppSpeechPreviewMode) {
        #if canImport(AVFoundation)
        do {
            kokoroPreviewPlayer?.stop()
            if speechPreviewSynthesizer.isSpeaking {
                speechPreviewSynthesizer.stopSpeaking(at: .immediate)
            }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let utterance = AVSpeechUtterance(string: "Spoken Margins preview. This is the \(label) path.")
            switch mode {
            case .spokenContent:
                utterance.rate = Float(speechRate)
            case .appVoice(let voiceIdentifier, let rate):
                utterance.rate = rate
                if let voiceIdentifier,
                   let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                    utterance.voice = configuredVoice
                }
            case .assistiveTechnology:
                utterance.rate = Float(speechRate)
                utterance.prefersAssistiveTechnologySettings = true
            }
            speechPreviewSynthesizer.speak(utterance)
            diagnostics["lastSpeechPreview"] = label
            reportSuccess("Previewing \(label).")
        } catch {
            reportFailure(error, context: "Speech preview failed")
        }
        #else
        reportFailure("Speech preview unavailable on this platform.")
        #endif
    }

    #if canImport(AVFoundation)
    private func stopSpeechPreviews() {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        kokoroPreviewPlayer?.stop()
        supertonicPreviewPlayer?.stop()
    }

    private func playSupertonicPreview(url: URL) throws {
        stopSpeechPreviews()
        if let priorURL = supertonicPreviewURL, let renderer = supertonicRenderer {
            Task { await renderer.discardGeneratedAudio(at: priorURL) }
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        supertonicPreviewPlayer = try AVAudioPlayer(contentsOf: url)
        supertonicPreviewPlayer?.prepareToPlay()
        guard supertonicPreviewPlayer?.play() == true else {
            throw SupertonicNarrationError.unsafeAudio("preview_playback_failed")
        }
        supertonicPreviewURL = url
    }

    private func playKokoroPreview(url: URL) throws {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        kokoroPreviewPlayer = try AVAudioPlayer(contentsOf: url)
        kokoroPreviewPlayer?.prepareToPlay()
        kokoroPreviewPlayer?.play()
    }
    #else
    private func stopSpeechPreviews() {}
    #endif

    private func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func kokoroAssetsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(path: "Kokoro", directoryHint: .isDirectory)
    }

    private func piperAssetsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(path: "Piper", directoryHint: .isDirectory)
    }

    private func isSupportedPiperVoiceAsset(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".onnx") || lowercasedName.hasSuffix(".onnx.json")
    }

    private func discoverPiperVoiceOptions() throws -> [PiperVoiceOption] {
        let directory = try piperAssetsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".onnx") }
            .compactMap { modelURL -> PiperVoiceOption? in
                let voiceId = piperVoiceId(forModelURL: modelURL)
                guard !voiceId.isEmpty else { return nil }
                let configURL = piperConfigURL(forVoiceId: voiceId, in: directory)
                let metadata = piperVoiceMetadata(configURL: configURL)
                return PiperVoiceOption(
                    id: voiceId,
                    name: metadata.name ?? piperDisplayName(for: voiceId),
                    language: metadata.language ?? "",
                    modelURL: modelURL,
                    configURL: configURL
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func piperVoiceId(forModelURL url: URL) -> String {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".onnx") else { return "" }
        return String(name.dropLast(5))
    }

    private func piperConfigURL(forVoiceId voiceId: String, in directory: URL) -> URL? {
        let candidates = [
            directory.appending(path: "\(voiceId).onnx.json"),
            directory.appending(path: "\(voiceId).json")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func piperDisplayName(for voiceId: String) -> String {
        voiceId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private func piperVoiceMetadata(configURL: URL?) -> (name: String?, language: String?) {
        guard let configURL,
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let dataset = object["dataset"] as? String
        let language = object["language"] as? [String: Any]
        let languageCode = language?["code"] as? String
        let languageName = language?["name"] as? String
        return (
            dataset?.isEmpty == false ? dataset : nil,
            languageName ?? languageCode
        )
    }

    private func summaryScopeForCurrentTarget() -> SummaryScope {
        switch currentPlaybackTargetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return SummaryScope(targetType: "turn", turnId: currentPlaybackTargetId)
        default:
            return SummaryScope(targetType: "item")
        }
    }

    private func latestPendingSummaryTurnId() -> String? {
        guard let sessionId = snapshot.sessionId,
              let turns = try? store?.loadTurns(sessionId: sessionId) else { return nil }
        return turns
            .filter { $0.turnType == "interjection_summary" && $0.status != "complete" }
            .last?.id
    }

    private func unsummarizedInterjectionsForCurrentTarget() -> [Interjection] {
        Gate1SummaryEligibility.unsummarizedInterjections(
            turns: selectedItem.turns,
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId
        )
    }

    private var currentPlaybackTargetType: String {
        (engine?.currentSession?.currentTargetType).map(\.rawValue) ?? snapshot.targetType ?? TargetType.itemTextTTS.rawValue
    }

    private var currentPlaybackTargetId: String? {
        engine?.currentSession?.currentTargetId ?? snapshot.itemId
    }

    private func rebuildEngineForCurrentSettings() -> Bool {
        guard let store else { return true }
        do {
            let replacement = try makeEngine(store: store)
            let sessionId = engine?.currentSession?.id ?? snapshot.sessionId
            if engine?.currentSession != nil {
                snapshot = try engine?.stopPlayback() ?? snapshot
            }
            let restoredSnapshot = try sessionId.map { try replacement.inspectSession(sessionId: $0) }
            installEngine(replacement)
            if let restoredSnapshot {
                snapshot = restoredSnapshot
                activeItemId = restoredSnapshot.itemId ?? activeItemId
                refreshSelectedItem()
                diagnostics["sessionRestoredAfterRuntimeRebuild"] = sessionId
            }
            return true
        } catch {
            reportFailure(error, context: "Runtime profile update failed")
            return false
        }
    }

    private func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
        let loadedProfile = try loadProfile(id: selectedProfileId)
        let profile = runtimeProfileForFeatureFlags(loadedProfile)
        let provider: AIProviderClient
        if !remoteProviderExperienceEnabled {
            provider = AppleFoundationAIProvider()
        } else if let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            provider = OpenAICompatibleProvider(baseURL: url, model: fallbackProviderModel(), apiKeyReference: providerAPIKey.isEmpty ? nil : "keychain:SpokenMargins/OpenAICompatibleAPIKey")
        } else {
            provider = FixtureAIProvider()
        }
        return SessionEngine(
            profile: profile,
            repository: store,
            audio: try makeAudioPlaybackClient(),
            recorder: recordingClientOverride ?? SystemRecordingClient(),
            aiProvider: provider,
            linkResolver: sourceLinkResolver ?? PublicPodcastLinkResolver(),
            textAudio: try makeTextAudioPreparationClient()
        )
    }

    private func runtimeProfileForFeatureFlags(_ profile: RuntimeCapabilityProfile) -> RuntimeCapabilityProfile {
        guard !remoteProviderExperienceEnabled else { return profile }
        var capabilities = profile.capabilities
        let allowedLocalAI = localFoundationModelAvailable
            ? Set(["generate_listening_map", "summarize_interjections", "cleanup_transcript", "defer_ai_jobs"])
            : Set(["cleanup_transcript", "defer_ai_jobs"])
        capabilities["ai"] = capabilities["ai", default: []].filter(allowedLocalAI.contains)
        return RuntimeCapabilityProfile(
            id: "\(profile.id)-local-foundation",
            displayName: "\(profile.displayName) · On-device AI",
            capabilities: capabilities,
            forbiddenCapabilities: Array(Set(profile.forbiddenCapabilities).union([
                "provider_diagnostics",
                "continue_discussion"
            ])).sorted()
        )
    }

    private func makeTextAudioPreparationClient() throws -> TextAudioPreparationClient? {
        guard audioPlaybackClientOverride == nil else { return nil }
        guard ttsVoiceSelection == .system else { return nil }
        guard ttsMode != "kokoro" else { return nil }
        guard ttsMode != "piper" else { return nil }
        #if canImport(AVFoundation)
        diagnostics["sessionTextAudio"] = "System generated audio"
        return SystemTextAudioPreparationClient(
            outputDirectory: try generatedTextAudioDirectory(),
            voiceIdentifier: speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier,
            speechRate: Float(speechRate),
            allowsSynchronousRendering: false
        )
        #else
        return nil
        #endif
    }

    private func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        // AVSpeechSynthesizer serializes or competes with live utterances on real
        // devices. Only an explicitly injected preparation job may pre-render in
        // the background; production playback must stay on the immediate path.
        guard ttsVoiceSelection == .system else { return }
        guard let prewarmHandler = preparedTextAudioPrewarmHandler, ttsMode != "kokoro" else { return }
        guard ttsMode != "piper" else { return }
        guard textAudioPrewarmTasks[itemId] == nil else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            let substantiallyCompleted = Self.hasSubstantiallyCompletedTextSession(
                try store.loadSessions(itemId: itemId)
            )
            guard !substantiallyCompleted else {
                diagnostics["textAudioPrewarm:\(itemId)"] = "skipped_substantially_completed"
                return
            }
            guard shouldPrewarmTextAudio(for: item), let text = item.text else { return }
            let outputDirectory = try generatedTextAudioDirectory()
            let voiceIdentifier = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier
            let rate = Float(speechRate)
            diagnostics["textAudioPrewarm:\(itemId)"] = "scheduled"
            preparedTextAudioStatus = "rendering"
            snapshot.preparedTextAudioStatus = preparedTextAudioStatus
            textAudioPrewarmTasks[itemId] = Task { [weak self, itemId, title = item.title, text, outputDirectory, voiceIdentifier, rate] in
                guard let self else { return }
                self.diagnostics["textAudioPrewarm:\(itemId)"] = "rendering_full"
                let fullResult = await prewarmHandler(itemId, title, text, outputDirectory, voiceIdentifier, rate)
                guard !Task.isCancelled else { return }
                self.textAudioPrewarmTasks[itemId] = nil
                switch fullResult {
                case .success(let prepared):
                    guard let prepared else {
                        self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_unavailable")
                        return
                    }
                    self.attachPreparedTextAudio(prepared, itemId: itemId, preparedStatus: "ready", diagnosticStatus: "ready")
                case .failure(let error):
                    self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_failed:\(error.localizedDescription)")
                }
            }
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "failed:\(error.localizedDescription)"
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
        }
    }

    private nonisolated static func prepareTextAudioInBackground(
        itemId: String,
        title: String,
        text: String,
        outputDirectory: URL,
        voiceIdentifier: String?,
        speechRate: Float,
        renderScope: TextAudioPrewarmRenderScope
    ) async -> Result<PreparedTextAudio?, Error> {
        await Task.detached(priority: renderScope.priority) {
            do {
                let renderer = SystemTextAudioPreparationClient(
                    outputDirectory: outputDirectory,
                    voiceIdentifier: voiceIdentifier,
                    speechRate: speechRate,
                    allowsSynchronousRendering: true
                )
                switch renderScope {
                case .starter(let targetDurationMs):
                    return .success(try renderer.prepareStarterTextAudio(itemId: itemId, title: title, text: text, targetDurationMs: targetDurationMs))
                case .complete:
                    return .success(try renderer.prepareTextAudio(itemId: itemId, title: title, text: text))
                }
            } catch {
                return .failure(error)
            }
        }.value
    }

    @discardableResult
    private func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready"
    ) -> Bool {
        do {
            let shouldAutoStart = pendingPreparedTextStartItemId == itemId
            if engine == nil, let store {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            snapshot = try engine.attachPreparedTextAudio(itemId: itemId, prepared: prepared)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                if activeItemId == itemId || selectedItem.id == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            diagnostics["textAudioPrewarm:\(itemId)"] = diagnosticStatus
            preparedTextAudioStatus = preparedStatus
            snapshot.preparedTextAudioStatus = preparedStatus
            if shouldAutoStart {
                pendingPreparedTextStartItemId = nil
                startItem(id: itemId)
            }
            return true
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "attach_failed:\(error.localizedDescription)"
            if pendingPreparedTextStartItemId == itemId {
                pendingPreparedTextStartItemId = nil
            }
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
            return false
        }
    }

    private func finishTextAudioPrewarm(itemId: String, status: String, diagnostic: String) {
        textAudioPrewarmTasks[itemId] = nil
        diagnostics["textAudioPrewarm:\(itemId)"] = diagnostic
        if pendingPreparedTextStartItemId == itemId {
            pendingPreparedTextStartItemId = nil
        }
        preparedTextAudioStatus = status
        snapshot.preparedTextAudioStatus = status
    }

    private nonisolated static func preparedTextAudioCoversCompleteText(_ prepared: PreparedTextAudio) -> Bool {
        guard let endChar = prepared.timeline.segments.compactMap(\.endChar).max() else {
            return false
        }
        return endChar >= prepared.normalizedText.count
    }

    private func shouldPrewarmTextAudio(for item: Item) -> Bool {
        guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        if item.mediaType == TargetType.browserOwnedMedia.rawValue {
            return false
        }
        switch item.media?.sourceType {
        case .none, .some(.generatedTTSRealtime):
            return true
        case .some(.generatedTTSPrerendered):
            return !isPreparedTextMediaAvailable(item.media) || isStarterPreparedTextMedia(item.media)
        case .some(.nativeMediaFile), .some(.browserOwnedMedia), .some(.remoteStream):
            return false
        }
    }

    static func hasSubstantiallyCompletedTextSession(_ sessions: [Session]) -> Bool {
        sessions.contains { $0.completionPercent >= substantiallyCompletedTextThreshold }
    }

    private func isStarterPreparedTextMedia(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
    }

    private func isPreparedTextMediaAvailable(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = [media?.url, media?.nativeMediaId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard let url = URL(string: identifier), url.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func cancelTextAudioPrewarmTasks() {
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        textAudioPrewarmTasks.removeAll()
    }

    private func generatedTextAudioDirectory() throws -> URL {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesDirectory.appending(path: "GeneratedTextAudio", directoryHint: .isDirectory)
    }

    private func prepareTextPlaybackBeforeStarting(itemId: String) -> Bool {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard shouldGatePreparedTextPlayback(for: item) else {
                return false
            }
            pendingPreparedTextStartItemId = itemId
            diagnostics["textAudioStartGate:\(itemId)"] = "waiting_for_prepared_media"
            if preparedTextAudioStatus != "failed" {
                preparedTextAudioStatus = "rendering"
                snapshot.preparedTextAudioStatus = "rendering"
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            selectedItem = try loadItemDetail(id: itemId, store: store)
            screen = .playback
            reportSuccess("Preparing generated audio for \(item.title).")
            return true
        } catch {
            reportFailure(error, context: "Prepare text playback failed")
            return true
        }
    }

    private func shouldGatePreparedTextPlayback(for item: Item) -> Bool {
        guard (audioPlaybackClientOverride == nil || forcePreparedTextGate),
              ttsVoiceSelection == .system,
              ttsMode != "kokoro",
              !liveSpeechFallbackItemIds.contains(item.id),
              shouldPrewarmTextAudio(for: item) else {
            return false
        }
        if item.media?.sourceType == .generatedTTSPrerendered {
            return false
        }
        return true
    }

    private enum TextAudioPrewarmRenderScope: Sendable {
        case starter(targetDurationMs: Int)
        case complete

        var priority: TaskPriority {
            switch self {
            case .starter:
                return .userInitiated
            case .complete:
                return .utility
            }
        }
    }

    private func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        if let audioPlaybackClientOverride {
            diagnostics["sessionTTS"] = "Test audio override"
            return audioPlaybackClientOverride
        }
        sanitizeTTSMode()
        let speech = try makeSpeechPlaybackClient()
        speechPlaybackClient = speech
        let routed = RoutedAudioPlaybackClient(
            speech: speech,
            media: makeMediaPlaybackClient()
        )
        streamingSpeechQueue.configureSpeechClient(routed)
        return routed
    }

    private func makeSpeechPlaybackClient() throws -> AudioPlaybackClient {
        let selectedVoice = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let appleVoiceIsAvailable = selectedVoice.isEmpty || Self.availableSpeechVoiceOptions().contains(where: { $0.id == selectedVoice })
        if ttsVoiceSelection == .system, !appleVoiceIsAvailable {
            diagnostics["speechVoiceAvailability"] = "unavailable"
            throw SessionKitError.persistenceFailed("selected_speech_voice_unavailable")
        }
        if let voice = ttsVoiceSelection.supertonicVoice {
            let renderer = try makeSupertonicRenderer()
            let supportDirectory = try applicationSupportDirectory()
            let diskCache: RenderedSpeechDiskCache
            if let renderedSpeechDiskCache {
                renderedSpeechDiskCache.setLimitBytes(renderedSpeechCacheLimitMB * 1024 * 1024)
                diskCache = renderedSpeechDiskCache
            } else {
                let created = try RenderedSpeechDiskCache(
                    directory: supportDirectory.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory),
                    limitBytes: renderedSpeechCacheLimitMB * 1024 * 1024
                )
                renderedSpeechDiskCache = created
                diskCache = created
            }
            diagnostics["sessionTTS"] = "Supertonic 3 INT8 \(voice.rawValue)"
            diagnostics["renderedSpeechCacheLimitMB"] = "\(renderedSpeechCacheLimitMB)"
            diagnostics["renderedSpeechCacheBytes"] = "\(diskCache.sizeBytes)"
            return SupertonicSpeechPlaybackClient(
                renderer: renderer,
                voice: voice,
                speed: Float(speechRate / 0.5),
                fallbackVoiceIdentifier: appleVoiceIsAvailable && !selectedVoice.isEmpty ? selectedVoice : nil,
                fallbackRate: Float(speechRate),
                diskCache: diskCache,
                onGenerationStateChange: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.onDeviceSpeechGenerationStatus = state.rawValue
                        self?.diagnostics["onDeviceSpeechGeneration"] = state.rawValue
                    }
                },
                onFallback: { [weak self] reason, offset in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.diagnostics["supertonicFallback"] = reason
                        self.diagnostics["supertonicFallbackOffset"] = "\(offset)"
                        self.statusMessage = "Using the iOS system voice for this playback."
                        self.feedbackEvent = UserFeedbackEvent(
                            kind: .warning,
                            message: "The on-device voice was unavailable, so playback continued with the iOS system voice."
                        )
                    }
                }
            )
        }
        #if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
        if ttsMode == "kokoro" {
            let supportDirectory = try applicationSupportDirectory()
            let cachesDirectory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            diagnostics["sessionTTS"] = "Kokoro bounded pre-render"
            let speech = KokoroSpeechPlaybackClient(
                applicationSupportDirectory: supportDirectory,
                outputDirectory: cachesDirectory.appending(path: "KokoroPlayback", directoryHint: .isDirectory),
                voiceName: kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName,
                speed: Float(speechRate / 0.5),
                cacheLimitBytes: kokoroCacheLimitBytes,
                maxCharacters: kokoroChunkCharacterLimit
            )
            return speech
        }
        #endif
        diagnostics["sessionTTS"] = "System speech"
        return SystemSpeechPlaybackClient(
            voiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
            speechRate: Float(speechRate)
        )
    }

    private func makeSupertonicRenderer() throws -> SupertonicNarrationRenderer {
        try verifyCurrentTermsForOnDeviceVoice()
        if let supertonicRenderer { return supertonicRenderer }
        guard let resourceRoot = Bundle.main.resourceURL?.appending(
            path: "Supertonic",
            directoryHint: .isDirectory
        ) else {
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: resourceRoot),
            outputDirectory: cachesDirectory.appending(path: "SupertonicPlayback", directoryHint: .isDirectory)
        )
        supertonicRenderer = renderer
        return renderer
    }

    private func makeMediaPlaybackClient() -> AudioPlaybackClient {
        let client = AVPlayerStreamPlaybackClient(
            preferredSkipBackSeconds: mediaSkipBackSeconds,
            preferredSkipForwardSeconds: mediaSkipForwardSeconds
        ) { [weak self] command, mediaTimeMs, playbackRate in
            Task { @MainActor [weak self] in
                self?.syncPlaybackProgressForLifecycle()
                self?.performGate2CompactCommand(
                    command,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: "now_playing"
                )
            }
        }
        mediaPlaybackClient = client
        return client
    }

    @discardableResult
    private func sanitizeTTSMode() -> Bool {
        let priorMode = ttsMode
        if ttsVoiceSelection.supertonicVoice != nil, !hasAcceptedCurrentTerms {
            ttsVoiceSelection = .system
        }
        synchronizeTTSModeFromSelection()
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        return priorMode != ttsMode
    }

    private func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listItems().map { item in
            let continuation = Self.preferredContinuationSession(in: try store.loadSessions(itemId: item.id))
            return LibraryItemRow(
                id: item.id,
                title: item.title,
                status: libraryStatusLabel(for: item),
                canDelete: true,
                hasContinuationSession: continuation != nil,
                continuationProgressPercent: continuation?.completionPercent
            )
        }
    }

    private func refreshBatchExportRows(store: SQLiteSessionStore) throws {
        let itemsById = Dictionary(uniqueKeysWithValues: try store.listItems().map { ($0.id, $0) })
        batchExportRows = try store.loadSessions().compactMap { session in
            guard let item = itemsById[session.itemId] else { return nil }
            let interjectionCount = try store.loadInterjections(sessionId: session.id)
                .filter { $0.status == "active" }
                .count
            return BatchSessionExportRow(
                session: session,
                itemTitle: item.title,
                interjectionCount: interjectionCount
            )
        }
        let availableIds = Set(batchExportRows.map(\.id))
        selectedBatchExportSessionIds.formIntersection(availableIds)
    }

    private func loadDeletedLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listDeletedItems().map { item in
            LibraryItemRow(id: item.id, title: item.title, status: "Recently deleted", canDelete: true)
        }
    }

    private func refreshLibraryRows(store: SQLiteSessionStore) throws {
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = try loadDeletedLibraryRows(store: store)
    }

    private func recoverInterruptedAIJobs(store: SQLiteSessionStore, rows: [LibraryItemRow]) throws {
        var recovered = 0
        for row in rows {
            for session in try store.loadSessions(itemId: row.id) {
                for var job in try store.loadAIJobs(sessionId: session.id) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = !remoteProviderExperienceEnabled
                        && job.providerType != "apple_foundation_on_device"
                    job.status = remoteJobDisabled ? "failed" : "retryable"
                    job.lastError = remoteJobDisabled
                        ? "remote_provider_disabled_by_feature_flag"
                        : "app_terminated_during_stream"
                    try store.updateAIJob(job)
                    if let turnId = job.turnId,
                       var turn = try store.loadTurns(sessionId: session.id).first(where: { $0.id == turnId && $0.status == "streaming" }) {
                        turn.status = "failed_partial"
                        try store.saveTurn(turn)
                    }
                    recovered += 1
                }
            }
        }
        diagnostics["recoveredInterruptedAIJobs"] = "\(recovered)"
    }

    private func libraryStatusLabel(for item: Item) -> String {
        guard item.status == "ready" else {
            switch item.status {
            case "needs_listening_map": return "Ready to listen · map optional"
            case "in_progress": return "In progress"
            case "finished": return "Finished"
            case "map_needs_repair": return "Listening map needs attention"
            default: return item.status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        if item.media != nil || item.mediaType == TargetType.transcriptBackedMedia.rawValue {
            return "Audio ready"
        }
        return "Ready to listen"
    }

    private func resolvedSourceLinkHandoffStore() throws -> SourceLinkHandoffStore {
        if let sourceLinkHandoffStore {
            return sourceLinkHandoffStore
        }
        return try SourceLinkHandoffStore.appGroup()
    }

    private func resolvedBrowserTextHandoffStore() throws -> Gate5BrowserTextHandoffStore {
        if let browserTextHandoffStore {
            return browserTextHandoffStore
        }
        return try Gate5BrowserTextHandoffStore.appGroup()
    }

    private func sourceLinkFailureMessage(status: String?, reason: String?, provider: String?) -> String {
        switch reason {
        case "spotify_audio_requires_provider_playback":
            if provider == "spotify" {
                return "Spoken Margins could not find a public audio file for this Spotify episode."
            }
            return "This provider did not expose a public audio file that Spoken Margins can play yet."
        case "spotify_metadata_unavailable":
            return "Spotify did not return enough episode metadata to search for a public copy."
        case "spotify_specific_episode_required":
            return "Open the specific episode in Spotify, tap Share, and send its episode link. Show or podcast-page links do not identify one episode."
        case "spotify_episode_not_found_on_apple":
            return "I could not find a confident Apple Podcasts match for this Spotify episode. It may be Spotify-only."
        case "spotify_episode_match_ambiguous":
            return "I found more than one Apple Podcasts episode with this title, so I did not risk importing the wrong one. Try sharing the specific Apple Podcasts episode or its RSS link."
        case "apple_episode_id_missing":
            return "That Apple Podcasts link did not identify a specific episode."
        case "apple_lookup_empty":
            return "Apple Podcasts did not return this episode from lookup, and I could not find a public audio stream on the Apple page."
        case "apple_audio_enclosure_not_found":
            return "Apple Podcasts did not expose a playable public audio stream for that episode."
        case "audio_enclosure_not_found":
            return "I found the page or feed, but not a playable podcast/audio file."
        case "rss_episode_ambiguous":
            return "I found the feed, but could not identify one episode to play."
        case "unsupported_link_type":
            return "That link is not a supported public podcast, RSS feed, or direct audio file."
        case "apple_lookup_failed":
            return "Apple Podcasts did not return a playable public audio file for that episode."
        case .some(let message):
            return message
        case .none:
            if status == LinkResolutionStatus.unsupported.rawValue {
                return "That link is not playable in Spoken Margins yet."
            }
            return "Source link needs review before it can be played."
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url).first
    }

    private func isUserImportedItem(_ id: String) -> Bool {
        id.hasPrefix("item-import-") || id.hasPrefix("item-obsidian-") || id.hasPrefix("item-browser-") || id.hasPrefix("item-source-")
    }

    private func submitProviderJobIfNeeded(kind: String, turnId: String, messages: [String], force: Bool = false) {
        guard remoteProviderExperienceEnabled else {
            markProviderFailure("remote_provider_disabled", userMessage: "Remote AI is disabled in this release.")
            return
        }
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.")
            screen = .settings
            return
        }
        guard aiDataSharingConsent == .grantedV1 else {
            pendingProviderJobForConsent = PendingProviderJob(kind: kind, turnId: turnId, messages: messages, force: true)
            isAIDataSharingConsentPresented = true
            reportSuccess("Review how live AI uses this source before continuing.")
            return
        }
        let selectedModel = modelForAIJob(kind: kind)
        recordModelForPendingJob(kind: kind, model: selectedModel)
        statusMessage = "Streaming \(selectedModel) for \(kind)."
        lastError = nil
        Task {
            var receivedText = false
            var automaticAttempts = 0
            var streamsSpeechImmediately: Bool?
            while automaticAttempts < 2 {
                do {
                    var completed = false
                    let stream = openAIResponsesClient.stream(
                        apiKey: providerAPIKey,
                        model: selectedModel,
                        instructions: systemPromptForAIJob(kind: kind),
                        messages: messages
                    )
                    for try await event in stream {
                        guard let engine else { return }
                        switch event {
                        case .started(let responseId):
                            diagnostics["lastOpenAIResponseId"] = responseId ?? "pending"
                            diagnostics["lastProviderTransport"] = "responses_sse"
                        case .textDelta(let delta):
                            receivedText = true
                            snapshot = try engine.aiStreamDelta(turnId: turnId, content: delta)
                            if streamsSpeechImmediately == nil {
                                streamsSpeechImmediately = !shouldDeferGeneratedTurnPlayback(turnId: turnId)
                            }
                            if streamsSpeechImmediately == true {
                                if snapshot.targetId != turnId {
                                    snapshot = try engine.activateStreamingTurn(turnId: turnId)
                                }
                                let stableUnits = snapshot.spokenUnits
                                streamingSpeechQueue.enqueue(stableUnits, turnId: turnId)
                                diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
                                diagnostics["streamingTurnId"] = turnId
                            }
                            refreshSelectedItem()
                        case .completed(let responseId):
                            diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
                            completed = true
                        }
                    }
                    guard completed else {
                        throw OpenAIResponsesError.api("OpenAI ended the stream before response.completed.")
                    }
                    guard let engine else { return }
                    snapshot = try engine.aiJobCompleted(turnId: turnId)
                    if streamsSpeechImmediately == true {
                        streamingSpeechQueue.enqueue(snapshot.spokenUnits, turnId: turnId)
                        completedStreamingTurnIds.insert(turnId)
                        diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
                        finishStreamingTurnIfReady(turnId)
                    } else {
                        let completedCurrentAudio = syncPlaybackProgressBeforeGeneratedTurnDecision(engine: engine)
                        try autoPlayCompletedTurn(
                            kind: kind,
                            turnId: turnId,
                            engine: engine,
                            completedCurrentAudio: completedCurrentAudio
                        )
                    }
                    refreshSelectedItem()
                    reportConfirmation(streamsSpeechImmediately == true
                        ? "Provider response saved and streamed to speech."
                        : "Provider response saved and queued after the current source.")
                    await generateAssistantChaptersIfUseful(turnId: turnId, model: selectedModel)
                    return
                } catch {
                    if !receivedText, automaticAttempts == 0 {
                        automaticAttempts += 1
                        diagnostics["providerAutomaticRetry"] = "before_first_delta"
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    markProviderFailure(String(describing: error), userMessage: receivedText ? "Provider stream stopped; the partial response was saved." : "Provider call failed.")
                    return
                }
            }
        }
    }

    private func submitLocalSummary(turnId: String, contexts: [String]) {
        statusMessage = "Summarizing interjections on device."
        lastError = nil
        Task {
            do {
                var partials: [String] = []
                for context in contexts {
                    partials.append(try await localFoundationModelClient.summarizeInterjections(context: context))
                }
                while partials.count > 1 {
                    var reduced: [String] = []
                    var start = 0
                    while start < partials.count {
                        let end = min(partials.count, start + 4)
                        let group = partials[start..<end]
                        let payload = group.enumerated().map { index, summary in
                            "PARTIAL \(index + 1):\n\(String(summary.prefix(1_200)))"
                        }.joined(separator: "\n\n")
                        reduced.append(try await localFoundationModelClient.summarizeInterjections(context: payload))
                        start = end
                    }
                    partials = reduced
                }
                guard let response = partials.first, !response.isEmpty else {
                    throw LocalFoundationModelError.emptyResponse
                }
                guard let engine else { return }
                snapshot = try engine.aiStreamDelta(turnId: turnId, content: response)
                snapshot = try engine.aiJobCompleted(turnId: turnId)
                let completedCurrentAudio = syncPlaybackProgressBeforeGeneratedTurnDecision(engine: engine)
                try autoPlayCompletedTurn(
                    kind: "interjection_summary",
                    turnId: turnId,
                    engine: engine,
                    completedCurrentAudio: completedCurrentAudio
                )
                diagnostics["lastSummaryMode"] = "apple_foundation_on_device"
                refreshSelectedItem()
                reportConfirmation("On-device summary saved and queued after the current source.")
            } catch {
                diagnostics["lastSummaryMode"] = "apple_foundation_failed"
                diagnostics["lastLocalSummaryErrorType"] = String(reflecting: type(of: error))
                markProviderFailure(
                    String(describing: error),
                    userMessage: "On-device summary failed: \(error.localizedDescription) Tap Retry Summary to try the model again."
                )
            }
        }
    }

    private func finishStreamingTurnIfReady(_ turnId: String) {
        guard completedStreamingTurnIds.contains(turnId),
              !streamingSpeechQueue.hasPendingSpeech(for: turnId),
              let engine else {
            return
        }
        do {
            snapshot = try engine.finishStreamingTurnPlayback(turnId: turnId)
            completedStreamingTurnIds.remove(turnId)
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            diagnostics["streamingTurnCompleted"] = turnId
            refreshSelectedItem()
        } catch {
            diagnostics["streamingTurnCompletionError"] = String(describing: error)
        }
    }

    private func syncPlaybackProgressBeforeGeneratedTurnDecision(engine: SessionEngine) -> Bool {
        let previousStatus = snapshot.status
        let previousTargetId = snapshot.targetId
        do {
            let updated = try engine.syncPlaybackProgress()
            if updated != snapshot {
                snapshot = updated
            }
            return previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
        } catch {
            diagnostics["playbackProgressSyncError"] = String(describing: error)
            return false
        }
    }

    private func generateAssistantChaptersIfUseful(turnId: String, model: String) async {
        guard remoteProviderExperienceEnabled,
              let sessionId = snapshot.sessionId,
              let store,
              let turn = try? store.loadTurns(sessionId: sessionId).first(where: { $0.id == turnId }),
              let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 240 else {
            return
        }
        do {
            let messages = [assistantChapterPrompt(responseText: text)]
            let response = try await openAIResponsesClient.complete(
                apiKey: providerAPIKey,
                model: model,
                instructions: "Return only strict JSON for assistant response chapters. Do not use Markdown.",
                messages: messages
            )
            let chapters = try assistantChapters(from: response, responseText: text)
            if let engine {
                snapshot = try engine.aiChaptersCompleted(turnId: turnId, chapters: chapters)
                refreshSelectedItem()
            }
            diagnostics["assistantChapters:\(turnId)"] = "complete:\(chapters.count)"
        } catch {
            diagnostics["assistantChapters:\(turnId)"] = "unavailable:\(error.localizedDescription)"
        }
    }

    private func assistantChapterPrompt(responseText: String) -> String {
        """
        Create 2 to 5 navigation chapters for the spoken response below. If it has fewer than two meaningful sections, return an empty chapters array.
        Return exactly {"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ch-1","title":"Short title","anchor":"exact phrase copied from RESPONSE"}]}.
        Every anchor must be an exact contiguous phrase from RESPONSE and identify the start of its section.
        RESPONSE:
        <<<
        \(responseText)
        >>>
        """
    }

    private func assistantChapters(from raw: String, responseText: String) throws -> [Chapter] {
        let data = Data(raw.utf8)
        let envelope = try JSONDecoder().decode(AssistantChapterEnvelope.self, from: data)
        guard envelope.schemaVersion == "assistant-response-map.v1" else {
            throw SessionKitError.persistenceFailed("assistant_chapter_schema")
        }
        var seen = Set<String>()
        return try envelope.chapters.map { candidate in
            guard !candidate.id.isEmpty,
                  !candidate.title.isEmpty,
                  seen.insert(candidate.id).inserted,
                  let range = responseText.range(of: candidate.anchor) else {
                throw SessionKitError.persistenceFailed("assistant_chapter_anchor")
            }
            let start = responseText.distance(from: responseText.startIndex, to: range.lowerBound)
            let end = responseText.distance(from: responseText.startIndex, to: range.upperBound)
            return Chapter(
                id: candidate.id,
                title: candidate.title,
                startChar: start,
                endChar: end,
                percent: responseText.isEmpty ? 0 : Int((Double(start) / Double(responseText.count) * 100).rounded())
            )
        }
    }

    private func callProvider(messages: [String], model: String, systemPrompt: String) async throws -> String {
        guard remoteProviderExperienceEnabled else {
            throw ProviderCallError.remoteProviderDisabled
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCallError.missingAPIKey
        }
        guard aiDataSharingConsent == .grantedV1 else {
            throw ProviderCallError.dataSharingConsentRequired
        }
        diagnostics["lastProviderRequestURL"] = OpenAIResponsesClient.endpoint.absoluteString
        diagnostics["lastProviderRequestStartedAt"] = "\(Date().timeIntervalSince1970)"
        diagnostics["lastProviderTransport"] = "responses_stream"
        var responseText = ""
        var completed = false
        for try await event in openAIResponsesClient.stream(
            apiKey: providerAPIKey,
            model: model,
            instructions: systemPrompt,
            messages: messages
        ) {
            switch event {
            case .started(let responseId):
                diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
            case .textDelta(let delta):
                responseText += delta
            case .completed(let responseId):
                diagnostics["lastOpenAIResponseId"] = responseId ?? diagnostics["lastOpenAIResponseId"]
                completed = true
            }
        }
        guard completed else {
            throw OpenAIResponsesError.api("OpenAI ended the Listening Map stream before response.completed.")
        }
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIResponsesError.emptyResponse }
        return trimmed
    }

    private func performProviderDataRequest(_ request: URLRequest, timeoutSeconds: TimeInterval = 30) async throws -> (Data, URLResponse) {
        guard remoteProviderExperienceEnabled else {
            throw ProviderCallError.remoteProviderDisabled
        }
        var timedRequest = request
        timedRequest.timeoutInterval = timeoutSeconds
        diagnostics["lastProviderRequestURL"] = timedRequest.url?.absoluteString ?? "none"
        diagnostics["lastProviderRequestStartedAt"] = "\(Date().timeIntervalSince1970)"
        return try await Self.performProviderDataRequestOffMain(timedRequest, timeoutSeconds: timeoutSeconds)
    }

    private nonisolated static func performProviderDataRequestOffMain(
        _ request: URLRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, URLResponse) {
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func makeChatCompletionsRequest(messages: [String], model: String, systemPrompt: String) -> URLRequest? {
        Gate1ProviderRequestFactory.makeChatCompletionsRequest(
            baseURL: providerBaseURL,
            apiKey: providerAPIKey,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )
    }

    private func modelForAIJob(kind: String) -> String {
        Gate1ProviderRequestFactory.modelForAIJob(
            kind: kind,
            listeningMapModel: listeningMapModel,
            summaryModel: summaryModel,
            conversationModel: conversationModel,
            fallbackProviderModel: fallbackProviderModel()
        )
    }

    private func fallbackProviderModel() -> String {
        let listeningMapFallback = listeningMapModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !listeningMapFallback.isEmpty {
            return listeningMapFallback
        }
        let storedFallback = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedFallback.isEmpty ? "gpt-5.6" : storedFallback
    }

    private func systemPromptForAIJob(kind: String) -> String {
        Gate1ProviderRequestFactory.systemPromptForAIJob(kind: kind)
    }

    private func recordModelForPendingJob(kind: String, model: String) {
        guard let sessionId = snapshot.sessionId,
              let store,
              var job = try? store.loadAIJobs(sessionId: sessionId).last(where: { $0.kind == kind && $0.status != "complete" }) else {
            return
        }
        job.model = model
        try? store.updateAIJob(job)
        diagnostics["last\(kind.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: ""))Model"] = model
    }

    private func decodeProviderText(_ data: Data) throws -> String {
        if let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
           let content = response.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if let raw = String(data: data, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw
        }
        throw ProviderCallError.emptyResponse
    }

    private func listeningMapPrompt(sourceText: String) -> String {
        """
        Create a Listening Map for the item content below.
        The user will listen to this content through text-to-speech, so the map must support quick navigation and situational awareness.
        Return only strict JSON. Use schemaVersion "listening-map.v1".
        Required object shape:
        {
          "schemaVersion": "listening-map.v1",
          "overview": "one or two sentence overview",
          "chapters": [
            {
              "id": "ch-1",
              "title": "short navigation title",
              "description": "what this chapter covers",
              "anchor": "exact contiguous phrase copied from ITEM CONTENT"
            }
          ]
        }
        Requirements: brief overview, navigable chapters, exact contiguous anchors copied from source, no invented anchors, no percent estimates, no start/end character offsets.
        JSON syntax rules: use ASCII double quotes for object keys and string delimiters. Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        Anchor quality rules: every anchor must be at least five words when possible; copy ordinary prose from the source, not headings; do not paraphrase; do not use ellipses.
        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    private func listeningMapRepairPrompt(sourceText: String, invalidResponse: String, error: String) -> String {
        """
        Repair the Listening Map JSON below. Return only strict JSON with schemaVersion "listening-map.v1".

        Parser/validator error:
        \(error)

        Requirements:
        - Keep only JSON. No Markdown fences.
        - Use ASCII double quotes for JSON object keys and string delimiters.
        - Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        - Every chapter must have id, title, description, and anchor.
        - Every anchor must be an exact contiguous phrase copied from ITEM CONTENT, preferably at least five words.
        - Do not include percent estimates.
        - Prefer preserving the previous chapter intent if the anchor can be fixed.

        INVALID RESPONSE:
        <<<
        \(invalidResponse)
        >>>

        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    private func markProviderFailure(_ error: String, userMessage: String) {
        do {
            if let engine {
                snapshot = try engine.aiProviderFailed(error: error)
                refreshSelectedItem()
            }
        } catch {
            diagnostics["providerFailurePersistence"] = String(describing: error)
        }
        providerProbeStatus = userMessage
        diagnostics["providerProbe"] = providerProbeStatus
        reportFailure(userMessage)
    }

    private func latestInterjectionNeedingTranscription() -> Interjection? {
        guard let sessionId = snapshot.sessionId,
              let interjections = try? store?.loadInterjections(sessionId: sessionId) else { return nil }
        return interjections.last { $0.transcriptionStatus == "pending" && $0.audioPath != nil }
    }

    private func scheduleSourceTranscriptImportIfAvailable(_ links: [SourceTranscriptLink], itemId: String) {
        guard !links.isEmpty else {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "no_links"
            return
        }
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.transcriptId == nil else { return }
        let sortedLinks = Self.prioritizedTranscriptLinks(links)
        diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "scheduled:\(sortedLinks.count)"
        diagnostics["sourceTranscriptionStatus"] = "downloading"
        sourceTranscriptStatus = "downloading"
        snapshot.sourceTranscriptStatus = "downloading"
        Task { [weak self, itemId, sortedLinks, durationMs = item.media?.durationMs] in
            guard let self else { return }
            var lastFailure = ""
            for link in sortedLinks {
                do {
                    let data = try await Self.fetchTranscriptLink(link)
                    if let timeline = try Self.transcriptTimeline(from: data, link: link, itemId: itemId, durationMs: durationMs),
                       !timeline.segments.isEmpty {
                        await MainActor.run {
                            self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "attached:\(link.type)"
                            self.attachSourceTranscriptTimeline(timeline, itemId: itemId)
                        }
                        return
                    }
                    lastFailure = "empty:\(link.type)"
                } catch {
                    lastFailure = "\(link.type):\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "unavailable:\(lastFailure)"
                self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                self.sourceTranscriptStatus = "unavailable"
                self.snapshot.sourceTranscriptStatus = "unavailable"
            }
        }
    }

    private static func prioritizedTranscriptLinks(_ links: [SourceTranscriptLink]) -> [SourceTranscriptLink] {
        links.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = transcriptLinkRank(lhs.element)
                let rhsRank = transcriptLinkRank(rhs.element)
                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }
                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func transcriptLinkRank(_ link: SourceTranscriptLink) -> Int {
        let value = "\(link.type) \(link.url) \(link.rel ?? "")".lowercased()
        if value.contains("vtt") || value.contains("webvtt") { return 0 }
        if value.contains("srt") || value.contains("subrip") { return 1 }
        if value.contains("json") { return 2 }
        if value.contains("plain") || value.contains(".txt") { return 3 }
        if value.contains("html") || value.contains(".htm") { return 4 }
        return 5
    }

    private static func fetchTranscriptLink(_ link: SourceTranscriptLink) async throws -> Data {
        guard let url = URL(string: link.url),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw SessionKitError.persistenceFailed("source_transcript_url_unsupported")
        }
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func transcriptTimeline(from data: Data, link: SourceTranscriptLink, itemId: String, durationMs: Int?) throws -> TranscriptTimeline? {
        let type = "\(link.type) \(link.url)".lowercased()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        if type.contains("vtt") || type.contains("srt") {
            return cueTranscriptTimeline(from: text, itemId: itemId, durationMs: durationMs)
        }
        if type.contains("json") {
            return jsonTranscriptTimeline(from: data, itemId: itemId, durationMs: durationMs)
        }
        let cleaned = type.contains("html") ? stripHTML(text) : text
        let normalized = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let endMs = max(1, durationMs ?? 1)
        return TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "transcript-\(itemId)-plain-0001",
                    startMs: 0,
                    endMs: endMs,
                    text: normalized
                )
            ],
            chapters: [],
            durationMs: durationMs ?? endMs
        )
    }

    private static func cueTranscriptTimeline(from text: String, itemId: String, durationMs: Int?) -> TranscriptTimeline {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var segments: [MediaTimelineSegment] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let startMs = parseCueTime(parts[0]),
                  let endMs = parseCueTime(parts[1]) else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-cue-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: body
            ))
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func jsonTranscriptTimeline(from data: Data, itemId: String, durationMs: Int?) -> TranscriptTimeline? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            entries = array
        } else if let dictionary = object as? [String: Any],
                  let nested = (dictionary["segments"] ?? dictionary["transcripts"] ?? dictionary["captions"]) as? [[String: Any]] {
            entries = nested
        } else if let dictionary = object as? [String: Any],
                  let text = dictionary["text"] as? String {
            let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let endMs = max(1, durationMs ?? 1)
            return TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "transcript-\(itemId)-json-0001", startMs: 0, endMs: endMs, text: normalized)],
                chapters: [],
                durationMs: durationMs ?? endMs
            )
        } else {
            return nil
        }
        var segments: [MediaTimelineSegment] = []
        for entry in entries {
            let body = (entry["text"] ?? entry["body"] ?? entry["caption"]) as? String ?? ""
            let text = body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = jsonTimeMs(entry["start"] ?? entry["startTime"] ?? entry["start_ms"] ?? entry["offset"]) ?? 0
            let explicitEndMs = jsonTimeMs(entry["end"] ?? entry["endTime"] ?? entry["end_ms"])
            let duration = jsonTimeMs(entry["duration"] ?? entry["durationMs"] ?? entry["duration_ms"])
            let endMs = explicitEndMs ?? duration.map { startMs + $0 } ?? max(startMs + 1, durationMs ?? startMs + 1)
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-json-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: text
            ))
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func parseCueTime(_ raw: String) -> Int? {
        let value = raw
            .split(separator: " ")
            .first?
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return Int(((hours * 3600) + (minutes * 60) + seconds) * 1000)
    }

    private static func jsonTimeMs(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        case let string as String:
            if string.contains(":") {
                return parseCueTime(string)
            }
            guard let double = Double(string) else { return nil }
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        default:
            return nil
        }
    }

    static func sanitizedBrowserTextHandoff(_ handoff: BrowserTextHandoff) -> BrowserTextHandoff {
        guard handoff.captureMode == .readablePage,
              handoff.text.range(of: #"<[^>]+>"#, options: .regularExpression) != nil else {
            return handoff
        }
        var sanitized = handoff
        sanitized.text = handoff.contentFormat == .markdown
            ? stripEmbeddedHTMLPreservingMarkdown(handoff.text)
            : stripHTML(handoff.text)
        sanitized.text = sanitized.text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    private static func stripEmbeddedHTMLPreservingMarkdown(_ markdown: String) -> String {
        var result = markdown
            .replacingOccurrences(
                of: #"<\s*(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b[^>]*>[\s\S]*?<\s*/\s*\1\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<\s*(source|img)\b[^>]*>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )

        for level in 1...6 {
            result = result
                .replacingOccurrences(
                    of: #"<\s*h\#(level)\b[^>]*>"#,
                    with: "\n\(String(repeating: "#", count: level)) ",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"<\s*/\s*h\#(level)\s*>"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                )
        }

        return result
            .replacingOccurrences(
                of: #"</?(p|div|section|article|li|br)\b[^>]*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<video[\s\S]*?</video>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<source[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</?(p|div|section|article|h[1-6]|li|br)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private func scheduleFullSourceTranscriptionForListeningMap(for item: Item, localSourceURL: URL? = nil) {
        guard item.transcriptId == nil,
              let sourceURLString = item.media?.url,
              let canonicalURL = URL(string: sourceURLString) else {
            return
        }
        let sourceURL = localSourceURL
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalURL
        guard sourceURL.isFileURL else {
            diagnostics["sourceTranscriptionStatus"] = "waiting_for_local_audio"
            return
        }
        diagnostics["sourceTranscriptionStatus"] = "transcribing"
        sourceTranscriptStatus = "transcribing"
        snapshot.sourceTranscriptStatus = "transcribing"
        statusMessage = "Transcribing source audio..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: sourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                await MainActor.run {
                    self.attachSourceTranscriptTimeline(timeline, itemId: item.id)
                }
            } catch {
                await MainActor.run {
                    self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                    self.diagnostics["sourceTranscriptionError"] = String(describing: error)
                    self.sourceTranscriptStatus = "unavailable"
                    self.snapshot.sourceTranscriptStatus = "unavailable"
                    if self.pendingMapGenerationItemId == item.id {
                        self.pendingMapGenerationItemId = nil
                    }
                    if self.lastError == nil {
                        self.statusMessage = "Audio ready. Source transcript and Listening Map are unavailable; notes will use timestamp context."
                    }
                }
            }
        }
    }

    private func attachSourceTranscriptTimeline(_ timeline: TranscriptTimeline, itemId: String) {
        let shouldGeneratePendingMap = pendingMapGenerationItemId == itemId
        run { engine in
            snapshot = try engine.attachTranscriptTimeline(itemId: itemId, timeline: timeline)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["sourceTranscriptionStatus"] = "complete"
            diagnostics["sourceTranscriptionItem"] = itemId
            sourceTranscriptStatus = "ready"
            snapshot.sourceTranscriptStatus = "ready"
        }
        if shouldGeneratePendingMap {
            pendingMapGenerationItemId = nil
            generateListeningMap()
        }
        retrySourceWindowContexts(itemId: itemId)
    }

    private func scheduleSourceWindowContextIfNeeded(for interjection: Interjection) {
        guard interjection.targetType == .item,
              let anchorMediaTimeMs = interjection.anchor.mediaTimeMs,
              let store,
              let item = try? store.loadItem(id: interjection.itemId),
              let sourceURLString = item.media?.url,
              let canonicalSourceURL = URL(string: sourceURLString) else {
            return
        }
        switch item.media?.sourceType {
        case .some(.nativeMediaFile), .some(.remoteStream):
            break
        default:
            return
        }
        if let storedTimeline = try? store.loadTranscriptTimeline(itemId: item.id)?.timeline,
           let window = Self.sourceContextWindow(
               from: storedTimeline,
               anchorMediaTimeMs: anchorMediaTimeMs,
               windowBeforeMs: sourceWindowContextBeforeMs,
               windowAfterMs: sourceWindowContextAfterMs
           ) {
            run { engine in
                snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, timeline: window)
                refreshSelectedItem()
                diagnostics["sourceWindowTranscription:\(interjection.id)"] = "complete:stored_transcript"
                diagnostics["sourceWindowContextProvenance:\(interjection.id)"] = "stored_transcript"
            }
            return
        }
        diagnostics["sourceWindowTranscription:\(interjection.id)"] = "scheduled"
        let transcriptionURL = podcastDownloadCoordinator?.validatedLocalURL(for: item.id) ?? canonicalSourceURL
        let provenance = transcriptionURL.isFileURL ? "downloaded_local_audio" : "bounded_remote_window"
        diagnostics["sourceWindowContextProvenance:\(interjection.id)"] = provenance
        pendingSourceContextInterjectionIds.insert(interjection.id)
        run { engine in
            snapshot = try engine.sourceWindowContextPending(interjectionId: interjection.id)
            refreshSelectedItem()
        }
        Task { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs, windowBeforeMs = sourceWindowContextBeforeMs, windowAfterMs = sourceWindowContextAfterMs] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudioWindow(
                    url: transcriptionURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: windowBeforeMs,
                    windowAfterMs: windowAfterMs
                )
                await MainActor.run {
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, timeline: timeline)
                        self.refreshSelectedItem()
                        self.diagnostics["sourceWindowTranscription:\(interjectionId)"] = "complete:speech_window"
                        self.diagnostics["sourceWindowContextProvenance:\(interjectionId)"] = provenance
                        self.pendingSourceContextInterjectionIds.remove(interjectionId)
                    }
                }
            } catch {
                await MainActor.run {
                    self.diagnostics["sourceWindowTranscription:\(interjectionId)"] = "failed:\(error.localizedDescription)"
                    self.diagnostics["sourceWindowContextProvenance:\(interjectionId)"] = "unavailable"
                    self.pendingSourceContextInterjectionIds.remove(interjectionId)
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjectionId)
                        self.refreshSelectedItem()
                    }
                    self.reportFailure("Podcast context could not be prepared. Retry the interjection or continue knowing source context is unavailable.")
                }
            }
        }
    }

    private func retrySourceWindowContexts(itemId: String) {
        guard let store else { return }
        let sessions = (try? store.loadSessions(itemId: itemId)) ?? []
        for session in sessions {
            let interjections = (try? store.loadInterjections(sessionId: session.id)) ?? []
            for interjection in interjections where interjection.targetType == .item
                && interjection.anchor.mediaTimeMs != nil
                && interjection.anchorContextStatus != .ready
                && !pendingSourceContextInterjectionIds.contains(interjection.id) {
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
        }
    }

    static func sourceContextWindow(
        from timeline: TranscriptTimeline,
        anchorMediaTimeMs: Int,
        windowBeforeMs: Int = 90_000,
        windowAfterMs: Int = 120_000
    ) -> TranscriptTimeline? {
        let startMs = max(0, anchorMediaTimeMs - windowBeforeMs)
        let endMs = min(timeline.durationMs ?? Int.max, anchorMediaTimeMs + windowAfterMs)
        let segments = timeline.segments.filter { segment in
            segment.endMs >= startMs && segment.startMs <= endMs
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: timeline.chapters.filter { $0.startMs >= startMs && $0.startMs <= endMs },
            durationMs: timeline.durationMs
        )
    }

    private func scheduleTranscription(for interjection: Interjection) {
        guard let audioPath = interjection.audioPath else { return }
        recordAnchorCaptureDiagnostics(for: interjection)
        diagnostics["interjectionAudioAtCapture:\(interjection.id)"] = interjectionAudioEvidence(for: audioPath)
        diagnostics["interjectionTranscription:\(interjection.id)"] = "scheduled"
        Task {
            do {
                let transcript = try await interjectionTranscriptionHandler(audioPath)
                await MainActor.run {
                    run { engine in
                        snapshot = try engine.transcriptionCompleted(interjectionId: interjection.id, transcript: transcript)
                        refreshSelectedItem()
                        diagnostics["interjectionTranscription:\(interjection.id)"] = "complete"
                        reportSuccess("Transcribed interjection.")
                    }
                    retryingInterjectionTranscriptionIds.remove(interjection.id)
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            } catch {
                await MainActor.run {
                    let failure = String(describing: error)
                    let wasRetry = retryingInterjectionTranscriptionIds.contains(interjection.id)
                    if wasRetry {
                        diagnostics["interjectionTranscription:\(interjection.id)"] = "retry_failed:\(failure)"
                        diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                        reportFailure("Saved audio and current transcript kept. Retranscription failed.")
                    } else {
                        run { engine in
                            snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, error: failure)
                            refreshSelectedItem()
                            diagnostics["interjectionTranscription:\(interjection.id)"] = "failed:\(failure)"
                            diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                            reportFailure("Audio saved. Transcript failed.")
                        }
                    }
                    retryingInterjectionTranscriptionIds.remove(interjection.id)
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            }
        }
    }

    private func interjectionAudioEvidence(for path: String) -> String {
        guard let url = resolvedInterjectionAudioURL(for: path) else {
            return "duration_ms=unknown;bytes=unknown"
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        #if canImport(AVFoundation)
        if let audioFile = try? AVAudioFile(forReading: url), audioFile.processingFormat.sampleRate > 0 {
            let durationMs = Int((Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1000).rounded())
            return "duration_ms=\(durationMs);bytes=\(bytes)"
        }
        #endif
        return "duration_ms=unknown;bytes=\(bytes)"
    }

    private func resolvedInterjectionAudioURL(for path: String) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path)
        if directURL.isFileURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        if path.hasPrefix("SpokenMargins/") {
            return support.appending(path: path)
        }
        if path.hasPrefix("interjections/") {
            return support.appending(path: "SpokenMargins").appending(path: path)
        }
        return support.appending(path: path)
    }

    private func recordAnchorCaptureDiagnostics(for interjection: Interjection) {
        diagnostics["interjectionAnchorAtCapture:\(interjection.id)"] = [
            "type=\(interjection.anchor.anchorType.rawValue)",
            "media_time=\(interjection.anchor.mediaTimeMs == nil ? "missing" : "present")",
            "segment=\(interjection.anchor.transcriptSegmentId == nil ? "missing" : "present")",
            "before=\(interjection.anchor.anchorBefore.isEmpty ? "missing" : "present")",
            "after=\(interjection.anchor.anchorAfter.isEmpty ? "missing" : "present")",
            "context=\(interjection.anchorContextStatus?.rawValue ?? "legacy")"
        ].joined(separator: ";")
    }

    private func summaryPrompt(interjections: [Interjection]) -> String {
        """
        I would like to have a session with you, the article, and my interjections below.
        \(sessionContextJSON(interjections: interjections, currentFollowUp: nil))
        """
    }

    private func localSummaryContexts(interjections: [Interjection]) -> [String] {
        let records: [[String: String]] = interjections.map { interjection in
            [
                "id": interjection.id,
                "anchorBefore": LocalInterjectionSummaryPolicy.boundedAnchorBefore(interjection.anchor.anchorBefore),
                "anchorAfter": LocalInterjectionSummaryPolicy.boundedAnchorAfter(interjection.anchor.anchorAfter),
                "note": String(LocalInterjectionSummaryPolicy.cleanSpokenNote(
                    interjection.cleanedTranscript ?? interjection.transcript ?? interjection.displayText ?? ""
                ).prefix(2_000))
            ]
        }
        var batches: [[[String: String]]] = []
        var current: [[String: String]] = []
        for record in records {
            let candidate = current + [record]
            if !current.isEmpty, encodedLocalSummaryContext(candidate).count > 6_500 {
                batches.append(current)
                current = [record]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches.map(encodedLocalSummaryContext)
    }

    private func encodedLocalSummaryContext(_ records: [[String: String]]) -> String {
        let payload: [String: Any] = [
            "schemaVersion": "local-interjection-summary.v1",
            "itemTitle": selectedItem.title,
            "interjections": records
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return records.enumerated().map { index, record in
                "\(index + 1). \(record["note"] ?? "")"
            }.joined(separator: "\n")
        }
        return json
    }

    private func conversationPrompt(followUp: String, explicitFollowUp: String, primaryInterjections: [Interjection]) -> String {
        let scopedInterjections = primaryInterjections.isEmpty ? currentDiscussionInterjections() : primaryInterjections
        return Gate1ProviderRequestFactory.conversationPrompt(
            followUp: followUp,
            contextJSON: sessionContextJSON(
                interjections: scopedInterjections,
                currentFollowUp: followUp,
                explicitFollowUp: explicitFollowUp,
                primaryInterjections: scopedInterjections
            )
        )
    }

    private func sessionContextJSON(
        interjections: [Interjection],
        currentFollowUp: String?,
        explicitFollowUp: String? = nil,
        primaryInterjections: [Interjection] = []
    ) -> String {
        let map: [String: Any] = [
            "schemaVersion": currentFollowUp == nil ? "session-export.v1" : "conversation-context.v2",
            "item": [
                "title": selectedItem.title,
                "text": selectedItem.text
            ],
            "listeningMap": [
                "overview": selectedItem.overview,
                "chapters": selectedItem.chapters.map { chapter in
                    [
                        "title": chapter.title,
                        "startChar": chapter.startChar,
                        "endChar": chapter.endChar
                    ]
                }
            ],
            "interjections": interjections.map { interjection in
                [
                    "targetType": interjection.targetType.rawValue,
                    "anchorBefore": interjection.anchor.anchorBefore,
                    "anchorAfter": interjection.anchor.anchorAfter,
                    "transcriptionStatus": interjection.transcriptionStatus,
                    "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                ]
            },
            "primaryUserIntent": currentFollowUp.map { followUp in
                [
                    "source": Gate1DiscussionContext.primaryIntentSource(
                        explicitFollowUp: explicitFollowUp ?? "",
                        currentInterjections: primaryInterjections
                    ),
                    "request": followUp,
                    "targetType": currentPlaybackTargetType,
                    "target": currentDiscussionTargetContext(),
                    "interjections": primaryInterjections.map { interjection in
                        [
                            "targetType": interjection.targetType.rawValue,
                            "anchorBefore": interjection.anchor.anchorBefore,
                            "anchorAfter": interjection.anchor.anchorAfter,
                            "transcriptionStatus": interjection.transcriptionStatus,
                            "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                        ]
                    }
                ] as [String: Any]
            } ?? NSNull(),
            "recentTurns": selectedItem.turns.suffix(6).map { turn in
                [
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "text": turn.summary ?? turn.text ?? turn.rawText ?? ""
                ]
            },
            "currentFollowUp": currentFollowUp.map { $0 as Any } ?? NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func currentDiscussionInterjections() -> [Interjection] {
        Gate1DiscussionContext.currentTargetInterjections(
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId,
            itemId: selectedItem.id
        )
    }

    private func currentDiscussionTargetContext() -> [String: Any] {
        let targetType = currentPlaybackTargetType
        let targetId = currentPlaybackTargetId ?? ""
        switch targetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            if let turn = selectedItem.turns.first(where: { $0.id == targetId }) {
                return [
                    "targetType": targetType,
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "summary": turn.summary ?? "",
                    "text": turn.text ?? turn.rawText ?? ""
                ]
            }
        default:
            break
        }
        return [
            "targetType": TargetType.itemTextTTS.rawValue,
            "title": selectedItem.title,
            "overview": selectedItem.overview
        ]
    }

    private func turnTitleText(_ turn: ConversationTurn) -> String {
        switch turn.turnType {
        case "interjection_summary":
            return "summary"
        case "assistant_response":
            return "AI response"
        default:
            return "turn"
        }
    }

    private func persistExportSettings() {
        UserDefaults.standard.set(exportFormat, forKey: "exportFormat")
        UserDefaults.standard.set(exportScope, forKey: "exportScope")
        UserDefaults.standard.set(exportIncludesSourceText, forKey: "exportIncludesSourceText")
        UserDefaults.standard.set(exportIncludesReference, forKey: "exportIncludesReference")
        UserDefaults.standard.set(exportIncludesListeningMap, forKey: "exportIncludesListeningMap")
        UserDefaults.standard.set(exportIncludesInterjections, forKey: "exportIncludesInterjections")
        UserDefaults.standard.set(exportIncludesTurns, forKey: "exportIncludesTurns")
    }

    private func currentExportOptions() -> ExportOptions {
        currentExportOptions(sessionId: exportSessionId)
    }

    private func currentExportOptions(sessionId: String?) -> ExportOptions {
        ExportOptions(
            sessionId: sessionId,
            includeFullText: exportIncludesSourceText,
            includeReference: exportIncludesReference,
            includeListeningMap: exportIncludesListeningMap,
            includeInterjections: exportIncludesInterjections,
            includeTurns: exportIncludesTurns,
            scope: exportScope
        )
    }

    private func renderExport(_ export: SessionExport, format: String? = nil) throws -> String {
        if (format ?? exportFormat) == "json" {
            let data = try encoder.encode(export)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return SessionExportMarkdownRenderer.render(export)
    }

    private func prepareIndividualMarkdownExportFile(markdown: String, export: SessionExport) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsSessionShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let exportFileURL, exportFileURL.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: exportFileURL)
        }
        let session = try store?.loadSession(id: export.session.id)
        return try SessionMarkdownFileWriter().write(
            markdown: markdown,
            itemTitle: export.item.title,
            sessionDate: session?.createdAt ?? session?.updatedAt,
            sessionId: export.session.id,
            to: directory
        )
    }

    private func resolvedBatchExportFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: batchExportFolderBookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: quickAccessBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshed = try url.bookmarkData(
                    options: quickAccessBookmarkCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: batchExportFolderBookmarkKey)
            }
            return url
        } catch {
            diagnostics["batchExportBookmarkError"] = String(describing: error)
            return nil
        }
    }

    private func resolvedQuickAccessFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: quickAccessFolderBookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: quickAccessBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshed = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: quickAccessFolderBookmarkKey)
            }
            return url
        } catch {
            diagnostics["quickAccessBookmarkError"] = String(describing: error)
            return nil
        }
    }

    private var quickAccessBookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private var quickAccessBookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private func obsidianItemId(fileName: String, index: Int) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "item-obsidian-\(Int(Date().timeIntervalSince1970))-\(index)-\(base.isEmpty ? "clip" : base)"
    }

    private func parseListeningMapJSON(_ raw: String, item: Item) throws -> ListeningMap {
        let trimmed = repairedJSONObjectString(from: raw)
        guard !trimmed.isEmpty else {
            throw ManualListeningMapError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ManualListeningMapError.invalidUTF8
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManualListeningMapError.jsonParseFailed(String(describing: error))
        }
        guard let root = parsed as? [String: Any] else {
            throw ManualListeningMapError.rootMustBeObject
        }
        guard root["schemaVersion"] as? String == "listening-map.v1" else {
            throw ManualListeningMapError.invalidSchema
        }
        guard let overview = root["overview"] as? String,
              !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualListeningMapError.missingOverview
        }
        guard let rawChapters = root["chapters"] as? [[String: Any]], !rawChapters.isEmpty else {
            throw ManualListeningMapError.missingChapters
        }
        guard let text = item.text, !text.isEmpty else {
            throw ManualListeningMapError.itemHasNoText
        }

        var ids = Set<String>()
        let chapters = try rawChapters.map { chapterObject in
            guard let id = chapterObject["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterId
            }
            guard ids.insert(id).inserted else {
                throw ManualListeningMapError.duplicateChapterId(id)
            }
            guard let title = chapterObject["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterTitle(id)
            }
            guard let description = chapterObject["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterDescription(id)
            }
            if let start = chapterObject["startChar"] as? Int,
               let end = chapterObject["endChar"] as? Int {
                return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
            }
            guard let anchor = (chapterObject["anchor"] as? String) ?? (chapterObject["anchorText"] as? String),
                  !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterAnchor(id)
            }
            let range = try resolveAnchor(anchor, in: text, chapterId: id)
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
        }
        .sorted { lhs, rhs in
            if lhs.startChar == rhs.startChar {
                return lhs.id < rhs.id
            }
            return lhs.startChar < rhs.startChar
        }

        return ListeningMap(
            id: "map-\(item.id)-manual",
            itemId: item.id,
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters
        )
    }

    private func repairedJSONObjectString(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last {
            text = String(text[first...last])
        }
        text = normalizingJSONDelimitersOutsideStrings(in: text)
        text = removingJSONCommentsOutsideStrings(from: text)
        text = escapingControlCharactersInsideJSONStringLiterals(in: text)
        text = text
            .replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizingJSONDelimitersOutsideStrings(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "\"" || scalar == "“" || scalar == "”" {
                output += "\""
                inString = true
            } else {
                output.unicodeScalars.append(scalar)
            }
        }

        return output
    }

    private func removingJSONCommentsOutsideStrings(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0
        var inString = false
        var escaped = false

        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                inString = true
                output.unicodeScalars.append(scalar)
                index += 1
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                index += 2
                while index < scalars.count, scalars[index] != "\n" {
                    index += 1
                }
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            } else {
                output.unicodeScalars.append(scalar)
                index += 1
            }
        }

        return output
    }

    private func escapingControlCharactersInsideJSONStringLiterals(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                if escaped {
                    output.unicodeScalars.append(scalar)
                    escaped = false
                } else if scalar == "\\" {
                    output.unicodeScalars.append(scalar)
                    escaped = true
                } else if scalar == "\"" {
                    output.unicodeScalars.append(scalar)
                    inString = false
                } else if scalar.value < 0x20 {
                    switch scalar {
                    case "\n":
                        output += "\\n"
                    case "\r":
                        output += "\\r"
                    case "\t":
                        output += "\\t"
                    default:
                        output += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    inString = true
                }
            }
        }

        return output
    }

    private func validatedChapter(id: String, title: String, start: Int, end: Int, text: String) throws -> Chapter {
        guard start >= 0, end > start, end <= text.count else {
            throw ManualListeningMapError.invalidChapterRange(id)
        }
        let percent = text.isEmpty ? 0 : Int((Double(start) / Double(text.count)) * 100)
        return Chapter(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startChar: start,
            endChar: end,
            percent: min(100, max(0, percent))
        )
    }

    private func resolveAnchor(_ anchor: String, in text: String, chapterId: String) throws -> Range<String.Index> {
        let trimmedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = text.range(of: trimmedAnchor) {
            return exact
        }
        if let folded = text.range(of: trimmedAnchor, options: [.caseInsensitive, .diacriticInsensitive]) {
            return folded
        }
        if let normalized = normalizedAnchorRange(trimmedAnchor, in: text) {
            return normalized
        }
        if let ngram = ngramAnchorRange(trimmedAnchor, in: text) {
            return ngram
        }
        throw ManualListeningMapError.anchorNotFound(chapterId)
    }

    private func ngramAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let words = anchor
            .replacingOccurrences(of: #"[^A-Za-z0-9']+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard words.count >= 5 else { return nil }
        let maxWindow = min(12, words.count)
        for size in stride(from: maxWindow, through: 5, by: -1) {
            guard words.count >= size else { continue }
            for start in 0...(words.count - size) {
                let phrase = words[start..<(start + size)].joined(separator: " ")
                if let range = normalizedAnchorRange(phrase, in: text) {
                    return range
                }
            }
        }
        return nil
    }

    private func normalizedAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let source = normalizedSearchIndex(for: text)
        let target = normalizedSearchIndex(for: anchor).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let range = source.text.range(of: target) else { return nil }
        let lowerOffset = source.text.distance(from: source.text.startIndex, to: range.lowerBound)
        let upperOffset = source.text.distance(from: source.text.startIndex, to: range.upperBound)
        guard lowerOffset < source.indices.count, upperOffset > 0 else { return nil }
        let lower = source.indices[lowerOffset]
        let last = source.indices[min(source.indices.count - 1, upperOffset - 1)]
        let upper = text.index(after: last)
        return lower..<upper
    }

    private func normalizedSearchIndex(for text: String) -> (text: String, indices: [String.Index]) {
        var normalized = ""
        var indices: [String.Index] = []
        var lastWasSpace = true
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let folded = String(char).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if folded.range(of: #"^[A-Za-z0-9']+$"#, options: .regularExpression) != nil {
                normalized.append(folded.lowercased())
                indices.append(index)
                lastWasSpace = false
            } else if !lastWasSpace {
                normalized.append(" ")
                indices.append(index)
                lastWasSpace = true
            }
            index = text.index(after: index)
        }
        if normalized.last == " " {
            normalized.removeLast()
            indices.removeLast()
        }
        return (normalized, indices)
    }

    private func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    /// Records a successful outcome and presents it only when the result is not
    /// otherwise apparent from the current interface.
    private func reportConfirmation(_ message: String) {
        reportSuccess(message)
        feedbackEvent = UserFeedbackEvent(kind: .success, message: message)
    }

    /// Presents degraded-but-successful behavior without styling it as either a
    /// normal confirmation or a failure.
    private func reportWarning(_ message: String) {
        statusMessage = message
        lastError = nil
        feedbackEvent = UserFeedbackEvent(kind: .warning, message: message)
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    private func reportFailure(_ error: Error, context: String? = nil) {
        let message: String
        if let urlError = error as? URLError, urlError.code == .timedOut {
            message = "The request timed out. Please try again."
        } else if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "))
    }

    private func reportFailure(_ message: String) {
        statusMessage = "Error"
        lastError = message
        feedbackEvent = UserFeedbackEvent(kind: .error, message: message)
        diagnostics["recentFailure"] = message
    }

    private func refreshSelectedItem() {
        guard let store, !activeItemId.isEmpty else { return }
        if let detail = try? loadItemDetail(id: activeItemId, store: store) {
            selectedItem = detail
        }
    }

    private func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard CommandLine.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] == nil,
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        _ = try engine.submitFollowup(text: "Can you respond to my interjection?")
        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: """
            <sm_summary>Here is a quick response to your interjection.</sm_summary>
            <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
            <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
            """
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")
        snapshot = try engine.inspectSession(sessionId: sessionId)
    }

    private func seedUITestingSummaryInterjectionIfNeeded(
        sessionId: String,
        engine: SessionEngine,
        store: SQLiteSessionStore
    ) throws {
        guard CommandLine.arguments.contains("--ui-testing"),
              let note = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_INTERJECTION"],
              try store.loadInterjections(sessionId: sessionId).isEmpty else { return }
        let interjection = Interjection(
            id: "ij-ui-summary",
            itemId: activeItemId,
            sessionId: sessionId,
            targetType: .item,
            targetId: activeItemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: snapshot.sourceProgressPercent,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: min(24, selectedItem.text.count),
                anchorBefore: String(selectedItem.text.prefix(120)),
                anchorAfter: ""
            ),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: note,
            cleanedTranscript: nil,
            displayText: note,
            status: "active",
            anchorContextStatus: .ready
        )
        try store.saveInterjection(interjection)
        snapshot = try engine.inspectSession(sessionId: sessionId)
        diagnostics["uiTestSummaryFixture"] = interjection.id
    }

    private func loadItemDetail(id: String, store: SQLiteSessionStore) throws -> ItemDetailState {
        let item = try store.loadItem(id: id)
        let map = try store.loadListeningMap(itemId: id)
        let mediaTimeline = try store.loadTranscriptTimeline(itemId: id)?.timeline
        let mediaChapters = mediaTimeline?.chapters ?? []
        let sessions = try store.loadSessions(itemId: id)
        let activeSessionId = snapshot.sessionId ?? sessions.first?.id
        let storedInterjections = activeSessionId.flatMap {
            try? store.loadInterjections(sessionId: $0).filter { $0.status == "active" }
        } ?? []
        let isNativeAudio = item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream
        let interjections = storedInterjections.map { interjection -> Interjection in
            guard isNativeAudio,
                  interjection.targetType == .item,
                  let mediaTimeMs = interjection.anchor.mediaTimeMs,
                  let mediaTimeline else {
                return interjection
            }
            var resolved = interjection
            if let context = SourceAnchorContextResolver.resolve(
                mediaTimeMs: mediaTimeMs,
                timeline: mediaTimeline
            ) {
                resolved.anchor.anchorBefore = context.anchorBefore
                resolved.anchor.anchorAfter = context.anchorAfter
                resolved.anchor.transcriptSegmentId = context.transcriptSegmentId
                resolved.anchor.startChar = context.startChar
                resolved.anchor.endChar = context.endChar
                resolved.anchorContextStatus = .ready
            } else {
                resolved.anchor.anchorBefore = ""
                resolved.anchor.anchorAfter = ""
                resolved.anchor.transcriptSegmentId = nil
                resolved.anchor.startChar = 0
                resolved.anchor.endChar = 0
                resolved.anchorContextStatus = .unavailable
            }
            return resolved
        }
        let activeInterjectionIDs = Set(storedInterjections.map(\.id))
        let turns = (activeSessionId.flatMap { try? store.loadTurns(sessionId: $0) } ?? []).filter { turn in
            guard turn.turnType == "interjection_summary", !turn.sourceInterjectionIds.isEmpty else {
                return true
            }
            return Set(turn.sourceInterjectionIds).isSubset(of: activeInterjectionIDs)
        }
        let sessionRows = sessions.map { session in
            let notes = ((try? store.loadInterjections(sessionId: session.id)) ?? [])
                .filter { $0.status == "active" }
            return SessionPresentation(
                session: session,
                interjectionCount: notes.count,
                interjectionPreview: notes.reversed().compactMap { note in
                    let text = note.cleanedTranscript ?? note.transcript ?? note.displayText
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
                }.first
            )
        }
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            overview: map?.overview ?? "",
            chapters: map?.chapters ?? [],
            mediaChapters: mediaChapters,
            mediaDurationMs: item.media?.durationMs ?? mediaTimeline?.durationMs,
            isNativeAudio: isNativeAudio,
            sessions: sessions,
            sessionRows: sessionRows,
            interjections: interjections,
            turns: turns
        )
    }

    private func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let url = try databaseURL()
        if let backupURL = try archiveLegacyLibraryIfNeeded(at: url) {
            legacyLibraryResetNotice = "This beta starts with a fresh library. Your earlier test database was archived at \(backupURL.lastPathComponent)."
            diagnostics["legacyLibraryArchive"] = backupURL.path
        }
        let store = try SQLiteSessionStore(path: url.path)
        self.store = store
        try configurePodcastDownloads(store: store)
        return store
    }

    private func configurePodcastDownloads(store: SQLiteSessionStore) throws {
        podcastDownloadCoordinator?.shutdown()
        let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) ?? .defaultValue
        let coordinator = try PodcastDownloadCoordinator(
            store: store,
            applicationSupportDirectory: try applicationSupportDirectory(),
            cacheLimit: limit,
            monitorsNetwork: !Self.isRunningUnitTests,
            usesBackgroundSession: !Self.isRunningUnitTests
        )
        coordinator.onRecordChanged = { [weak self] record in
            guard let self else { return }
            podcastDownloadRecords[record.itemId] = record
            diagnostics["podcastDownload:\(record.itemId)"] = record.state.rawValue
        }
        coordinator.onLocalAssetReady = { [weak self] itemId, url in
            self?.podcastLocalAssetDidBecomeReady(itemId: itemId, url: url)
        }
        podcastDownloadCoordinator = coordinator
        podcastDownloadRecords = coordinator.recordsByItemId
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
    }

    func podcastLocalAssetDidBecomeReady(itemId: String, url: URL) {
        guard let engine, let store else { return }
        run { _ in
            snapshot = try engine.updatePlaybackTransport(itemId: itemId, playbackURL: url.absoluteString)
            refreshSelectedItem()
        }
        scheduleEmbeddedPublisherChapterImport(itemId: itemId, localURL: url)
        retrySourceWindowContexts(itemId: itemId)
        guard pendingMapGenerationItemId == itemId,
              let item = try? store.loadItem(id: itemId) else {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "not_requested"
            return
        }
        diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_for_listening_map"
        scheduleFullSourceTranscriptionForListeningMap(for: item, localSourceURL: url)
    }

    private func scheduleEmbeddedPublisherChapterImport(itemId: String, localURL: URL) {
        Task { @MainActor [weak self] in
            guard let collection = await EmbeddedPublisherChapterLoader.load(from: localURL),
                  let self,
                  let engine = self.engine else {
                self?.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "not_found"
                return
            }
            self.run { _ in
                self.snapshot = try engine.attachPublisherChapters(itemId: itemId, collection: collection)
                if self.activeItemId == itemId {
                    self.refreshSelectedItem()
                }
                self.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "imported_\(collection.chapters.count)"
            }
        }
    }

    private func schedulePodcastDownloadIfNeeded(itemId: String) {
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.media?.sourceType == .remoteStream,
              let rawURL = item.media?.url,
              let remoteURL = URL(string: rawURL) else { return }
        podcastDownloadCoordinator?.register(itemId: itemId, remoteURL: remoteURL)
    }

    private func preparePodcastPlayback(itemId: String) {
        guard let coordinator = podcastDownloadCoordinator else { return }
        coordinator.configureActiveItem(itemId)
        if let record = podcastDownloadRecords[itemId], record.state == .evicted,
           coordinator.networkTransport == .wifi,
           let remoteURL = URL(string: record.remoteURL) {
            coordinator.register(itemId: itemId, remoteURL: remoteURL)
        }
        guard let localURL = coordinator.validatedLocalURL(for: itemId) else { return }
        _ = try? engine?.updatePlaybackTransport(itemId: itemId, playbackURL: localURL.absoluteString)
    }

    private func archiveLegacyLibraryIfNeeded(at databaseURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path),
              SQLiteSessionStore.schemaVersion(atPath: databaseURL.path) == 1 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archiveDirectory = databaseURL
            .deletingLastPathComponent()
            .appending(path: "LegacyLibraryBackup")
            .appending(path: formatter.string(from: Date()))
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(
                at: source,
                to: archiveDirectory.appending(path: source.lastPathComponent)
            )
        }
        return archiveDirectory
    }

    private func databaseURL() throws -> URL {
        if let databaseURLOverride {
            return databaseURLOverride
        }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "SpokenMarginsGate1.sqlite")
    }

    private func loadFixtureItem(name: String) throws -> Item {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/items") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.item(at: url)
    }

    private func loadFixtureMap(name: String) throws -> ListeningMap {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/maps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.listeningMap(at: url)
    }

    private func loadProfile(id: String) throws -> RuntimeCapabilityProfile {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "fixtures/capabilities") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.profile(at: url)
    }

    #if SPOKEN_MARGINS_WATCH
    private func seedGate4WatchPackageFixture(store: SQLiteSessionStore) throws {
        guard let url = Bundle.main.url(forResource: "offline-package", withExtension: "json", subdirectory: "fixtures/watch") else {
            return
        }
        let package = try ContractFixtureLoader.watchAudioPackage(at: url)
        try store.saveWatchAudioPackage(package)
    }
    #endif
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct AssistantChapterEnvelope: Decodable {
    struct Candidate: Decodable {
        var id: String
        var title: String
        var anchor: String
    }

    var schemaVersion: String
    var chapters: [Candidate]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private enum ProviderCallError: Error, CustomStringConvertible {
    case http(Int, String)
    case emptyResponse
    case invalidURL
    case missingAPIKey
    case dataSharingConsentRequired
    case remoteProviderDisabled

    var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(240))"
        case .emptyResponse:
            return "empty_response"
        case .invalidURL:
            return "provider_url_invalid"
        case .missingAPIKey:
            return "provider_api_key_missing"
        case .dataSharingConsentRequired:
            return "ai_data_sharing_consent_required"
        case .remoteProviderDisabled:
            return "remote_provider_disabled"
        }
    }
}

private enum ManualListeningMapError: Error, CustomStringConvertible {
    case empty
    case invalidUTF8
    case rootMustBeObject
    case invalidSchema
    case missingOverview
    case missingChapters
    case itemHasNoText
    case missingChapterId
    case duplicateChapterId(String)
    case missingChapterTitle(String)
    case missingChapterDescription(String)
    case missingChapterAnchor(String)
    case anchorNotFound(String)
    case invalidChapterRange(String)
    case jsonParseFailed(String)

    var description: String {
        switch self {
        case .empty:
            return "manual_map_empty"
        case .invalidUTF8:
            return "manual_map_invalid_utf8"
        case .rootMustBeObject:
            return "manual_map_root_must_be_object"
        case .invalidSchema:
            return "manual_map_schemaVersion_must_be_listening-map.v1"
        case .missingOverview:
            return "manual_map_missing_overview"
        case .missingChapters:
            return "manual_map_missing_chapters"
        case .itemHasNoText:
            return "manual_map_item_has_no_text"
        case .missingChapterId:
            return "manual_map_missing_chapter_id"
        case .duplicateChapterId(let id):
            return "manual_map_duplicate_chapter_id:\(id)"
        case .missingChapterTitle(let id):
            return "manual_map_missing_chapter_title:\(id)"
        case .missingChapterDescription(let id):
            return "manual_map_missing_chapter_description:\(id)"
        case .missingChapterAnchor(let id):
            return "manual_map_missing_chapter_anchor:\(id)"
        case .anchorNotFound(let id):
            return "manual_map_anchor_not_found:\(id)"
        case .invalidChapterRange(let id):
            return "manual_map_invalid_chapter_range:\(id)"
        case .jsonParseFailed(let error):
            return "manual_map_json_parse_failed:\(error)"
        }
    }
}

#if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
private final class KokoroSpeechPlaybackClient: NSObject, AudioPlaybackClient, AVAudioPlayerDelegate, @unchecked Sendable {
    private let fallback = SystemSpeechPlaybackClient()
    private let applicationSupportDirectory: URL
    private let outputDirectory: URL
    private let voiceName: String
    private let speed: Float
    private let cacheLimitBytes: Int
    private let maxCharacters: Int
    private let renderQueue = DispatchQueue(label: "spoken-margins.kokoro.playback", qos: .userInitiated)
    private let lock = NSLock()

    private var preparedSourceText = ""
    private var player: AVAudioPlayer?
    private var generation = UUID()
    private var currentTargetId: String?
    private var currentStartOffset = 0
    private var currentChunkLength = 0
    private var currentChunkBoundary = KokoroChunkBoundary.hard
    private var fallbackIsActive = false
    private var completedTargetId: String?
    private var playbackComplete = false
    private var pendingStartTargetId: String?
    private var startedTargetId: String?
    private var playbackFailure: String?
    private var renderedCache: [Int: URL] = [:]
    private var inFlightOffsets = Set<Int>()
    private var pendingAutoplayOffset: Int?
    private var appIsActive = true
    #if canImport(UIKit)
    private var activityObservers: [NSObjectProtocol] = []
    #endif

    init(
        applicationSupportDirectory: URL,
        outputDirectory: URL,
        voiceName: String,
        speed: Float,
        cacheLimitBytes: Int,
        maxCharacters: Int = 360
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.outputDirectory = outputDirectory
        self.voiceName = voiceName
        self.speed = max(0.65, min(1.75, speed))
        self.cacheLimitBytes = cacheLimitBytes
        self.maxCharacters = maxCharacters
        super.init()
        configureAppActivityObservers()
    }

    deinit {
        #if canImport(UIKit)
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    func prepareSpeechText(_ text: String) throws -> String {
        lock.lock()
        preparedSourceText = text
        lock.unlock()
        return SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        guard let request = nextRequest(targetId: targetId, from: charOffset) else {
            markPlaybackFailure(targetId: targetId, reason: "kokoro_playback_text_empty")
            throw SessionKitError.invalidCommandForState("kokoro_playback_text_empty")
        }
        enqueueRender(request)
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let isFallbackActive = fallbackIsActive
        lock.unlock()
        if isFallbackActive {
            return fallback.currentCharOffset()
        }
        lock.lock()
        let start = currentStartOffset
        let length = currentChunkLength
        let localPlayer = player
        lock.unlock()
        guard let localPlayer, localPlayer.duration > 0, length > 0 else {
            return start
        }
        let fraction = max(0, min(1, localPlayer.currentTime / localPlayer.duration))
        return start + Int((Double(length) * fraction).rounded(.down))
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let isFallbackActive = fallbackIsActive
        let isComplete = playbackComplete && completedTargetId == targetId
        lock.unlock()
        if isFallbackActive {
            return fallback.isPlaybackComplete(targetId: targetId)
        }
        return isComplete
    }

    func pause() throws {
        player?.pause()
        try fallback.pause()
    }

    func stop() throws {
        lock.lock()
        generation = UUID()
        player?.stop()
        player = nil
        fallbackIsActive = false
        renderedCache.removeAll()
        inFlightOffsets.removeAll()
        pendingAutoplayOffset = nil
        completedTargetId = nil
        playbackComplete = false
        pendingStartTargetId = nil
        startedTargetId = nil
        playbackFailure = nil
        lock.unlock()
        try fallback.stop()
    }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        lock.lock()
        let failed = currentTargetId == targetId ? playbackFailure : nil
        let isStarted = startedTargetId == targetId || (currentTargetId == targetId && player != nil)
        let isPending = pendingStartTargetId == targetId || pendingAutoplayOffset != nil || !inFlightOffsets.isEmpty
        lock.unlock()
        if let failed {
            return .failed(failed)
        }
        if isStarted {
            return .confirmed
        }
        return isPending ? .pending : .confirmed
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        lock.lock()
        let nextOffset = currentStartOffset + max(1, currentChunkLength)
        let targetId = currentTargetId
        let sourceCount = preparedSourceText.count
        let cachedURL = renderedCache.removeValue(forKey: nextOffset)
        let transitionDelay = currentChunkBoundary.transitionDelay
        let requestId = generation
        lock.unlock()
        guard let targetId,
              nextOffset < sourceCount,
              let request = renderRequest(targetId: targetId, startOffset: nextOffset, id: requestId) else {
            lock.lock()
            currentStartOffset = sourceCount
            currentChunkLength = 0
            completedTargetId = targetId
            playbackComplete = true
            lock.unlock()
            return
        }
        if let cachedURL {
            playRenderedAudio(cachedURL, request: request, delay: transitionDelay)
        } else {
            lock.lock()
            pendingAutoplayOffset = nextOffset
            lock.unlock()
            enqueueRender(request, shouldPlayWhenReady: false)
        }
    }

    private struct RenderRequest: Sendable {
        var id: UUID
        var targetId: String
        var startOffset: Int
        var sourceLength: Int
        var text: String
        var boundary: KokoroChunkBoundary
    }

    private func nextRequest(targetId: String, from charOffset: Int) -> RenderRequest? {
        lock.lock()
        let source = preparedSourceText
        generation = UUID()
        let requestId = generation
        player?.stop()
        player = nil
        fallbackIsActive = false
        renderedCache.removeAll()
        inFlightOffsets.removeAll()
        pendingAutoplayOffset = nil
        completedTargetId = nil
        playbackComplete = false
        pendingStartTargetId = targetId
        startedTargetId = nil
        playbackFailure = nil
        currentTargetId = targetId
        lock.unlock()

        return renderRequest(targetId: targetId, startOffset: charOffset, id: requestId, source: source)
    }

    private func renderRequest(targetId: String, startOffset: Int, id: UUID, source: String? = nil) -> RenderRequest? {
        let source = source ?? currentPreparedSourceText()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clampedOffset = max(0, min(startOffset, source.count))
        guard clampedOffset < source.count else { return nil }
        let slice = kokoroSourceSlice(from: source, startOffset: clampedOffset, maxCharacters: maxCharacters)
        guard !slice.text.isEmpty, slice.sourceLength > 0 else { return nil }
        return RenderRequest(
            id: id,
            targetId: targetId,
            startOffset: clampedOffset,
            sourceLength: slice.sourceLength,
            text: slice.text,
            boundary: slice.boundary
        )
    }

    private func currentPreparedSourceText() -> String {
        lock.lock()
        let source = preparedSourceText
        lock.unlock()
        return source
    }

    private func enqueueRender(_ request: RenderRequest, shouldPlayWhenReady: Bool = true) {
        guard canSubmitKokoroRender() else {
            markPlaybackFailureIfRequired(request: request, shouldPlayWhenReady: shouldPlayWhenReady, reason: "kokoro_render_unavailable")
            renderFailed(request: request)
            return
        }
        lock.lock()
        if renderedCache[request.startOffset] != nil || inFlightOffsets.contains(request.startOffset) {
            if !shouldPlayWhenReady {
                lock.unlock()
                return
            }
        }
        inFlightOffsets.insert(request.startOffset)
        lock.unlock()

        renderQueue.async { [weak self, applicationSupportDirectory, outputDirectory, voiceName, speed, cacheLimitBytes] in
            guard let self else { return }
            guard self.canSubmitKokoroRender() else {
                DispatchQueue.main.async {
                    self.markPlaybackFailureIfRequired(request: request, shouldPlayWhenReady: shouldPlayWhenReady, reason: "kokoro_render_unavailable")
                    self.renderFailed(request: request)
                }
                return
            }
            do {
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportDirectory)
                guard let modelURL = assets.modelURL else { throw KokoroNarrationError.missingModel }
                guard let voicesURL = assets.voicesURL else { throw KokoroNarrationError.missingVoices }
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                let before = KokoroNarrationRenderer.memorySnapshot()
                let preview = request.text
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .prefix(120)
                NSLog(
                    "SpokenMargins Kokoro render start target=%@ offset=%d chars=%d boundary=%@ configured=%@ before=%@ text=\"%@\"",
                    request.targetId,
                    request.startOffset,
                    request.sourceLength,
                    request.boundary.rawValue,
                    configured.description,
                    before.description,
                    String(preview)
                )
                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )
                guard self.canSubmitKokoroRender() else {
                    DispatchQueue.main.async {
                        self.markPlaybackFailureIfRequired(request: request, shouldPlayWhenReady: shouldPlayWhenReady, reason: "kokoro_render_unavailable")
                        self.renderFailed(request: request)
                    }
                    return
                }
                let renderSpeed = Self.currentKokoroSpeed(defaultSpeed: speed)
                let result = try renderer.render(
                    text: request.text,
                    itemId: request.targetId,
                    chunkId: "offset-\(request.startOffset)",
                    voiceName: voiceName,
                    speed: renderSpeed
                )
                let after = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog(
                    "SpokenMargins Kokoro render finish target=%@ offset=%d duration=%.2f tokens=%d speed=%.2f after=%@ final=%@",
                    request.targetId,
                    request.startOffset,
                    result.duration,
                    result.tokenCount,
                    renderSpeed,
                    after.description,
                    final.description
                )
                DispatchQueue.main.async {
                    self.renderCompleted(audioURL: result.audioURL, request: request, shouldPlayWhenReady: shouldPlayWhenReady)
                }
            } catch {
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog(
                    "SpokenMargins Kokoro render failed target=%@ offset=%d error=%@ final=%@",
                    request.targetId,
                    request.startOffset,
                    error.localizedDescription,
                    final.description
                )
                DispatchQueue.main.async {
                    self.markPlaybackFailureIfRequired(request: request, shouldPlayWhenReady: shouldPlayWhenReady, reason: "kokoro_render_failed")
                    self.renderFailed(request: request)
                }
            }
        }
    }

    private func renderCompleted(audioURL: URL, request: RenderRequest, shouldPlayWhenReady: Bool) {
        lock.lock()
        inFlightOffsets.remove(request.startOffset)
        guard generation == request.id else {
            lock.unlock()
            return
        }
        let shouldAutoplay = shouldPlayWhenReady || pendingAutoplayOffset == request.startOffset
        if shouldAutoplay {
            pendingAutoplayOffset = nil
        } else {
            renderedCache[request.startOffset] = audioURL
        }
        lock.unlock()

        if shouldAutoplay {
            playRenderedAudio(audioURL, request: request)
        }
    }

    private func renderFailed(request: RenderRequest) {
        lock.lock()
        inFlightOffsets.remove(request.startOffset)
        if pendingAutoplayOffset == request.startOffset {
            pendingAutoplayOffset = nil
        }
        lock.unlock()
    }

    private func playRenderedAudio(_ audioURL: URL, request: RenderRequest, delay: TimeInterval = 0) {
        lock.lock()
        guard generation == request.id else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            try fallback.stop()
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let nextPlayer = try AVAudioPlayer(contentsOf: audioURL)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            lock.lock()
            player = nextPlayer
            currentTargetId = request.targetId
            currentStartOffset = request.startOffset
            currentChunkLength = request.sourceLength
            currentChunkBoundary = request.boundary
            fallbackIsActive = false
            pendingStartTargetId = nil
            startedTargetId = request.targetId
            playbackFailure = nil
            lock.unlock()
            if delay > 0 {
                nextPlayer.play(atTime: nextPlayer.deviceCurrentTime + delay)
            } else {
                nextPlayer.play()
            }
            prefetchNextChunk(after: request)
        } catch {
            markPlaybackFailure(request: request, reason: "kokoro_playback_failed")
        }
    }

    private func prefetchNextChunk(after request: RenderRequest) {
        let nextOffset = request.startOffset + max(1, request.sourceLength)
        lock.lock()
        let sourceCount = preparedSourceText.count
        let targetId = currentTargetId
        let currentGeneration = generation
        lock.unlock()
        guard currentGeneration == request.id,
              let targetId,
              nextOffset < sourceCount,
              let nextRequest = renderRequest(targetId: targetId, startOffset: nextOffset, id: currentGeneration) else {
            return
        }
        enqueueRender(nextRequest, shouldPlayWhenReady: false)
    }

    private func configureAppActivityObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        activityObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(true)
        })
        activityObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(false)
        })
        activityObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(false)
        })
        #endif
    }

    private func setAppIsActive(_ isActive: Bool) {
        lock.lock()
        appIsActive = isActive
        if !isActive {
            renderedCache.removeAll()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
        }
        lock.unlock()
    }

    private func canSubmitKokoroRender() -> Bool {
        lock.lock()
        let isActive = appIsActive
        lock.unlock()
        return isActive
    }

    private static func currentKokoroSpeed(defaultSpeed: Float) -> Float {
        let storedRate = UserDefaults.standard.double(forKey: "speechRate")
        guard storedRate > 0 else { return defaultSpeed }
        return Float(max(0.65, min(1.75, storedRate / 0.5)))
    }

    private func markPlaybackFailure(request: RenderRequest, reason: String) {
        lock.lock()
        guard generation == request.id else {
            lock.unlock()
            return
        }
        currentTargetId = request.targetId
        currentStartOffset = request.startOffset
        currentChunkLength = 0
        fallbackIsActive = false
        pendingStartTargetId = nil
        startedTargetId = nil
        playbackFailure = reason
        lock.unlock()
    }

    private func markPlaybackFailureIfRequired(request: RenderRequest, shouldPlayWhenReady: Bool, reason: String) {
        lock.lock()
        let isAwaitedAutoplay = pendingAutoplayOffset == request.startOffset
        lock.unlock()
        guard shouldPlayWhenReady || isAwaitedAutoplay else { return }
        markPlaybackFailure(request: request, reason: reason)
    }

    private func markPlaybackFailure(targetId: String, reason: String) {
        lock.lock()
        currentTargetId = targetId
        currentChunkLength = 0
        fallbackIsActive = false
        pendingStartTargetId = nil
        startedTargetId = nil
        playbackFailure = reason
        lock.unlock()
    }
}
#endif

private enum KokoroChunkBoundary: String, Sendable {
    case sentence
    case comma
    case whitespace
    case hard

    var transitionDelay: TimeInterval {
        switch self {
        case .sentence:
            return 0.12
        case .comma:
            return 0.05
        case .whitespace, .hard:
            return 0
        }
    }
}

private struct KokoroSourceSlice: Sendable {
    var text: String
    var sourceLength: Int
    var boundary: KokoroChunkBoundary
}

private func kokoroRenderChunk(from text: String, maxCharacters: Int = 360) -> String {
    let trimmed = SpeechTextNormalizer.normalize(text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxCharacters else { return trimmed }

    let hardLimit = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
    let prefix = String(trimmed[..<hardLimit])
    return kokoroSelectChunkPrefix(prefix, maxCharacters: maxCharacters).text
}

private func kokoroSourceSlice(from source: String, startOffset: Int, maxCharacters: Int) -> KokoroSourceSlice {
    let clampedOffset = max(0, min(startOffset, source.count))
    let start = source.index(source.startIndex, offsetBy: clampedOffset)
    let remainingLength = source.distance(from: start, to: source.endIndex)
    let length = min(maxCharacters, remainingLength)
    let hardEnd = source.index(start, offsetBy: length)
    let prefix = String(source[start..<hardEnd])
    let selected = kokoroSelectChunkPrefix(prefix, maxCharacters: maxCharacters)
    return KokoroSourceSlice(
        text: selected.text,
        sourceLength: max(0, selected.sourceLength),
        boundary: selected.boundary
    )
}

private func kokoroSelectChunkPrefix(_ prefix: String, maxCharacters: Int) -> KokoroSourceSlice {
    let minimumUsefulLength = min(80, max(24, maxCharacters / 3))
    let sentenceCharacters = CharacterSet(charactersIn: ".!?\n;:")
    if let sentence = kokoroBoundary(in: prefix, characters: sentenceCharacters, includeBoundary: true, minimumUsefulLength: minimumUsefulLength) {
        return sentence.withBoundary(.sentence)
    }

    if let comma = kokoroBoundary(in: prefix, characters: CharacterSet(charactersIn: ","), includeBoundary: true, minimumUsefulLength: minimumUsefulLength) {
        return comma.withBoundary(.comma)
    }

    if let whitespace = kokoroBoundary(in: prefix, characters: .whitespacesAndNewlines, includeBoundary: false, minimumUsefulLength: minimumUsefulLength) {
        return whitespace.withBoundary(.whitespace)
    }

    let normalized = SpeechTextNormalizer.normalize(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
    return KokoroSourceSlice(text: normalized, sourceLength: prefix.count, boundary: .hard)
}

private func kokoroBoundary(in prefix: String, characters: CharacterSet, includeBoundary: Bool, minimumUsefulLength: Int) -> KokoroSourceSlice? {
    guard let range = prefix.rangeOfCharacter(from: characters, options: .backwards) else { return nil }
    let end = includeBoundary ? range.upperBound : range.lowerBound
    guard prefix.distance(from: prefix.startIndex, to: end) >= minimumUsefulLength else { return nil }
    let selected = String(prefix[..<end])
    let normalized = SpeechTextNormalizer.normalize(selected).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    let sourceLength = prefix.distance(from: prefix.startIndex, to: range.upperBound)
    return KokoroSourceSlice(text: normalized, sourceLength: sourceLength, boundary: .hard)
}

private extension KokoroSourceSlice {
    func withBoundary(_ boundary: KokoroChunkBoundary) -> KokoroSourceSlice {
        KokoroSourceSlice(text: text, sourceLength: sourceLength, boundary: boundary)
    }
}

private final class UnavailableSpeechPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    private let reason: String
    private var failedTargetId: String?

    init(reason: String) {
        self.reason = reason
    }

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        try fail(targetId: targetId)
    }

    func play(targetId: String, from charOffset: Int) throws {
        try fail(targetId: targetId)
    }

    func pause() throws {}

    func stop() throws {}

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        failedTargetId == targetId ? .failed(reason) : .confirmed
    }

    private func fail(targetId: String) throws {
        failedTargetId = targetId
        throw SessionKitError.invalidCommandForState(reason)
    }
}

#if targetEnvironment(simulator)
private final class FakeGeneratedSpeechPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var preparedText = ""
    private var currentOffsetValue = 0
    private var completedTargetId: String?
    private var playingTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        lock.lock()
        preparedText = normalized
        lock.unlock()
        return normalized
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        lock.lock()
        playingTargetId = targetId
        completedTargetId = nil
        currentOffsetValue = max(0, min(charOffset, preparedText.count))
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.playingTargetId == targetId {
                self.currentOffsetValue = self.preparedText.count
                self.completedTargetId = targetId
            }
            self.lock.unlock()
        }
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let offset = currentOffsetValue
        lock.unlock()
        return offset
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let complete = completedTargetId == targetId
        lock.unlock()
        return complete
    }

    func pause() throws {
        lock.lock()
        playingTargetId = nil
        lock.unlock()
    }

    func stop() throws {
        lock.lock()
        playingTargetId = nil
        completedTargetId = nil
        lock.unlock()
    }
}
#endif

#if canImport(AVFoundation)
private func voiceQualityName(_ voice: AVSpeechSynthesisVoice) -> String {
    if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
        switch voice.quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }
    return "Default"
}
#endif

enum KeychainStore {
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            return deleteStatus == errSecItemNotFound ? errSecSuccess : deleteStatus
        }
        let protectedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, protectedAttributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var addAttributes = query
        protectedAttributes.forEach { addAttributes[$0.key] = $0.value }
        return SecItemAdd(addAttributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
