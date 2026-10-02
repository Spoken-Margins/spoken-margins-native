import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
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
    case timeline
    case settings
    case offlineStorage
    case export
    case batchExport
}

@MainActor
final class Gate1AppModel: ObservableObject {
    static let welcomeSampleItemId = "item-spoken-margins-overview"
    static let guidedOnboardingItemId = "guided-onboarding"
    static let welcomeSampleSeedVersion = 2
    static let welcomeSampleSeedVersionKey = "welcomeSampleSeedVersion"
    static let onboardingStepsKey = "onboardingCompletedStepsV1"
    static let guidedOnboardingStageKey = "guidedOnboardingStageV1"
    static let guidedOnboardingSeedVersionKey = "guidedOnboardingSeedVersion"
    static let guidedOnboardingTombstoneKey = "guidedOnboardingTombstone"
    static let onboardingCardDismissedKey = "onboardingCardDismissedV1"
    static let dismissedQuickAccessFilesKey = "dismissedQuickAccessFilesV1"
    static let supertonicTTSMigrationKey = "supertonicTTSMigrationV1"
    static let supertonicVoicePendingTermsKey = "supertonicVoicePendingTermsV1"
    static let showsMixWithOtherAudioOptionKey = "showsMixWithOtherAudioOption"
    static let mixedPlaybackVolumeKey = "mixedPlaybackVolume"
    static let suppressedAudioPreparationItemIdsKey = "suppressedAudioPreparationItemIdsV1"
    static let mixedPlaybackVolumeMaximum = 1.0
    static let exportPreviewCharacterLimit = 24_000
    nonisolated static let supportedPlaybackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let privateSharingNoteCharacterLimit = 500
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    static var supportsSpeechVoiceEnumeration: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    static func makeApplicationModel() -> Gate1AppModel {
        if ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_RECORDING"] == "1" {
            return Gate1AppModel(recordingClient: NoopRecordingClient())
        }
        return Gate1AppModel()
    }

    @Published private var presentedScreen: Gate1Screen = .home
    @Published var requestedExperienceRoot: AppRoot?
    @Published var writtenMarginDraft: WrittenMarginDraft?
    @Published var recordingPermissionDenied = false
    @Published var marginCollectionQuery = MarginCollectionQuery()
    @Published var sharedMarginRows: [SharedMarginRow] = []
    var pendingVoiceCaptureRequestID: UUID?
    var screen: Gate1Screen {
        get { presentedScreen }
        set {
            guard !recordingNavigationIsLocked || newValue == .playback else {
                diagnostics["recordingNavigationGuard"] = "blocked_\(String(describing: newValue))"
                return
            }
            presentedScreen = newValue
        }
    }
    @Published var snapshot = SessionSnapshot() {
        didSet {
            recordPlaybackEventState(previous: oldValue)
            if playingImportedCommentary != nil,
               oldValue.sessionId != snapshot.sessionId || oldValue.itemId != snapshot.itemId
                || oldValue.targetId != snapshot.targetId || snapshot.status.isPlaybackActive {
                stopImportedCommentaryPlayback(resumeSource: false)
            }
            preparedTextAudioStatus = snapshot.preparedTextAudioStatus ?? preparedTextAudioStatus
            if let snapshotSourceTranscriptStatus = snapshot.sourceTranscriptStatus,
               !(sourceTranscriptStatus == "transcribing" && snapshotSourceTranscriptStatus == "not_started") {
                sourceTranscriptStatus = snapshotSourceTranscriptStatus
            }
            if oldValue.status.isPlaybackActive != snapshot.status.isPlaybackActive || oldValue.itemId != snapshot.itemId {
                if !canPrepareLibraryAudio {
                    foregroundAudioPreparationTask?.cancel()
                } else {
                    startForegroundAudioPreparationIfNeeded()
                }
            }
            reconcilePlaybackProgressTicker()
            reconcileTextPlaybackStartupBackgroundTask()
            updateSkimAvailability(refreshResources: false)
            updateGate2CompactState()
        }
    }
    var gate2CompactSnapshot: CompactControlSnapshot?
    let runtimeDiagnostics = RuntimeDiagnostics()
    @Published var developerDiagnosticRecordingEnabled = false {
        didSet { configureDeveloperDiagnosticRecording() }
    }
    let developerDiagnosticBuild = DeveloperDiagnosticRecording.buildIdentity
    var developerDiagnosticTask: Task<Void, Never>?
    let developerRecording = DeveloperDiagnosticRecording(fileURL:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeveloperDiagnostics/latest.json"))

    let playbackEventRecording = DeveloperDiagnosticRecording(
        limit: 300,
        fileURL: Gate1AppModel.isRunningUnitTests ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeveloperDiagnostics/playback-events.json"),
        automatic: true
    )
    var lastPlaybackEventCheckpoint: TimeInterval = 0

    @Published var statusMessage = "Ready."
    @Published var lastError: String?
    @Published var feedbackEvent: UserFeedbackEvent?
    @Published var itemFailures = ItemFailureLog()
    @Published var exportPreview = ""
    @Published var exportFileURL: URL?
    @Published var exportShareCandidates: [Interjection] = []
    @Published var exportSessionId: String?
    @Published var exportFormat = UserDefaults.standard.string(forKey: "exportFormat") ?? "markdown"
    @Published var exportScope = UserDefaults.standard.string(forKey: "exportScope") ?? "full_session"
    @Published var exportIncludesSourceText = UserDefaults.standard.object(forKey: "exportIncludesSourceText") as? Bool ?? false
    @Published var exportIncludesReference = UserDefaults.standard.object(forKey: "exportIncludesReference") as? Bool ?? true
    @Published var exportIncludesListeningMap = UserDefaults.standard.object(forKey: "exportIncludesListeningMap") as? Bool ?? true
    @Published var exportIncludesInterjections = UserDefaults.standard.object(forKey: "exportIncludesInterjections") as? Bool ?? true
    @Published var exportIncludesTurns = UserDefaults.standard.object(forKey: "exportIncludesTurns") as? Bool ?? true
    @Published var batchExportRows: [BatchSessionExportRow] = []
    @Published var batchExportFilter: BatchSessionExportFilter = .withInterjections
    @Published var selectedBatchExportSessionIds: Set<String> = []
    @Published var batchExportFolderName = UserDefaults.standard.string(forKey: "batchExportFolderName") ?? "No folder selected"
    @Published var batchExportResult: BatchSessionExportResult?
    @Published var isWritingBatchExport = false
    @Published var retryingInterjectionTranscriptionIds: Set<String> = []
    @Published var playingInterjectionAudioId: String?
    @Published var playingInterjectionAudioSessionID: String?
    @Published var playingInterjectionAudioRate: Double = 1
    var libraryPresentationRevision = 0
    var navigationRefreshTask: Task<Void, Never>?
    var navigationLibraryRead: @Sendable (SQLiteSessionStore) async throws -> LibraryReadSnapshot = { store in
        try await Task.detached(priority: .utility) { try LibraryReadSnapshot.read(store: store) }.value
    }
    var activePlaybackDetail: ItemDetailState?
    @Published var libraryItems: [LibraryItemRow] = [] {
        didSet { cachedQuickAddCandidates = nil; libraryPresentationRevision += 1 }
    }
    @Published var audioPreparationQueue: [AudioPreparationQueueRow] = []
    @Published var recentlyPreparedAudio: [RecentlyPreparedAudioRow] = []
    @Published var libraryQuery = LibraryQuery(
        contentType: LibraryContentTypeFilter(rawValue: UserDefaults.standard.string(forKey: "libraryContentTypeFilter") ?? "") ?? .all,
        listeningState: Gate1AppModel.loadLibraryListeningFilter(defaults: .standard),
        offlineState: LibraryOfflineStateFilter(rawValue: UserDefaults.standard.string(forKey: "libraryOfflineStateFilter") ?? "") ?? .all,
        sort: LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recentlyAdded
    )
    @Published var sleepTimerState: SleepTimerState = .inactive
    @Published var sleepTimerRemainingSeconds: Int?
    @Published var libraryAccessError: String?
    @Published var recentlyDeletedItems: [LibraryItemRow] = []
    @Published var completionUndo: (itemID: String, title: String, markedAt: Date)?
    @Published var trashUndo: TrashUndoState?
    @Published var selectedItem = ItemDetailState() {
        didSet {
            if selectedItem.id == snapshot.itemId { activePlaybackDetail = selectedItem }
            else if oldValue.id == snapshot.itemId { activePlaybackDetail = oldValue }
            if oldValue.id != selectedItem.id { selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: selectedItem.id) }
            skimResourceContext = nil
            if oldValue.id != selectedItem.id || oldValue.externalReference != selectedItem.externalReference {
                storedSourceFollowSuggestionCandidates = []
                sourceFollowSuggestionItemId = nil
            }
            // Every way to an item (Library, Safari import, Continue listening) looks for its feed (#280).
            if oldValue.id != selectedItem.id, let store {
                discoverFollowOfferIfEligible(itemId: selectedItem.id, store: store)
            }
        }
    }
    @Published var marginRows: [MarginRow] = []
    @Published var offlineStorageSnapshot = OfflineStorageSnapshot()
    @Published var recordingPresentationContext: RecordingPresentationContext?
    @Published var isRequestingRecordingPermission = false
    @Published var isFinishingInterjection = false
    @Published var isMarginCaptureCoolingDown = false
    @Published var isDismissingMiniPlayer = false
    @Published var requestedTimelineFocusMarginID: String?
    @Published var pastedAssistantResponse = ""
    @Published var sharingState = InterjectionSharingState()
    @Published var isSharingInterjectionsPresented = false
    @Published var sharedSpokenMarginsPackageURL: URL?
    @Published var isSharedSpokenMarginsPackagePresented = false
    @Published var spokenMarginsPackageImportReview: SpokenMarginsPackageImportReview?
    @Published var isImportingSpokenMarginsPackage = false
    @Published var spokenMarginsPackageImportError: String?
    @Published var pendingImportedCommentary: ImportedCommentaryPrompt? {
        didSet {
            if oldValue?.id != pendingImportedCommentary?.id {
                updateGate2CompactState()
            }
        }
    }
    @Published var playingImportedCommentary: ImportedCommentaryPrompt?
    @Published var importedCommentaryIsPaused = false
    let importedMarginRemoteControls = ImportedMarginRemoteControls()
    /// "Play this moment" (#159). The sequence is published for the playback screen; the conductor runs it.
    @Published var marginMoment: MarginMomentSequence?
    @Published var marginMomentVoiceIsPaused = false
    /// Whose Margin the moment is for ("Your Margin", "Cole's Margin"), and whether its position is only a guess.
    @Published var marginMomentTitle = "Your Margin"
    @Published var marginMomentPositionIsApproximate = false
    var marginMomentConductor: MarginMomentConductor?
    /// Heard audio around streamed Margins, written to temporary files until transcribed (#156). Keyed by margin identity.
    var heardSourceWindows: [String: [(url: URL, startMediaTimeMs: Int, durationMs: Int)]] = [:]

    @Published var quickAccessFolderName = UserDefaults.standard.string(forKey: "quickAccessFolderName") ?? "No folder selected"
    @Published var quickAccessRecentFiles: [QuickAccessFile] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published var dismissedQuickAccessFileKeys = Set(
        UserDefaults.standard.stringArray(forKey: Gate1AppModel.dismissedQuickAccessFilesKey) ?? []
    ) { didSet { cachedQuickAddCandidates = nil } }
    @Published var sourceImportProgressMessage: String?
    @Published var isRefreshingQuickAccessFolder = false
    @Published var importInbox: [ImportInboxEntry] = []
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = ""
    @Published var importText = ""
    @Published var sourceLinkURL = ""
    @Published var followedSourceURL = ""
    @Published var followedSourceCandidates: [SourceCandidateEvidence] = []
    @Published var storedSourceFollowSuggestionCandidates: [SourceCandidateEvidence] = []
    var sourceFollowSuggestionItemId: String?
    @Published var followedSourceEntries: [FeedEntry] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published var feedSubscriptions: [FeedSubscription] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published var isRefreshingFollowedSources = false
    @Published var importingFollowedSourceEntryIds: Set<String> = []
    @Published var isFollowingSelectedSource = false
    @Published var isResolvingSourceLink = false
    @Published var sourceLinkCandidateReview: SourceLinkCandidateReviewState?
    @Published var sourceLinkImportState = "idle"
    @Published var sourceLinkImportMessage: String?
    @Published var sourceLinkSafariOffer: OpenInSafariOffer? // #145, set in Gate1AppModel+PasteAndGo.swift
    @Published var selectedListeningEdition: ListeningEdition?
    @Published var automaticMarginOutputEnabled = UserDefaults.standard.bool(forKey: "automaticMarginOutputEnabled")
    @Published var marginOutputStatus = "Choose a folder and send a test note before enabling automatic delivery."
    @Published var isImportingReadLater = false
    let readwiseHighlightSync = ReadwiseHighlightSync()
    private(set) lazy var marginNotesDelivery = MarginNotesDelivery(
        isEnabled: { [weak self] in self?.automaticMarginOutputEnabled == true && self?.store != nil },
        isRecording: { [weak self] in self?.snapshot.isRecording == true },
        target: { [weak self] in
            guard let self else { throw CancellationError() }
            return try self.marginNotesTarget()
        },
        report: { [weak self] in self?.marginOutputStatus = $0 },
        recordGather: { [weak self] in self?.recordAutomaticMarginGather(ms: $0, sessions: $1, notes: $2) }
    )
    @Published var listeningMapJSON = ""
    @Published var isGeneratingListeningMap = false
    @Published var localFoundationModelAvailability: LocalFoundationModelAvailability = .unavailable("Checking availability")
    @Published private(set) var providerBaseURL = "https://api.openai.com/v1"
    @Published var listeningMapModel = UserDefaults.standard.string(forKey: "listeningMapModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summaryModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var conversationModel = UserDefaults.standard.string(forKey: "conversationModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    @Published var skipUnit = UserDefaults.standard.string(forKey: "skipUnit") ?? "paragraph"
    @Published var mediaSkipBackSeconds = Gate1AppModel.storedMediaSkipSeconds(forKey: "mediaSkipBackSeconds")
    @Published var mediaSkipForwardSeconds = Gate1AppModel.storedMediaSkipSeconds(forKey: "mediaSkipForwardSeconds")
    @Published var speechRate: Double = {
        let stored = UserDefaults.standard.double(forKey: "speechRate")
        let rawRate = stored == 0 ? 0.5 : stored
        let multiplier = max(0.5, min(2.0, ((rawRate / 0.5) * 4).rounded() / 4))
        return multiplier * 0.5
    }()
    @Published var mediaPlaybackRate: Double = {
        let stored = UserDefaults.standard.double(forKey: "mediaPlaybackRate")
        let rawRate = stored == 0 ? 1.0 : stored
        return max(0.5, min(2.0, (rawRate * 4).rounded() / 4))
    }()
    @Published var showsMixWithOtherAudioOption = UserDefaults.standard.bool(
        forKey: Gate1AppModel.showsMixWithOtherAudioOptionKey
    )
    @Published var mixesWithOtherAudio = false
    @Published var lowersBackgroundAudio = false
    @Published var mixedPlaybackVolume: Double = {
        guard UserDefaults.standard.object(forKey: Gate1AppModel.mixedPlaybackVolumeKey) != nil else {
            return 1
        }
        return max(
            0,
            min(
                Gate1AppModel.mixedPlaybackVolumeMaximum,
                UserDefaults.standard.double(forKey: Gate1AppModel.mixedPlaybackVolumeKey)
            )
        )
    }()
    @Published var podcastCacheLimitGB = PodcastCacheLimitGB(
        rawValue: UserDefaults.standard.integer(forKey: "podcastCacheLimitGB")
    )?.rawValue ?? PodcastCacheLimitGB.defaultValue.rawValue
    @Published var renderedSpeechCacheLimitMB = Gate1AppModel.storedRenderedSpeechCacheLimitMB()
    @Published var offlineStorageLimitGB = OfflineStorageBudget.allowedGigabytes.contains(
        UserDefaults.standard.integer(forKey: "offlineStorageLimitGB")
    ) ? UserDefaults.standard.integer(forKey: "offlineStorageLimitGB") : 5
    @Published var offlineStorageUsageDescription = "Calculating…"
    @Published var automaticAudioPreparationPolicy = AutomaticAudioPreparationPolicy(
        rawValue: UserDefaults.standard.string(forKey: "automaticAudioPreparationPolicy") ?? ""
    ) ?? .off
    @Published var automaticEpisodeMapPreparationPolicy = AutomaticEpisodeMapPreparationPolicy(
        rawValue: UserDefaults.standard.string(forKey: "automaticEpisodeMapPreparationPolicy") ?? ""
    ) ?? .off
    @Published var episodeMapPreparationStatus = "Not started"
    @Published var podcastDownloadRecords: [String: PodcastDownloadRecord] = [:]
    @Published var preparedTextAudioStatus = "Not started"
    @Published var onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.inactive.rawValue
    @Published var onDeviceSpeechGenerationStopReason: String?
    /// Why narration is in the iOS voice instead of the chosen one (I14); nil when it isn't.
    @Published var speechFallbackReason: SpeechFallbackReason?
    @Published var onDeviceSpeechGenerationProgress = RenderedSpeechGenerationProgress(
        completedChunks: 0,
        totalChunks: 0
    )
    @Published var isOnDeviceSpeechGenerationDelayed = false
    @Published var sourceTranscriptStatus = "Not started"
    @Published var pendingPreparedTextStartItemId: String?
    @Published var speechVoiceOptions: [SpeechVoiceChoice] = []
    @Published var speechVoiceIdentifier = UserDefaults.standard.string(forKey: "speechVoiceIdentifier") ?? ""
    @Published var ttsVoiceSelection = AppTTSVoiceSelection(
        rawValue: UserDefaults.standard.string(forKey: "ttsVoiceSelection") ?? ""
    ) ?? .james
    @Published var ttsMode = UserDefaults.standard.string(forKey: "ttsMode") ?? "supertonic"
    @Published var piperVoiceId = UserDefaults.standard.string(forKey: "piperVoiceId") ?? ""
    @Published var piperVoiceOptions: [PiperVoiceOption] = []
    @Published var piperStatus = "Not checked"
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
    @Published var hasAcceptedCurrentTerms = SpokenMarginsTerms.hasAcceptedCurrentVersion()
        && SpokenMarginsTerms.hasBundledText()
    @Published var acceptedTermsVersion = SpokenMarginsTerms.acceptedVersion()
    @Published var isTermsOfUsePresented = false
    @Published var isHelpPresented = false
    @Published var completedOnboardingSteps = Gate1AppModel.loadOnboardingSteps()
    @Published var guidedOnboardingStage = Gate1AppModel.loadGuidedOnboardingStage()
    @Published var isOnboardingCardDismissed = UserDefaults.standard.bool(forKey: Gate1AppModel.onboardingCardDismissedKey)
    @Published var legacyLibraryResetNotice: String?
    @Published var knownIssues = [
        "Physical-device product validation remains pending.",
        "Now Playing lock-screen controls require signed real-device validation.",
        "Source link, public podcast, and share-extension intake are experimental until they have their own human validation record."
    ]

    var engine: SessionEngine?
    var store: SQLiteSessionStore?
    var databaseURLOverride: URL?
    let gate2CompactControls: Gate2CompactControlController
    let featureFlags: SpokenMarginsFeatureFlags
    let localFoundationModelClient: any LocalFoundationModelClient
    #if SPOKEN_MARGINS_WATCH
    let gate3WatchConnectivity = Gate3WatchConnectivityController()
    #endif
    let openAIResponsesClient = OpenAIResponsesClient()
    let streamingSpeechQueue = StreamingSpeechQueue()
    var speechPlaybackClient: AudioPlaybackClient?
    var sessionAudioPlaybackClient: AudioPlaybackClient?
    var supertonicRenderer: SupertonicNarrationRenderer?
    var preparedAudioCoordinator: PreparedAudioCoordinator?
    var currentSupertonicRenderSignature: TTSRenderSignature?
    var renderedSpeechDiskCache: RenderedSpeechDiskCache?
    let sourceLinkResolver: LinkResolutionClient?
    let sourceLinkHandoffStore: SourceLinkHandoffStore?
    let browserTextHandoffStore: Gate5BrowserTextHandoffStore?
    let audioPlaybackClientOverride: AudioPlaybackClient?
    var mediaPlaybackClient: AVPlayerStreamPlaybackClient?
    var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    var requestedPodcastTransportReplacements: Set<String> = []
    var offlineStorageLedger: OfflineStorageLedger?
    var localSourceImporter: LocalSourceImporter?
    var followedSourceCoordinator: FollowedSourceCoordinator?
    /// A fresh install: the Library was empty before the welcome sample was added (B1 drawer).
    var libraryWasEmptyAtLaunch = false
    var readablePageExtractor: any ReadablePageExtracting = AppOwnedReadablePageExtractor() // tests replace it (#223)
    var sourceSuggestionChecks: Set<String> = []
    var followDiscoveries: [String: Task<[SourceCandidateEvidence], Error>] = [:]
    @Published var followOffers: [String: FollowOffer] = [:]
    var guidedOnboardingCoordinator: GuidedOnboardingCoordinator?
    let recordingClientOverride: RecordingClient?
    let microphonePermissionRequest: (() async -> Bool)?
    let forcePreparedTextGate: Bool
    let sourceTranscriptionClient: SourceTranscriptionClient
    let interjectionTranscriptionHandler: InterjectionTranscriptionHandler
    let alignedInterjectionTranscriptionHandler: AlignedInterjectionTranscriptionHandler?
    let preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler?
    let shareMarginSilenceAnalysisHandler: ShareMarginSilenceAnalysisHandler
    let shareMarginAudioCleanupHandler: ShareMarginAudioCleanupHandler
    let trashUndoDismissDelay: Duration
    #if SPOKEN_MARGINS_WATCH
    var gate3WatchDispatcher: CompactControlDispatcher?
    #endif
    var activeItemId = "item-pill"
    var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    var playbackProgressTask: Task<Void, Never>?
    var sleepTimerTask: Task<Void, Never>?
    var onDeviceSpeechGenerationDelayTask: Task<Void, Never>?
    var trashUndoDismissTask: Task<Void, Never>?
    #if canImport(UIKit) && os(iOS)
    var textPlaybackStartupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    #if canImport(AVFoundation)
    var interjectionAudioPlayer: AVPlayer?
    var interjectionAudioCompletionTask: Task<Void, Never>?
    var skimBridgePlayer: AVPlayer?
    var skimBridgeTask: Task<Void, Never>?
    var preparingLocalAudioMapItems = Set<String>()
    var commentaryCuePlayer: AVAudioPlayer?
    #endif
    var announcedImportedInterjectionIDs: Set<String> = []
    var sourceShouldResumeAfterImportedCommentary = false
    var sourcePausedForImportedCommentaryPrompt = false
    var importedCommentaryAutoPlayTask: Task<Void, Never>?
    var bulkSharePreparationTask: Task<Void, Never>?
    var bulkSharePreparationGeneration = 0
    var shouldForceFirstSharedSourceMissForUITesting =
        CommandLine.arguments.contains("--ui-testing")
        && ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_FORCE_FIRST_SHARED_SOURCE_MISS"] == "1"
    var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    var foregroundAudioPreparationTask: Task<Void, Never>?
    var foregroundAudioPreparationGeneration = 0
    var episodeMapPreparationTask: Task<Void, Never>?
    var episodeMapPreparationItemId: String?
    var isUpdatingSkimAvailability = false
    var backgroundPreparationPrefersEpisodeMap = true
    var sourceImportTask: Task<Void, Never>?
    var quickAccessRefreshTask: Task<Void, Never>?
    var quickAccessRefreshID = UUID()
    var liveSpeechFallbackItemIds: Set<String> = []
    var suppressedAutomaticAudioPreparationItemIds = Set(
        UserDefaults.standard.stringArray(forKey: Gate1AppModel.suppressedAudioPreparationItemIdsKey) ?? []
    )
    var pendingStartupAudioPreparationItemIds: Set<String> = []
    var failedStartupAudioPreparationItemIds: Set<String> = []
    var isImportingPendingSourceLinkHandoffs = false
    var pendingAutoPlayQueue = Gate1PlaybackAutoplayQueue()
    var completedStreamingTurnIds: Set<String> = []
    @Published var pendingSourceContextInterjectionIds: Set<String> = []
    var pendingFullSourceTranscriptionItemIds: Set<String> = []
    var importedPodcastResolutionGenerations: [String: Int] = [:]
    var importedPodcastResolutionURLs: [String: URL] = [:]
    var importedTranscriptRetryDates: [String: Date] = [:]
    var transcriptAssistedResolutionItems: Set<String> = []
    var importedPodcastRecipientLocalURLs: [String: URL] = [:]
    var pendingMapGenerationItemId: String?
    var pendingProviderJobForConsent: PendingProviderJob?
    var pendingMapGenerationAfterConsent = false
    var pendingTermsVoiceSelection: AppTTSVoiceSelection?
    var pendingPlaybackAfterTerms: PendingPlaybackAfterTerms?
    #if SPOKEN_MARGINS_WATCH
    var activeWatchPackageRenderItemIds: Set<String> = []
    var failedWatchPackageRenderItemIds: Set<String> = []
    #endif
    private let preparedTextAudioStarterDurationMs = 30_000
    static let startupAudioChunkCount = 2
    static let textAudioPreparationCutoffPercent = 99
    static let lastPreparedAudioNoticeDateKey = "lastPreparedAudioNoticeDateV1"
    let sourceWindowContextBeforeMs = SourceAnchorContextResolver.windowBeforeMs
    let sourceWindowContextAfterMs = SourceAnchorContextResolver.windowAfterMs
    let quickAccessFolderBookmarkKey = "quickAccessFolderBookmark"
    let batchExportFolderBookmarkKey = "batchExportFolderBookmark"
    #if canImport(AVFoundation)
    let speechPreviewSynthesizer = AVSpeechSynthesizer()
    var supertonicPreviewPlayer: AVAudioPlayer?
    var supertonicPreviewURL: URL?
    #endif
    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(
        sourceLinkResolver: LinkResolutionClient? = nil,
        sourceLinkHandoffStore: SourceLinkHandoffStore? = nil,
        browserTextHandoffStore: Gate5BrowserTextHandoffStore? = nil,
        audioPlaybackClient: AudioPlaybackClient? = nil,
        recordingClient: RecordingClient? = nil,
        microphonePermissionRequest: (() async -> Bool)? = nil,
        forcePreparedTextGate: Bool = false,
        sourceTranscriptionClient: SourceTranscriptionClient = SystemSourceTranscriptionClient(),
        interjectionTranscriptionHandler: InterjectionTranscriptionHandler? = nil,
        alignedInterjectionTranscriptionHandler: AlignedInterjectionTranscriptionHandler? = nil,
        preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler? = nil,
        shareMarginSilenceAnalysisHandler: ShareMarginSilenceAnalysisHandler? = nil,
        shareMarginAudioCleanupHandler: ShareMarginAudioCleanupHandler? = nil,
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
        self.microphonePermissionRequest = microphonePermissionRequest
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
            self.alignedInterjectionTranscriptionHandler = alignedInterjectionTranscriptionHandler
        } else {
            let transcriptionClient = SystemSpeechTranscriptionClient()
            self.interjectionTranscriptionHandler = { audioPath in
                try await transcriptionClient.transcribe(audioPath: audioPath)
            }
            self.alignedInterjectionTranscriptionHandler = alignedInterjectionTranscriptionHandler ?? { audioPath in
                try await transcriptionClient.transcribeAligned(audioPath: audioPath)
            }
        }
        self.preparedTextAudioPrewarmHandler = preparedTextAudioPrewarmHandler
        self.shareMarginSilenceAnalysisHandler = shareMarginSilenceAnalysisHandler ?? { sourceURL, aligned in
            try InterjectionSilenceDetector.proposePauseEdits(
                sourceURL: sourceURL,
                alignedTranscript: aligned
            )
        }
        self.shareMarginAudioCleanupHandler = shareMarginAudioCleanupHandler ?? { sourceURL, destinationURL, decisions in
            try await InterjectionAudioCleanupRenderer.render(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                decisions: decisions
            )
        }
        localFoundationModelAvailability = localFoundationModelClient.availability()
        migrateTTSSettingsIfNeeded()
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
            } else {
                // UI routes share a simulator preferences domain. Keep a route
                // that explicitly exercises Supertonic from changing the voice
                // used by later system-speech routes.
                ttsVoiceSelection = .system
                UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
                // The route explicitly chooses system speech, including on a
                // fresh simulator whose migration queued a Supertonic choice.
                UserDefaults.standard.removeObject(forKey: Self.supertonicVoicePendingTermsKey)
            }
        }
        enforceTermsGateForStoredVoice()
        UserDefaults.standard.removeObject(forKey: "aiExecutionMode")
        // The system voice catalog is loaded when Settings appears. Eager
        // enumeration here can block app launch while TextToSpeech services
        // are still starting, and the catalog is not needed on other screens.
        sanitizeTTSMode()
        settingsValueChanged()
        refreshQuickAccessFolder()
        streamingSpeechQueue.onTurnDrained = { [weak self] turnId in
            self?.finishStreamingTurnIfReady(turnId)
        }
        streamingSpeechQueue.onPlaybackObservation = { [weak self] observation in
            self?.applyStreamingSpeechObservation(observation)
        }
        #if canImport(BackgroundTasks) && canImport(UIKit)
        AudioPreparationBackgroundController.shared.install { [weak self] in
            await self?.performBackgroundPreparationPass() ?? .finished
        }
        #endif
    }

    static let supportedMediaSkipSeconds = [10, 15, 30, 45, 60]
    static let supportedPodcastCacheLimitsGB = PodcastCacheLimitGB.allCases.map(\.rawValue)
    static let supportedRenderedSpeechCacheLimitsMB = [128, 256, 512, 1_024]

    deinit {
        navigationRefreshTask?.cancel()
        playbackProgressTask?.cancel()
        onDeviceSpeechGenerationDelayTask?.cancel()
        trashUndoDismissTask?.cancel()
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        foregroundAudioPreparationTask?.cancel()
        sourceImportTask?.cancel()
        quickAccessRefreshTask?.cancel()
        interjectionAudioCompletionTask?.cancel()
        importedCommentaryAutoPlayTask?.cancel()
        bulkSharePreparationTask?.cancel()
    }

    var cachedQuickAddCandidates: [QuickAddCandidate]?

    @Published var skimForwardDestinationMs: Int?
    @Published var skimBackwardDestinationMs: Int?
    var skimResourceContext: SkimResourceContext?
    #if DEBUG
    var skimResourceLoadCount = 0
    #endif

    @Published var renderedSourceFraction: Double?
    var frontierSignatures: [String: TTSRenderSignature] = [:]
    var frontierPublicationKey: String?

    var automaticMarginGatherMaxMs = 0

    nonisolated static let preparationPlanCache = PreparedChunkPlanCache()

    var followCandidateDiscoveryHandler: ((Item, URL) async throws -> [SourceCandidateEvidence])?

}
