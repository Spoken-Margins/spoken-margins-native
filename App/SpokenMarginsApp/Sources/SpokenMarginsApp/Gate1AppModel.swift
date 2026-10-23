import Combine
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

struct ObsidianImportRequest: Sendable {
    let url: URL
    let itemId: String
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
    private static let supertonicTTSMigrationKey = "supertonicTTSMigrationV1"
    static let supertonicVoicePendingTermsKey = "supertonicVoicePendingTermsV1"
    static let showsMixWithOtherAudioOptionKey = "showsMixWithOtherAudioOption"
    static let mixedPlaybackVolumeKey = "mixedPlaybackVolume"
    static let suppressedAudioPreparationItemIdsKey = AudioPreparationQueueProjection.suppressedItemIdsDefaultsKey
    static let mixedPlaybackVolumeMaximum = 1.0
    static let exportPreviewCharacterLimit = 24_000
    nonisolated static let supportedPlaybackRates: [Double] = SpeechRateRule.supportedMultipliers
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

    @Published private var presentedScreen: Gate1Screen = .home
    @Published var requestedExperienceRoot: AppRoot?
    @Published var marginCollectionQuery = MarginCollectionQuery()
    @Published var sharedMarginRows: [SharedMarginRow] = []
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
    /// Publishes to every screen except when only the playback position moved (`publishSnapshotChange`, #2074).
    var snapshot = SessionSnapshot() {
        willSet { publishSnapshotChange(to: newValue) }
        didSet {
            recordPlaybackEventState(previous: oldValue)
            if oldValue.sessionId != snapshot.sessionId { resumeDeferredPodcastPlacements() }
            if oldValue.isRecording, !snapshot.isRecording { endCaptureWatch() }
            if !oldValue.isRecording, snapshot.isRecording { startCaptureWatch() }
            settleSpeechInterruptionResume()
            listeningSignals.snapshotChanged(from: oldValue, to: snapshot)
            updateNarrationVoiceNotice()
            if playingImportedCommentary != nil,
               oldValue.sessionId != snapshot.sessionId || oldValue.itemId != snapshot.itemId
                || oldValue.targetId != snapshot.targetId || snapshot.status.isPlaybackActive {
                stopImportedCommentaryPlayback(resumeSource: false)
            }
            if snapshot.status.isPlaybackActive { releaseOwnMarginReturn() }
            if let status = snapshot.preparedTextAudioStatus, status != preparedTextAudioStatus { preparedTextAudioStatus = status } // an equal write still publishes
            if let snapshotSourceTranscriptStatus = snapshot.sourceTranscriptStatus, snapshotSourceTranscriptStatus != sourceTranscriptStatus,
               !(sourceTranscriptStatus == "transcribing" && snapshotSourceTranscriptStatus == "not_started") {
                sourceTranscriptStatus = snapshotSourceTranscriptStatus
            }
            if oldValue.status.isPlaybackActive != snapshot.status.isPlaybackActive || oldValue.itemId != snapshot.itemId {
                if !canPrepareLibraryAudio {
                    libraryAudioLoop.cancelOnly()
                } else {
                    startForegroundAudioPreparationIfNeeded()
                }
            }
            reconcilePlaybackProgressTicker()
            reconcileNarrationStartupProtection()
            updateSkimAvailability(refreshResources: false)
            updateGate2CompactState()
        }
    }
    @Published var narrationVoiceNotice = NarrationVoiceNotice() // written by updateNarrationVoiceNotice() only
    var gate2CompactSnapshot: CompactControlSnapshot?
    let runtimeDiagnostics = RuntimeDiagnostics()
    let playbackClock = PlaybackClock() // the playhead, for the views that follow it (#2074)
    let selectedItemStreamFlag = CachedItemFlag() // whether the open item is a remote stream, read from the store once (#2074)
    var diagnostics: [String: String] {
        get { runtimeDiagnostics.values }
        set { if runtimeDiagnostics.values != newValue { runtimeDiagnostics.values = newValue } }
    }
    @Published var developerDiagnosticRecordingEnabled = false {
        didSet { configureDeveloperDiagnosticRecording() }
    }
    let developerDiagnosticBuild = DeveloperDiagnosticRecording.buildIdentity
    private var developerDiagnosticTask: Task<Void, Never>?
    private let developerRecording = DeveloperDiagnosticRecording(fileURL:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeveloperDiagnostics/latest.json"))
    let playbackEventRecording = DeveloperDiagnosticRecording(
        limit: 300,
        fileURL: Gate1AppModel.isRunningUnitTests ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeveloperDiagnostics/playback-events.json"),
        automatic: true
    )
    let hangTelemetry = HangTelemetry() // #2099
    var lastPlaybackEventCheckpoint: TimeInterval = 0
    var speechInterruptionResumeWatch = SpeechInterruptionResumeWatch()

    func recordDeveloperDiagnostic(_ kind: String, _ fields: [String: String] = [:]) {
        developerRecording.record(kind, fields)
        // High-frequency samples and rendering events must not erase transport history.
        if kind != "sample", !kind.hasPrefix("preparation."),
           !kind.hasPrefix("scrub."), kind != "main.delayed" {
            playbackEventRecording.record(kind, fields)
        }
    }

    private func configureDeveloperDiagnosticRecording() {
        developerDiagnosticTask?.cancel()
        guard developerDiagnosticRecordingEnabled else {
            developerRecording.stop()
            return
        }
        developerRecording.start()
        developerDiagnosticTask = Task { @MainActor [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.recordDeveloperSample(intervalMs: Int((now - previous) * 1000))
                previous = now
            }
        }
    }

    private func recordDeveloperSample(intervalMs: Int) {
        let row = libraryItems.first { $0.id == selectedItem.id }
        let fields: [String: String] = [
            "item": DeveloperDiagnosticRecording.token(snapshot.itemId),
            "selected": DeveloperDiagnosticRecording.token(selectedItem.id),
            "target": DeveloperDiagnosticRecording.token(snapshot.targetId),
            "screen": String(describing: screen),
            "status": snapshot.status.rawValue,
            "textOffset": String(snapshot.currentTextStart ?? 0),
            "generation": onDeviceSpeechGenerationStatus,
            "generatedChunks": String(onDeviceSpeechGenerationProgress.completedChunks),
            "totalChunks": String(onDeviceSpeechGenerationProgress.totalChunks),
            "openingState": String(describing: row?.startupAudioState),
            "openingChunks": String(row?.startupAudioCompletedChunkCount ?? 0),
            "openingTarget": String(row?.startupAudioTargetChunkCount ?? 0),
            "workerActive": String(libraryAudioLoop.isRunning),
            "canPrepare": String(canPrepareLibraryAudio),
            "queueCount": String(audioPreparationQueue.count),
            "lowPower": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "thermal": String(ProcessInfo.processInfo.thermalState.rawValue),
            "intervalMs": String(intervalMs)
        ]
        recordDeveloperDiagnostic("sample", fields)
        #if canImport(UIKit)
        if intervalMs > 1000, UIApplication.shared.applicationState == .active {
            recordDeveloperDiagnostic("main.delayed", ["intervalMs": String(intervalMs)])
        }
        #endif
    }

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
    @Published private(set) var batchExportRows: [BatchSessionExportRow] = []
    @Published var batchExportFilter: BatchSessionExportFilter = .withInterjections
    @Published var selectedBatchExportSessionIds: Set<String> = []
    @Published var batchExportFolderName = SavedFolderSetting.sessionExport.name() ?? "No folder selected"
    @Published var batchExportResult: BatchSessionExportResult?
    @Published var batchExportShare: SessionShareFiles?
    @Published var retryingInterjectionTranscriptionIds: Set<String> = []
    var libraryPresentationRevision = 0
    var navigationRefreshTask: Task<Void, Never>?
    var navigationLibraryRead: @Sendable (SQLiteSessionStore) async throws -> LibraryReadSnapshot = { store in
        try await Task.detached(priority: .utility) { try LibraryReadSnapshot.read(store: store) }.value
    }
    var activePlaybackDetail: ItemDetailState?
    let backgroundRefresh = BackgroundRefreshGate() // #2102
    @Published var libraryItems: [LibraryItemRow] = [] {
        didSet { quickAccess.invalidateCandidates(); libraryPresentationRevision += 1 }
    }
    @Published var audioPreparationQueue: [AudioPreparationQueueRow] = []
    @Published var recentlyPreparedAudio: [RecentlyPreparedAudioRow] = []
    @Published var libraryQuery = LibraryQuery(
        contentType: LibraryContentTypeFilter(rawValue: UserDefaults.standard.string(forKey: "libraryContentTypeFilter") ?? "") ?? .all,
        listeningState: Gate1AppModel.loadLibraryListeningFilter(defaults: .standard),
        offlineState: LibraryOfflineStateFilter(rawValue: UserDefaults.standard.string(forKey: "libraryOfflineStateFilter") ?? "") ?? .all,
        sort: LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recentlyAdded
    )
    @Published private(set) var sleepTimerState: SleepTimerState = .inactive
    @Published private(set) var sleepTimerRemainingSeconds: Int?
    @Published var libraryAccessError: String?
    @Published var recentlyDeletedItems: [LibraryItemRow] = []
    @Published var trashUndo: TrashUndoState?
    @Published var selectedItem = ItemDetailState() {
        didSet {
            if selectedItem.id == snapshot.itemId { activePlaybackDetail = selectedItem }
            else if oldValue.id == snapshot.itemId { activePlaybackDetail = oldValue }
            if oldValue.id != selectedItem.id { selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: selectedItem.id) }
            backgroundRefresh.selectionWasAssigned()
            skimBridge.itemDetailChanged(from: SkimResourceKey(oldValue), to: SkimResourceKey(selectedItem)); selectedItemStreamFlag.invalidate()
            prepareLeveledMargins(from: oldValue)
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
    @Published private(set) var offlineStorageSnapshot = OfflineStorageSnapshot()
    @Published var recordingCaptureHealth: MarginCaptureSupervisor.Health = .capturing // written by Gate1AppModel+MarginCapture only
    var captureWatcher = MarginCaptureWatcher()
    /// The capture state (#993): its values reach views under their old names (`Gate1AppModel+MarginCapture.swift`), and its changes are forwarded here before they happen.
    private var marginCaptureObservation: AnyCancellable?
    private(set) lazy var marginCapture: MarginCaptureCoordinator = {
        let capture = MarginCaptureCoordinator()
        self.marginCaptureObservation = capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return capture
    }()
    @Published var isDismissingMiniPlayer = false
    @Published var requestedTimelineFocusMarginID: String?
    @Published var pastedAssistantResponse = ""
    @Published var sharingState = InterjectionSharingState()
    @Published var isSharingInterjectionsPresented = false
    @Published var sharedSpokenMarginsPackageURL: URL?
    @Published var isSharedSpokenMarginsPackagePresented = false
    /// The views' copy of the import state, which `packageImport` owns (T5, #963). A write here reaches it through `didSet`.
    @Published var spokenMarginsPackageImportReview: SpokenMarginsPackageImportReview? { didSet { packageImport.adoptReviewFromViews(spokenMarginsPackageImportReview) } }
    @Published var isImportingSpokenMarginsPackage = false { didSet { packageImport.adoptIsImportingFromViews(isImportingSpokenMarginsPackage) } }
    @Published var spokenMarginsPackageImportError: String? { didSet { packageImport.adoptErrorFromViews(spokenMarginsPackageImportError) } }
    private(set) lazy var packageImport = SpokenMarginsPackageImportCoordinator(environment: .live(model: self))
    @Published var pendingImportedCommentary: ImportedCommentaryPrompt? {
        didSet {
            if oldValue?.id != pendingImportedCommentary?.id {
                updateGate2CompactState()
            }
        }
    }
    /// The Margin voice transport (#993). Its published state reaches views as this model's own names
    /// (`playingImportedCommentary` and the rest, in `Gate1AppModel+MarginVoicePlayback.swift`), and its changes are
    /// forwarded here synchronously, before the value changes, as the model's own `@Published` copies were.
    private var marginVoiceObservation: AnyCancellable?
    private(set) lazy var marginVoicePlayer: MarginVoicePlayer = {
        let voice = MarginVoicePlayer(host: self)
        self.marginVoiceObservation = voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return voice
    }()
    /// "Play this moment" (#159). The sequence is published for the playback screen; the conductor runs it.
    @Published private(set) var marginMoment: MarginMomentSequence?
    @Published private(set) var marginMomentVoiceIsPaused = false
    /// Whose Margin the moment is for ("Your Margin", "Cole's Margin"), and whether its position is only a guess.
    @Published private(set) var marginMomentTitle = "Your Margin"
    @Published private(set) var marginMomentPositionIsApproximate = false
    private(set) var marginMomentConductor: MarginMomentConductor?
    /// The Margin voice Add a Margin paused and kept (`Gate1AppModel+MarginVoiceHold.swift`, #1672).
    var marginVoiceHeldForRecording: HeldMarginVoice?
    private(set) var marginMomentClock = MarginMomentClock.media // media time, or narration time for text read aloud (#1577)
    /// Heard audio around streamed Margins, in temporary files only while a Margin can use it (#156, #652). Keyed by margin identity.
    var heardSourceWindows = HeardSourceWindowFiles(rootDirectory: HeardSourceWindowFiles.defaultRootDirectory)

    var activePlaybackIsPlaying: Bool {
        if playingImportedCommentary != nil { return importedCommentaryPhase.showsPause }
        if marginMomentConductor?.isPlayingVoice == true { return !marginMomentVoiceIsPaused }
        if ownMarginVoiceHasTransport { return !ownMarginVoiceIsPaused }
        return snapshot.skimBridgeState?.status == .playing || snapshot.status.isPlaybackActive
    }

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
    let quickAccess = QuickAccessFolderState() // the Quick Folder; its changes are relayed in init (#981)
    @Published var sourceImportProgressMessage: String?
    @Published var importInbox: [ImportInboxEntry] = []
    @Published var sourceLinksWaitingForNetwork = 0 // shared links left pending while offline (#1546)
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = ""
    @Published var importText = ""
    @Published var sourceLinkURL = ""
    @Published var followedSourceURL = ""
    @Published var followedSourceCandidates: [SourceCandidateEvidence] = []
    @Published var storedSourceFollowSuggestionCandidates: [SourceCandidateEvidence] = []
    var sourceFollowSuggestionItemId: String?
    var sourceFollowSuggestionCandidates: [SourceCandidateEvidence] {
        guard sourceFollowSuggestionItemId == selectedItem.id else { return [] }
        let row = libraryItems.first(where: { $0.id == selectedItem.id })
        guard !FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: row?.sourceURL, sourceTitle: row?.sourceTitle, sourceReference: row?.sourceReference,
            subscriptions: feedSubscriptions
        ) else { return [] }
        return FollowedSourceMatching.uniqueUnfollowedCandidates(storedSourceFollowSuggestionCandidates, subscriptions: feedSubscriptions)
    }
    @Published var followedSourceEntries: [FeedEntry] = [] { didSet { quickAccess.invalidateCandidates() } }
    @Published var feedSubscriptions: [FeedSubscription] = [] { didSet { quickAccess.invalidateCandidates(); listeningSignals.endListening() } }
    @Published var isRefreshingFollowedSources = false
    @Published var importingFollowedSourceEntryIds: Set<String> = []
    /// The latest Play now or Add and open from Following; any later open or start makes it stale (#2124).
    var followedPlayIntent = CurrentRequest()
    @Published var isFollowingSelectedSource = false
    @Published var sourceLinkGate = SourceLinkImportGate() // #2135: counts overlapping imports
    @Published var sourceLinkCandidateReview: SourceLinkCandidateReviewState?
    @Published var sourceLinkImportState = "idle"
    @Published var sourceLinkImportMessage: String?
    @Published var sourceLinkSafariOffer: OpenInSafariOffer? // #145, set in Gate1AppModel+PasteAndGo.swift
    @Published var selectedListeningEdition: ListeningEdition?
    @Published private(set) var isImportingReadLater = false
    let readwiseHighlightSync = ReadwiseHighlightSync()
    /// Margin Output (#492): every notes destination, its settings and its delivery loop.
    private(set) lazy var marginOutput = MarginOutputCoordinator(
        store: { [weak self] in self?.store },
        isRecording: { [weak self] in self?.snapshot.isRecording == true },
        recordGather: { [weak self] in self?.recordAutomaticMarginGather(ms: $0, sessions: $1, notes: $2) },
        databaseURLOverride: databaseURLOverride
    )
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
    @Published var speechRate: Double = {
        let stored = UserDefaults.standard.double(forKey: "speechRate")
        let rawRate = stored == 0 ? 0.5 : stored
        return SpeechRateRule.quarterStepMultiplier(rawRate / 0.5) * 0.5
    }()
    @Published var mediaPlaybackRate: Double = {
        let stored = UserDefaults.standard.double(forKey: "mediaPlaybackRate")
        let rawRate = stored == 0 ? 1.0 : stored
        return SpeechRateRule.quarterStepMultiplier(rawRate)
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
    @Published private(set) var offlineStorageUsageDescription = "Calculating…"
    @Published var automaticAudioPreparationPolicy = AutomaticAudioPreparationPolicy(
        rawValue: UserDefaults.standard.string(forKey: "automaticAudioPreparationPolicy") ?? ""
    ) ?? .off
    @Published var automaticEpisodeMapPreparationPolicy = AutomaticEpisodeMapPreparationPolicy(
        rawValue: UserDefaults.standard.string(forKey: "automaticEpisodeMapPreparationPolicy") ?? ""
    ) ?? .off
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
    @Published var speechVoiceOptions: [SpeechVoiceChoice] = []
    @Published var speechVoiceIdentifier = UserDefaults.standard.string(forKey: "speechVoiceIdentifier") ?? ""
    @Published var ttsVoiceSelection = AppTTSVoiceSelection(
        rawValue: UserDefaults.standard.string(forKey: "ttsVoiceSelection") ?? ""
    ) ?? .james
    @Published var ttsMode = UserDefaults.standard.string(forKey: "ttsMode") ?? "supertonic"
    @Published var isRenderingSupertonicPreview = false
    /// The Supertonic preview still rendering; playback, a Margin or a voice change makes it stale (#2125).
    var supertonicPreviewRequest = VoicePreviewRequest<SupertonicVoiceID>()
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
    /// Read from UserDefaults here, in the declaration, so a model built after a test writes the keys sees them.
    @Published var onboardingProgress = OnboardingProgress(
        storedSteps: UserDefaults.standard.stringArray(forKey: Gate1AppModel.onboardingStepsKey),
        storedStage: UserDefaults.standard.string(forKey: Gate1AppModel.guidedOnboardingStageKey),
        isCardDismissed: UserDefaults.standard.bool(forKey: Gate1AppModel.onboardingCardDismissedKey)
    )
    @Published var knownIssues = [
        "Physical-device product validation remains pending.",
        "Now Playing lock-screen controls require signed real-device validation.",
        "Source link, public podcast, and share-extension intake are experimental until they have their own human validation record."
    ]

    var engine: SessionEngine?
    var store: SQLiteSessionStore?
    /// The UI-test seed this launch still has to write; nil once written and for a normal launch. Written even when
    /// something opened the store before the root view bootstrapped the Library, else the last run's Library shows (#1175).
    var pendingUITestingSeed: UITestingLaunchSeed? = UITestingHooks.seed.writesLibrary ? UITestingHooks.seed : nil
    lazy var listeningSignals = ListeningSignalsCoordinator(repository: { [weak self] in self?.store })
    var databaseURLOverride: URL?
    let gate2CompactControls: Gate2CompactControlController
    private let featureFlags: SpokenMarginsFeatureFlags
    let localFoundationModelClient: any LocalFoundationModelClient
    let openAIResponsesClient = OpenAIResponsesClient()
    let streamingSpeechQueue = StreamingSpeechQueue(speech: SystemSpeechPlaybackClient())
    var speechPlaybackClient: AudioPlaybackClient?
    var sessionAudioPlaybackClient: AudioPlaybackClient?
    let supertonicModel = SupertonicModelFollower<SupertonicNarrationRenderer>(locate: { SupertonicAssetResolver.location() }, retire: { old in Task { await old.unload(removingGeneratedAudio: false) } }) // a download (#1820)
    var kittenRenderer: KittenNarrationRenderer? // bundled fallback voice, built on first use (#849)
    var preparedAudioCoordinator: PreparedAudioCoordinator?
    var currentSupertonicRenderSignature: TTSRenderSignature? { // older prepared chunks go first when space is needed (#281)
        didSet { if let digest = currentSupertonicRenderSignature?.digest, digest != oldValue?.digest { Task { [ledger = offlineStorageLedger] in _ = try? await ledger?.markSupersededPreparedChunks(currentSignatureDigest: digest) } } }
    }
    var renderedSpeechDiskCache: RenderedSpeechDiskCache?
    let sourceLinkResolver: LinkResolutionClient?
    let sourceLinkHandoffStore: SourceLinkHandoffStore?
    let browserTextHandoffStore: Gate5BrowserTextHandoffStore?
    let audioPlaybackClientOverride: AudioPlaybackClient?
    var mediaPlaybackClient: AVPlayerStreamPlaybackClient?
    var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    /// Shared by the podcast downloader and the pre-play offline check (#779).
    let connectivity = ConnectivityMonitor()
    var requestedPodcastTransportReplacements: Set<String> = []
    var offlineStorageLedger: OfflineStorageLedger?
    /// Settings › Voices (#1819); created on first use by `requireVoiceDownloads()`.
    var voiceDownloadsModel: VoiceDownloadsModel?
    private var localSourceImporter: LocalSourceImporter?
    var followedSourceCoordinator: FollowedSourceCoordinator?
    /// A fresh install: the Library was empty before the welcome sample was added (B1 drawer).
    var libraryWasEmptyAtLaunch = false
    var readablePageExtractor: any ReadablePageExtracting = AppOwnedReadablePageExtractor() // tests replace it (#223)
    let sharedLinkVoiceover = SharedLinkVoiceover() // tests replace its page fetch (#810)
    var sourceSuggestionChecks: Set<String> = []
    var followDiscoveries: [String: Task<[SourceCandidateEvidence], Error>] = [:]
    @Published var followOffers: [String: FollowOffer] = [:]
    var guidedOnboardingCoordinator: GuidedOnboardingCoordinator?
    private let recordingClientOverride: RecordingClient?
    let microphoneAccess: MarginMicrophoneAccess
    let sourceTranscriptionClient: SourceTranscriptionClient
    let interjectionTranscriptionHandler: InterjectionTranscriptionHandler
    let alignedInterjectionTranscriptionHandler: AlignedInterjectionTranscriptionHandler?
    let preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler?
    let shareMarginSilenceAnalysisHandler: ShareMarginSilenceAnalysisHandler
    let shareMarginAudioCleanupHandler: ShareMarginAudioCleanupHandler
    let trashUndoDismissDelay: Duration
    var activeItemId = "item-pill"
    var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    private var playbackProgressTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    var onDeviceSpeechGenerationDelayTask: Task<Void, Never>?
    var trashUndoDismissTask: Task<Void, Never>?
    /// Background time while on-device narration starts, on every path into "starting" (#854).
    private lazy var narrationStartupProtection = NarrationStartupProtection(
        begin: NarrationStartupBackgroundTime.begin,
        record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
        outcomeChanged: { [weak self] in self?.diagnostics["textAudioBackgroundStartup"] = $0.rawValue }
    )
    /// Background time over each seam between two chunks of on-device narration (#540).
    lazy var handOverBackgroundHold = HandOverBackgroundHold(
        begin: NarrationStartupBackgroundTime.begin,
        record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) }
    )
    #if canImport(AVFoundation)
    var preparingLocalAudioMapItems: [String: Bool] = [:] // a summary pass in flight → another was asked for meanwhile (#2255)
    #endif
    var sharedMarginOffers = SharedMarginOfferQueue()
    var reviewPlaces = ReviewReturnPlaces() // the place a "Review new Margins" owes the listener, kept across launches (#474)
    var sharedMarginReturn = SharedMarginReturnClaim() // who owes the source back after a shared Margin (#997)
    var importedCommentaryAutoPlayTask: Task<Void, Never>?
    var bulkSharePreparationTask: Task<Void, Never>?
    var bulkSharePreparationGeneration = 0
    var shouldForceFirstSharedSourceMissForUITesting = UITestingHooks.forcesFirstSharedSourceMiss
    private var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    let libraryAudioLoop = LibraryAudioPreparationLoop() // the foreground loop, its render gate and turns (#281, #534, #995)
    var libraryAudioPreparingItemId: String? { get { libraryAudioLoop.turns.preparingItemId } set { libraryAudioLoop.turns.preparingItemId = newValue } }
    lazy var episodeMapPreparer = EpisodeMapPreparer(host: self) // private episode map preparation: task, status, pending request (#957)
    var backgroundPreparationPlanner = BackgroundPreparationPlanner()
    var sourceImportTask: Task<Void, Never>?
    var offlineServicesStartupTasks: [Task<Void, Never>] = [] // `startOfflineServices`; cancelled with the model (#2195)
    var liveSpeechFallbackItemIds: Set<String> = []
    var suppressedAutomaticAudioPreparationItemIds = Set(
        UserDefaults.standard.stringArray(forKey: Gate1AppModel.suppressedAudioPreparationItemIdsKey) ?? []
    )
    var pendingStartupAudioPreparationItemIds: Set<String> = []
    var failedStartupAudioPreparationItemIds: Set<String> = []
    var isImportingPendingSourceLinkHandoffs = false
    let pendingHandoffNetworkRetry = PendingHandoffNetworkRetry()
    private var pendingAutoPlayQueue = Gate1PlaybackAutoplayQueue()
    var completedStreamingTurnIds: Set<String> = []
    @Published var pendingSourceContextInterjectionIds: Set<String> = []
    let sourceWindowJobQueue = SourceWindowJobQueue()
    lazy var importedPodcastPlacement = makeImportedPodcastPlacementCoordinator() // placing shared podcast Margins and the transcript slot (#1015)
    var deferredPodcastPlacementURLs: [String: URL] = [:] // see Gate1AppModel+PodcastPlacementDeferral (#914)
    var importedPodcastRecipientLocalURLs: [String: URL] = [:]
    var pendingProviderJobForConsent: PendingProviderJob?
    private var pendingMapGenerationAfterConsent = false
    var pendingTermsVoiceSelection: AppTTSVoiceSelection?
    var pendingPlaybackAfterTerms: PendingPlaybackAfterTerms?
    private let preparedTextAudioStarterDurationMs = 30_000
    static let startupAudioChunkCount = LibraryRowBuilder.startupAudioChunkCount
    var preparationSeams = PreparationPassSeams()
    var isWaitingOutPreparationHeat = false // the foreground loop sleeps until the phone cools (#905)
    static let lastPreparedAudioNoticeDateKey = AudioPreparationQueueProjection.lastNoticeDateDefaultsKey
    let sourceWindowContextBeforeMs = SourceAnchorContextResolver.windowBeforeMs
    let sourceWindowContextAfterMs = SourceAnchorContextResolver.windowAfterMs
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

    enum PendingPlaybackAfterTerms {
        case startCurrentItem
        case resumeSession(String)
        case jumpToChapter(String, fromTimeline: Bool)
        case playSourceFromBeginning(fromTimeline: Bool)
    }
    static func availableSpeechVoiceOptions() -> [SpeechVoiceChoice] {
        #if canImport(AVFoundation)
        // `AVSpeechSynthesisVoice.speechVoices()` can crash inside the iOS
        // Simulator's AXSpeech process while XCTest is attaching. The system
        // default voice still works there, so do not cross that unstable
        // framework boundary on Simulator. Real devices retain the complete
        // installed-voice picker.
        guard supportsSpeechVoiceEnumeration else { return [] }
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

    #if DEBUG
    /// Tests that model a write through the app must share its serialized connection.
    /// Opening another connection also races unrelated offline-ledger startup work.
    func libraryStoreForTesting() throws -> SQLiteSessionStore {
        precondition(Self.isRunningUnitTests)
        return try requireStore()
    }
    #endif

    init(
        sourceLinkResolver: LinkResolutionClient? = nil,
        sourceLinkHandoffStore: SourceLinkHandoffStore? = nil,
        browserTextHandoffStore: Gate5BrowserTextHandoffStore? = nil,
        audioPlaybackClient: AudioPlaybackClient? = nil,
        recordingClient: RecordingClient? = nil,
        microphonePermissionRequest: (() async -> Bool)? = nil,
        microphonePermissionStatus: (() -> PermissionPromptStatus)? = nil,
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
        self.sourceLinkResolver = sourceLinkResolver ?? UITestingHooks.ambiguousSourceLinkResolver
        self.sourceLinkHandoffStore = sourceLinkHandoffStore
        self.browserTextHandoffStore = browserTextHandoffStore
        self.audioPlaybackClientOverride = audioPlaybackClient
        self.recordingClientOverride = recordingClient
        self.microphoneAccess = MarginMicrophoneAccess(recorderInjected: recordingClient != nil, request: microphonePermissionRequest, status: microphonePermissionStatus)
        self.sourceTranscriptionClient = sourceTranscriptionClient
        self.gate2CompactControls = gate2CompactControls
        self.featureFlags = featureFlags
        self.localFoundationModelClient = UITestingHooks.localFoundationModelClient ?? localFoundationModelClient
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
        if UITestingHooks.isActive {
            speechVoiceIdentifier = ""
            UserDefaults.standard.removeObject(forKey: "speechVoiceIdentifier")
            if let testRate = UITestingHooks.speechRate {
                speechRate = testRate
                UserDefaults.standard.set(testRate, forKey: "speechRate")
            }
            if UITestingHooks.usesSupertonic {
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
        quickAccess.forwardWillChange(to: objectWillChange)
        quickAccess.recordDiagnostic = { [weak self] key, value in self?.diagnostics[key] = value }
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
        } drainEnded: { [weak self] in self?.libraryAudioBackgroundDrainEnded() }
        #endif
    }

    private func migrateTTSSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.supertonicTTSMigrationKey) else {
            synchronizeTTSModeFromSelection()
            return
        }

        // This is intentionally a one-way pre-1.0 migration. Legacy experimental
        // and system-only modes all move to the bundled default voice;
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
        if ttsVoiceSelection.isOnDeviceVoice {
            pendingTermsVoiceSelection = ttsVoiceSelection
            defaults.set(ttsVoiceSelection.rawValue, forKey: Self.supertonicVoicePendingTermsKey)
        } else if let rawValue = defaults.string(forKey: Self.supertonicVoicePendingTermsKey),
                  let pendingVoice = AppTTSVoiceSelection(rawValue: rawValue),
                  pendingVoice.isOnDeviceVoice {
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
            if let chapter = selectedItem.chapters.first(where: { $0.id == chapterId }) {
                jumpToChapter(chapter, fromTimeline: fromTimeline)
            } else if let chapter = selectedItem.mediaChapters.first(where: { $0.id == chapterId }) {
                jumpToMediaChapter(chapter, fromTimeline: fromTimeline)
            } else {
                reportFailure("The selected chapter could not be restored after choosing a voice.")
            }
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
        guard selectedItem.chapters.isEmpty,
              selectedItem.mediaChapters.isEmpty,
              selectedItem.listeningMapScenes.isEmpty else { return false }
        guard let item = try? store?.loadItem(id: activeItemId) else { return false }
        return item.media?.sourceType == .nativeMediaFile
            || item.media?.sourceType == .remoteStream
            || remoteProviderExperienceEnabled
            || item.media == nil
    }

    var listeningMapGenerationAvailabilityDescription: String {
        if !selectedItem.listeningMapScenes.isEmpty {
            return selectedItem.listeningMapAvailabilityDescription
        }
        if !selectedItem.mediaChapters.isEmpty {
            return "This podcast already includes publisher chapters. A generated Listening Map is unnecessary."
        }
        if !selectedItem.chapters.isEmpty {
            return "This item already has a Listening Map."
        }
        guard let item = try? store?.loadItem(id: activeItemId) else {
            return "Listening Map generation is unavailable."
        }
        if item.media != nil {
            return "Prepare a private episode fingerprint map. Supported iOS 26 devices also generate on-device scene summaries."
        }
        return "Listening Map generation is unavailable."
    }

    static let supportedMediaSkipSeconds = MediaSkipRule.supportedSeconds
    static let supportedPodcastCacheLimitsGB = PodcastCacheLimitGB.allCases.map(\.rawValue)
    static let supportedRenderedSpeechCacheLimitsMB = [128, 256, 512, 1_024]

    private static func storedMediaSkipSeconds(forKey key: String) -> Int {
        MediaSkipRule.validated(UserDefaults.standard.integer(forKey: key))
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
                itemId: pendingJob.itemId,
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
        if let pendingJob = pendingProviderJobForConsent {
            markProviderFailure("ai_data_sharing_not_allowed", userMessage: "Live AI request cancelled. No content was sent.", itemId: pendingJob.itemId)
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
        navigationRefreshTask?.cancel()
        playbackProgressTask?.cancel()
        onDeviceSpeechGenerationDelayTask?.cancel()
        trashUndoDismissTask?.cancel()
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        libraryAudioLoop.cancelOnly()
        sourceImportTask?.cancel()
        importedCommentaryAutoPlayTask?.cancel()
        bulkSharePreparationTask?.cancel()
        offlineServicesStartupTasks.forEach { $0.cancel() }
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
                await MainActor.run { self?.hangTelemetry.labels.scoped("playbackTick") { self?.tickPlaybackProgress() } } // a stuck tick holds play at starting (#2255)
            }
        }
    }

    /// One progress tick. The start cue (#357) also calls it to check the player before its chime.
    func tickPlaybackProgress() {
        guard snapshot.status.isPlaybackActive else { stopPlaybackProgressTicker(); return }
        guard let engine = self.engine else { return }
        do {
            self.synchronizeStreamingSpeechAnchorIfNeeded()
            let previousSnapshot = self.snapshot
            let previousStatus = self.snapshot.status
            let previousTargetId = self.snapshot.targetId
            let previousEngagementProgress = self.snapshot.currentPlaybackProgressPercent
            let updated = self.snapshotReflectingTextAudioPrewarmStatus(
                try engine.syncPlaybackProgress(),
                itemId: self.activeItemId
            )
            self.recordMediaSeekEvidence(from: engine)
            let completedCurrentAudio = previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
            if updated != self.snapshot {
                self.snapshot = updated
            }
            self.listeningSignals.playbackProgress(itemId: updated.itemId, status: updated.status, transport: engine.currentPlaybackTransportState())
            self.updateNarrationVoiceNotice()
            if SourceFollowSuggestionPolicy.crossedEngagementThreshold(
                previous: previousEngagementProgress, current: updated.currentPlaybackProgressPercent
            ),
               let itemId = updated.itemId,
               let store = self.store {
                self.offerFollowSuggestionIfEligible(itemId: itemId, store: store)
            }
            self.reconcileImportedCommentary(previous: previousSnapshot, current: updated)
            self.observeMarginMoment(updated)
            let playedPendingTurn = self.playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
            if completedCurrentAudio && !playedPendingTurn {
                self.closeCompletedSessionIfReady()
            }
        } catch {
            self.diagnostics["playbackProgressSyncError"] = String(describing: error)
        }
    }

    private func stopPlaybackProgressTicker() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
        listeningSignals.endListening()
    }

    func syncPlaybackProgressForLifecycle(refreshingItem: Bool = true) {
        guard snapshot.status.isPlaybackActive, let engine else { return }
        do {
            synchronizeStreamingSpeechAnchorIfNeeded()
            let previousStatus = snapshot.status
            let previousTargetId = snapshot.targetId
            let updated = snapshotReflectingTextAudioPrewarmStatus(
                try hangTelemetry.labels.scoped("lifecycleSync") { try engine.syncPlaybackProgress() },
                itemId: activeItemId
            )
            recordMediaSeekEvidence(from: engine)
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
            if refreshingItem || completedCurrentAudio { refreshSelectedItem() }
            diagnostics["playbackLifecycleSync"] = "saved"
        } catch {
            diagnostics["playbackLifecycleSyncError"] = String(describing: error)
        }
    }

    func refreshLockScreenSurfacesForLifecycle() {
        gate2CompactControls.reconcileLiveActivities()
        diagnostics["lockScreenLifecycleRefresh"] = snapshot.targetType ?? "none"
    }

    func handleAppBecameInactiveOrBackground(entersBackground: Bool = false) {
        if entersBackground { narrationStartupProtection.appEnteredBackground(); hangTelemetry.setForeground(false) }; reconcileNarrationOwnership(trigger: entersBackground ? "background" : "inactive")
        marginOutput.finishBeforeBackground(); readwiseHighlightSync.stop()
        OnDeviceVoiceGovernor.app.setAppBackgrounded(true) // every on-device voice is paced while away (#1679)
        syncPlaybackProgressForLifecycle(refreshingItem: false) // saves the position; re-reading the item decoded a mapped transcript on main as iOS waited, unseen (#2184)
        refreshLockScreenSurfacesForLifecycle()
        scheduleAutomaticAudioPreparationIfNeeded()
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

    func handleAppBecameActive() {
        startHangTelemetry(); narrationStartupProtection.appEnteredForeground(); reconcileNarrationOwnership(trigger: "foreground")
        openReadyListeningEdition()
        marginOutput.start(); readwiseHighlightSync.start { [weak self] in self?.store }
        if let store { CommunityMapUploadService.shared.retryFailed(store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 } }
        OnDeviceVoiceGovernor.app.setAppBackgrounded(false)
        let refreshedAvailability = localFoundationModelClient.availability()
        if refreshedAvailability != localFoundationModelAvailability {
            localFoundationModelAvailability = refreshedAvailability
            diagnostics["localFoundationModelAvailability"] = refreshedAvailability.description
            _ = rebuildEngineForCurrentSettings()
        }
        syncPlaybackProgressForLifecycle()
        gate2CompactControls.reconcileLiveActivities()
        importPendingSourceLinkHandoffs()
        if let store {
            try? refreshLibraryRows(store: store)
            try? refreshAudioPreparationPresentation(store: store, announceNewCompletions: true)
        }
        scheduleAutomaticAudioPreparationIfNeeded()
        submitAutomaticEpisodeMapPreparationIfNeeded()
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() } // a background task may have ended while the app was away (#534)
        refreshQuickAddFeed(force: false)
    }

    func offlineStorageBudgetChanged() {
        guard OfflineStorageBudget.allowedGigabytes.contains(offlineStorageLimitGB) else {
            offlineStorageLimitGB = 5
            return
        }
        UserDefaults.standard.set(offlineStorageLimitGB, forKey: "offlineStorageLimitGB")
        podcastCacheLimitGB = offlineStorageLimitGB
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                try store.saveOfflineStorageBudget(OfflineStorageBudget(
                    limitBytes: Int64(self.offlineStorageLimitGB) * OfflineStorageBudget.bytesPerGigabyte
                ))
                _ = try await self.offlineStorageLedger?.enforceBudget()
                self.tryRefreshOfflineStorageUsage()
            } catch {
                self.reportFailure(error, context: "Offline storage budget update failed")
            }
        }
    }

    func clearReproducibleOfflineAudio() {
        guard let ledger = offlineStorageLedger else { return }
        Task { [weak self, renderedSpeechDiskCache = self.renderedSpeechDiskCache] in
            do {
                let bytes = try await ledger.clearReproducibleAudio(renderedSpeechCache: renderedSpeechDiskCache)
                await MainActor.run {
                    self?.reportConfirmation("Cleared \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of reproducible offline audio.")
                    self?.tryRefreshOfflineStorageUsage()
                }
            } catch {
                await MainActor.run { self?.reportFailure(error, context: "Offline audio clear failed") }
            }
        }
    }

    func refreshMarginRows() {
        do {
            let store = try requireStore()
            // Library rows refresh asynchronously on navigation. Retrieval must
            // use durable membership so freshly imported items are not omitted.
            let entries = try MarginCollection.build(
                items: store.listItems(), sessions: store.loadSessions(), loadMap: { try? store.loadListeningMap(itemId: $0) }, loadMediaChapters: { (try? store.loadTranscriptTimelineChapters(itemId: $0)) ?? [] },
                loadInterjections: { try store.loadInterjections(sessionId: $0) },
                loadImportedLayers: { try store.loadImportedCommentaryLayers() },
                loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) }
            )
            sharedMarginRows = entries.sharedRows.map {
                SharedMarginRow(interjection: $0.interjection, layer: $0.layer, itemTitle: $0.itemTitle,
                                placement: sharedMarginPlacementPasses.pass(itemId: $0.layer.itemId))
            }
            marginRows = entries.privateRows.map {
                MarginRow(interjection: $0.interjection, itemTitle: $0.itemTitle, sessionDate: $0.sessionDate, place: $0.place)
            }
            marginOutput.deliverSoon() // A Margin or its transcript may be new (#171).
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    var marginScopeItems: [LibraryItemRow] {
        let ids = Set(marginRows.map { $0.interjection.itemId } + sharedMarginRows.compactMap { $0.layer.itemId } + [selectedItem.id])
        return libraryItems.filter { ids.contains($0.id) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var visiblePrivateMarginRows: [MarginRow] {
        marginRows.filter { row in
            let matchesFilter: Bool
            switch marginCollectionQuery.filter {
            case .all: matchesFilter = true
            case .starred: matchesFilter = row.interjection.isStarredForSharing == true
            case .attention: matchesFilter = row.needsAttention
            case .shared: matchesFilter = false
            }
            return matchesFilter && marginCollectionQuery.includes(itemID: row.interjection.itemId) && marginCollectionQuery.matches([row.fullText, row.itemTitle])
        }
    }

    var visibleSharedMarginRows: [SharedMarginRow] {
        guard marginCollectionQuery.filter == .shared else { return [] }
        return sharedMarginRows.filter {
            marginCollectionQuery.includes(itemID: $0.layer.itemId) && marginCollectionQuery.matches([$0.interjection.approvedTranscript, $0.itemTitle, $0.collectionLabel])
        }
    }

    func marginSourceContext(_ row: MarginRow) -> String? {
        MarginCollection.sourceContext(anchorBefore: row.interjection.anchor.anchorBefore, anchorAfter: row.interjection.anchor.anchorAfter)
    }

    /// Opens the Margin a notes-folder link names (#171).
    func openMargin(_ link: MarginDeepLink) {
        bootstrapLibraryIfNeeded() // A cold launch from the link can arrive before the root view loads the Library.
        let matches = { (row: MarginRow) in row.interjection.sessionId == link.sessionId && row.interjection.id == link.marginId }
        if !marginRows.contains(where: matches) { refreshMarginRows() }
        guard let row = marginRows.first(where: matches) else { return reportFailure("This Margin is no longer in your Library.") }
        openMarginInTimeline(row)
    }

    func openMarginInTimeline(_ row: MarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margin_timeline") else { return }
        let opening = MarginTimelineOpening.decide(
            loadedSessionID: snapshot.sessionId, marginSessionID: row.interjection.sessionId, loadedSessionIsPlaying: activePlaybackIsPlaying)
        if opening == .keepNowPlaying {
            reportWarning("This Margin belongs to another session. Now Playing was left unchanged.")
            diagnostics["marginTimelineNavigation"] = "blocked_active_session_replacement"
            return
        }
        do {
            let store = try requireStore()
            if opening == .openMarginSession {
                guard let session = try store.loadSession(id: row.interjection.sessionId) else { throw SessionKitError.persistenceFailed("margin_session_missing") }
                openSession(session) // A paused session (#638) is saved and stopped there, never played.
                guard snapshot.sessionId == session.id else { return } // openSession reported why.
            }
            requestedTimelineFocusMarginID = row.id
            screen = .timeline
        } catch {
            reportFailure(error, context: "Open Margin failed")
        }
    }

    @discardableResult
    func playMarginMoment(_ row: MarginRow) -> Bool {
        guard !rejectNavigationOrSessionMutationWhileRecording("play_margin_moment") else { return false }
        let previousItemID = snapshot.itemId
        do {
            let store = try requireStore()
            guard let session = try store.loadSession(id: row.interjection.sessionId),
                  session.itemId == row.interjection.itemId,
                  let interjection = try store.loadInterjections(sessionId: session.id).first(where: {
                      $0.id == row.interjection.id && $0.sessionId == session.id
                          && $0.itemId == session.itemId && $0.status == "active"
                  }) else {
                throw SessionKitError.invalidCommandForState("This Margin's listening session is unavailable.")
            }
            let detail = try loadItemDetail(id: session.itemId, store: store)
            if engine == nil { installEngine(try makeEngine(store: store)) }
            guard let engine else { return false }
            if blockOfflineEpisodeStart(itemId: session.itemId) { return false }
            // URL registration is separate from selection; the engine owns exact
            // target validation and the reversible playback transaction.
            try prepareSourceMediaPlayback(itemId: session.itemId)
            endMarginMoment()
            snapshot = try playAnchorAtShownRate(interjection, engine: engine)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            stopInterjectionAudioPlayback()
            activeItemId = session.itemId
            selectedItem = detail
            if previousItemID != session.itemId { resetMixWithOtherAudioForNewSession() }
            startMarginMomentIfSpoken(interjection, store: store)
            screen = .playback
            lastError = nil
            return true
        } catch {
            if let engine { snapshot = engine.snapshot }
            if let previousItemID { podcastDownloadCoordinator?.configureActiveItem(previousItemID) }
            reportFailure(error, context: "Could not play this Margin's position")
            return false
        }
    }

    /// Tapping a shared Margin in the Timeline plays its moment (#158): a lead-in, their voice, then the item.
    /// Position is the best the app has: a verified or interpolated match, else the sender's own time.
    func playSharedMarginMoment(_ row: SharedMarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("play_shared_margin_moment") else { return }
        guard let itemID = row.layer.itemId else {
            reportFailure("The source for this shared Margin isn't in your Library.")
            return
        }
        guard let position = SharedMarginPlaybackPosition(row.interjection) else {
            reportFailure("This shared Margin has no position in the episode.")
            return
        }
        guard let voiceURL = row.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) else {
            reportFailure("This shared Margin contains reviewed text but no playable voice recording.")
            return
        }
        endMarginMoment(); stopInterjectionAudioPlayback() // one Margin voice at a time: a paused one of yours mustn't take the resume below (#1672)
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID else { return }
        // The moment plays this voice; the automatic shared-Margin prompt mustn't play it again.
        sharedMarginOffers.markAnnounced(row.interjection.id)
        let targetID = "shared::\(row.layer.id)::\(row.interjection.id)"
        startMarginMoment(
            sequence: MarginMomentSequence(itemId: itemID, target: MarginMomentAnchor(marginId: targetID, mediaTimeMs: position.mediaTimeMs), otherMargins: []),
            voiceURLs: [targetID: voiceURL],
            title: "\(row.collectionLabel)'s Margin",
            isApproximate: position.isApproximate
        )
        marginMomentConductor?.onVoiceStarted = { [weak self] in if $0 == targetID { self?.markSharedMarginHeard(row.interjection) } }
        // Their voice gets the same chime as the automatic prompt, unless the layer is muted (#932).
        marginMomentConductor?.chimedMarginIds = row.layer.isMuted ? [] : [targetID]
        marginMomentConductor?.onChimeStarted = { [weak self] in self?.diagnostics["marginMoment.chime"] = "played:\($0)" }
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        screen = .playback
    }

    /// Runs `sequence` through the conductor: a Margin moment (#159) or a review of new Margins (#474). `listening`
    /// starts it already listening (#1538): no lead-in, no seek, only Margins after the current position play.
    func startMarginMoment(
        sequence: MarginMomentSequence,
        voiceURLs: [String: URL],
        title: String,
        isApproximate: Bool,
        listening: Bool = false,
        clock: MarginMomentClock = .media
    ) {
        marginMomentClock = clock
        let conductor = MarginMomentConductor(
            sequence: sequence,
            source: .init(
                pause: { [weak self] in self?.pause() },
                resume: { [weak self] in self?.resumePlayback() },
                seek: { [weak self] in self?.seekMarginMomentSource(toPosition: $0) }
            ),
            voiceURL: leveledVoiceURL(voiceURLs, itemId: sequence.itemId, margins: [sequence.target] + sequence.unplayed)
        )
        conductor.voiceRate = Float(recordMarginVoiceRate("moment"))
        conductor.prepareAudioSession = { [weak self] in try self?.prepareMarginMomentVoice() }
        conductor.onVoiceUnavailable = { [weak self] (marginId: String, reason: String) in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            self?.reportWarning("That Margin's recording couldn't play, so listening continues.")
        }
        conductor.onChange = { [weak self, weak conductor] in
            guard let self, let conductor, self.marginMomentConductor === conductor else { return }
            self.marginMoment = conductor.sequence
            self.marginMomentVoiceIsPaused = conductor.isVoicePaused
            if !conductor.isPlayingVoice { self.recordMarginMomentVoiceEnded() }
            // Nothing left to play inline: the card goes away and the item simply continues.
            if conductor.sequence.phase == .listening, conductor.sequence.unplayed.isEmpty { self.endMarginMoment() }
        }
        marginMomentConductor = conductor
        marginMomentTitle = title
        marginMomentPositionIsApproximate = isApproximate
        startMarginMomentLeadIn(conductor, target: sequence.target, itemId: sequence.itemId, resuming: listening)
        diagnostics["marginMoment.chime"] = nil
        if listening {
            diagnostics["marginMoment"] = "started:listening;later=\(sequence.unplayed.count)"
            return
        }
        diagnostics["marginMoment"] = "started:lead_in_ms=\(sequence.target.mediaTimeMs - sequence.startMediaTimeMs);others=\(sequence.unplayed.count - 1);approximate=\(isApproximate);clock=\(clock.isNarratedText ? "narrated_text" : "media")"
    }

    /// "Play it now" on the coming-up cue.
    func playMarginMomentNow() {
        marginMomentConductor?.playTargetNow()
    }

    /// Stops the Margin that's playing and continues the item.
    func skipMarginMomentVoice() {
        marginMomentConductor?.skipVoice()
    }

    /// Stops playing Margins inline. The item keeps its current play state.
    func endMarginMoment() {
        giveBackUnfinishedReview()
        recordMarginMomentVoiceEnded()
        marginMomentConductor?.cancel()
        marginMomentConductor = nil
        marginMoment = nil
        marginMomentVoiceIsPaused = false
    }

    private func observeMarginMoment(_ current: SessionSnapshot) {
        guard let conductor = marginMomentConductor else { return }
        guard current.itemId == conductor.sequence.itemId else { return endMarginMoment() }
        conductor.observe(mediaTimeMs: marginMomentPositionMs(in: current))
    }

    func tryRefreshOfflineStorageUsage() {
        guard let ledger = offlineStorageLedger else { return }
        Task { [weak self] in
            guard let snapshot = try? await ledger.presentationSnapshot() else { return }
            await MainActor.run {
                self?.offlineStorageSnapshot = snapshot
                let base = "\(ByteCountFormatter.string(fromByteCount: snapshot.usedBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: snapshot.budgetBytes, countStyle: .decimal)) used · \(ByteCountFormatter.string(fromByteCount: snapshot.protectedBytes, countStyle: .decimal)) protected"
                self?.offlineStorageUsageDescription = snapshot.currentOverageBytes > 0
                    ? "\(base) · \(ByteCountFormatter.string(fromByteCount: snapshot.currentOverageBytes, countStyle: .decimal)) over budget"
                    : base
            }
        }
    }

    func handleApplicationWillTerminate() {
        stopImportedCommentaryPlayback(resumeSource: false)
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        syncPlaybackProgressForLifecycle(refreshingItem: false) // the item isn't shown again; iOS gives this a deadline (#2184)
        narrationStartupProtection.stop()
        gate2CompactControls.endLiveActivities()
    }

    func handleMemoryWarning() {
        Self.preparationPlanCache.removeAll()
        activePlaybackDetail = nil
        SupertonicResourcePolicy.memoryBackoff.recordWarning()
        // Cancel demand before unloading: otherwise the next chunk can reload
        // the same sessions immediately after the warning.
        libraryAudioLoop.cancelOnly()
        if let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient {
            do {
                if try stopOnDeviceRenderingRecordingFallback(client, returnsAutomatically: true, code: "memory_warning_stop", reason: .memoryWarning) {
                    speechFallbackReason = .memoryWarning
                    let message = SpeechFallbackReason.memoryWarning.listenerExplanation
                    statusMessage = message
                    presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
                }
            } catch {
                reportFailure(error, context: "Memory-pressure voice recovery failed")
            }
        }
        diagnostics["supertonicMemoryPressure"] = "sessions_unloaded"
        unloadNarrationRenderers(removingGeneratedAudio: false)
    }

    func makeAppOverviewSample() throws -> (Item, ListeningMap) {
        try WelcomeSample.make(itemId: Self.welcomeSampleItemId, remoteProviderExperienceEnabled: remoteProviderExperienceEnabled)
    }

    @discardableResult func importBrowserTextInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws -> String {
        let item = try browserTextImportEngine().importBrowserTextInBackground(Self.sanitizedBrowserTextHandoff(handoff), structuredDocument: structuredDocument)
        return try finishBackgroundBrowserTextImport(item, handoff: handoff)
    }

    func browserTextImportEngine() throws -> SessionEngine {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine else {
            throw SessionKitError.persistenceFailed("Browser text importer is unavailable.")
        }
        return engine
    }


    @discardableResult
    func importBrowserText(_ handoff: BrowserTextHandoff) -> Bool {
        importBrowserTextItem(handoff) != nil
    }

    /// `importBrowserText`, returning the new item's id, or nil when the import failed.
    /// `opensItem: false` (the Link field, Paste & go) adds an article in the background with the shared add confirmation (#828).
    func importBrowserTextItem(_ handoff: BrowserTextHandoff, opensItem: Bool = true) -> String? {
        do {
            if hasActiveSession || (!opensItem && !handoff.requestedContinuation.startSession) {
                let itemId = try importBrowserTextInBackground(handoff)
                if opensItem { openItem(id: itemId) } // #1437: a share shows its item whatever is in Now Playing; playback is untouched
                reportAddedToLibrary(title: handoff.source.title, itemId: itemId)
                return itemId
            }
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
            return importedItemId
        } catch {
            reportFailure(error, context: "Browser text import failed")
            return nil
        }
    }

    func start() {
        guard !blockOfflineEpisodeStart(itemId: activeItemId) else { return }
        guard !requireTermsDecisionBeforePlayback(.startCurrentItem) else { return }
        if !hasActiveSession {
            resetMixWithOtherAudioForNewSession()
        }
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
        narrationStartupProtection.protectUpcomingStart(eligible: narrationRendersOnDevice(itemId: activeItemId))
        run { engine in
            try prepareSourceMediaPlayback(itemId: activeItemId)
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
        reconcileNarrationStartupProtection()
    }

    private func reconcileNarrationStartupProtection() {
        let itemId = snapshot.itemId
        narrationStartupProtection.statusChanged(to: snapshot.status, itemId: itemId) {
            itemId.map { narrationRendersOnDevice(itemId: $0) } ?? false
        }
    }

    /// Supertonic renders the narration on the phone, so its start has no audio keeping a backgrounded app alive.
    private func narrationRendersOnDevice(itemId: String) -> Bool {
        ttsVoiceSelection.isOnDeviceVoice && !playsPublisherAudio(itemId: itemId)
            && (try? store?.loadItem(id: itemId))?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func playPause() {
        if marginVoiceIsHeldForRecording { return } // a Margin is recording over the voice; nothing plays until it ends
        if playingImportedCommentary != nil {
            // Pause while it sounds or loads; Play (resume, or Retry after a failure) otherwise (#941).
            setImportedCommentaryPaused(importedCommentaryPhase.showsPause)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice {
            conductor.setVoicePaused(!conductor.isVoicePaused)
            return
        }
        if ownMarginVoiceHasTransport {
            setOwnMarginPaused(!ownMarginVoiceIsPaused)
            return
        }
        if snapshot.phase == .finished, let itemID = snapshot.itemId {
            startNewSession(id: itemID)
            return
        }
        if let bridge = snapshot.skimBridgeState {
            setSkimBridgePaused(bridge.status == .playing)
            return
        }
        if snapshot.status.isPlaybackActive {
            pause()
        } else if hasActiveSession {
            resumePlayback()
        } else {
            start()
        }
    }

    func pause() {
        if marginVoiceIsHeldForRecording { return }
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(true)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice, !conductor.isVoicePaused {
            conductor.setVoicePaused(true)
            return
        }
        if ownMarginVoiceHasTransport, !ownMarginVoiceIsPaused {
            setOwnMarginPaused(true)
            return
        }
        if snapshot.skimBridgeState != nil {
            setSkimBridgePaused(true)
            return
        }
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.pause()
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItemInBackground()
            reportSuccess("Paused.")
        }
    }

    var sleepTimerIsActive: Bool {
        SleepTimerPolicy.isActive(sleepTimerState)
    }

    var sleepTimerDescription: String {
        SleepTimerPolicy.description(state: sleepTimerState, remainingSeconds: sleepTimerRemainingSeconds)
    }

    var canUseEndOfChapterSleepTimer: Bool {
        SleepTimerPolicy.endOfChapterTarget(chapters: selectedItem.mediaChapters, currentMediaTimeMs: snapshot.currentMediaTimeMs) != nil
    }

    func armSleepTimer(_ mode: SleepTimerMode) {
        guard let state = SleepTimerPolicy.arm(mode, now: Date(), chapters: selectedItem.mediaChapters, currentMediaTimeMs: snapshot.currentMediaTimeMs) else { return }
        sleepTimerState = state
        startSleepTimerTicker()
        reconcileSleepTimer(now: Date())
    }

    func extendSleepTimerBy15Minutes() {
        let now = Date()
        sleepTimerState = SleepTimerPolicy.extend(sleepTimerState, now: now)
        startSleepTimerTicker()
        reconcileSleepTimer(now: now)
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerState = .inactive
        sleepTimerRemainingSeconds = nil
    }

    private func startSleepTimerTicker() {
        sleepTimerTask?.cancel()
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reconcileSleepTimer(now: Date())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func reconcileSleepTimer(now: Date) {
        if let mode = SleepTimerPolicy.reconcile(
            state: &sleepTimerState, remainingSeconds: &sleepTimerRemainingSeconds,
            now: now, isRecording: snapshot.isRecording,
            currentMediaTimeMs: snapshot.currentMediaTimeMs, chapters: selectedItem.mediaChapters
        ) {
            if snapshot.status.isPlaybackActive { pause() }
            releaseOwnMarginReturn()
            cancelSleepTimer()
            reportConfirmation(SleepTimerPolicy.expiryConfirmation(mode: mode))
        }
    }

    func stopOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else {
            reportFailure("On-device voice generation is not active for this playback.")
            return
        }
        do {
            if snapshot.status.isPlaybackActive, let engine {
                snapshot = snapshotReflectingTextAudioPrewarmStatus(
                    try engine.syncPlaybackProgress(),
                    itemId: activeItemId
                )
            }
            guard try stopOnDeviceRenderingRecordingFallback(client, code: "listener_stop", reason: .listenerStoppedGeneration) else {
                reportFailure("There is no active Supertonic generation to stop.")
                return
            }
            speechFallbackReason = .listenerStoppedGeneration
            suppressAudioPreparation(itemId: activeItemId)
            if let coordinator = preparedAudioCoordinator,
               let signature = currentSupertonicRenderSignature {
                let itemId = activeItemId
                Task {
                    try? await coordinator.stop(itemId: itemId, signature: signature)
                }
            }
            if let engine {
                snapshot = snapshotReflectingTextAudioPrewarmStatus(
                    try engine.syncPlaybackProgress(),
                    itemId: activeItemId
                )
                refreshSelectedItem()
            }
            onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.stopped.rawValue
            onDeviceSpeechGenerationDelayTask?.cancel()
            onDeviceSpeechGenerationDelayTask = nil
            isOnDeviceSpeechGenerationDelayed = false
            diagnostics["onDeviceSpeechGeneration"] = "stopped_by_user"
            reportConfirmation("Stopped on-device voice generation. Playback is continuing with the iOS system voice.")
        } catch {
            reportFailure(error, context: "Stop on-device voice generation failed")
        }
    }

    func resumePlayback() {
        if marginVoiceIsHeldForRecording { return }
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(false)
            return
        }
        if let conductor = marginMomentConductor, conductor.isVoicePaused {
            conductor.setVoicePaused(false)
            return
        }
        if ownMarginVoiceHasTransport, ownMarginVoiceIsPaused {
            setOwnMarginPaused(false)
            return
        }
        if snapshot.skimBridgeState != nil {
            setSkimBridgePaused(false)
            return
        }
        guard let sessionId = snapshot.sessionId else {
            reportFailure("There is no listening session to resume.")
            return
        }
        if let itemId = snapshot.itemId, blockOfflineEpisodeStart(itemId: itemId) { return }
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
        if let item = selectedItemRecord,
           item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream {
            isGeneratingListeningMap = false
            prepareEpisodeMap(itemId: item.id, policy: .explicit)
            return
        }
        if !remoteProviderExperienceEnabled {
            guard selectedItemRecord?.media == nil else {
                diagnostics["lastListeningMapMode"] = "on_device_generation_disabled"
                isGeneratingListeningMap = false
                reportFailure("Publisher chapters appear when available. AI-generated podcast maps are reserved for a future server-hosted option.")
                return
            }
            generateLocalListeningMap(confirmation: "Generated Listening Map.")
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
            generateLocalListeningMap(confirmation: "Generated local Listening Map.")
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
            let firstPrompt = ProviderPrompts.listeningMap(sourceText: text)
            let firstResponse = try await callProvider(messages: [firstPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
            do {
                try saveProviderListeningMapResponse(firstResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "0"
                reportConfirmation("Generated Listening Map with \(model).")
            } catch {
                let repairPrompt = ProviderPrompts.listeningMapRepair(sourceText: text, invalidResponse: firstResponse, error: String(describing: error))
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
        let map = try ManualListeningMapParser.parse(response, item: item)
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

    private func generateLocalListeningMap(confirmation: String) {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            diagnostics["lastListeningMapMode"] = "local_deterministic"
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportConfirmation(confirmation)
        }
    }

    /// Why a friend's shared map couldn't be placed on this item's copy, as stored on its packets (#481).
    func sharedListeningMapRefusal(itemId: String) -> String? {
        guard let store, let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              let hasMap = try? Self.listenerHasListeningMap(itemId: itemId, store: store) else { return nil }
        return SharedListeningMapPlacement.storedRefusalReason(layers: layers, listenerHasMap: hasMap)
    }

    /// The listener's own map or the publisher's chapters, which a friend's map never replaces.
    static func listenerHasListeningMap(itemId: String, store: SQLiteSessionStore) throws -> Bool {
        try store.loadPortableListeningMapProposals(itemId: itemId).contains { !CommunityMapConverter.isCommunityProposal(id: $0.id) } // a community map never blocks a friend's (#553)
            || store.loadTranscriptTimelineChapters(itemId: itemId).isEmpty == false // chapters only: this runs from the Item screen's body (#2073)
    }

    lazy var skimBridge = SkimBridgeController(host: self) // the Skim bridge's player, poll, resources and destinations (#954)

    func applyListeningMapJSON() {
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            let map = try ManualListeningMapParser.parse(listeningMapJSON, item: item)
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

    var visibleLibraryItems: [LibraryItemRow] {
        LibraryQueryEngine.visibleLibraryItems(libraryItems, query: libraryQuery)
    }

    static func loadLibraryListeningFilter(defaults: UserDefaults) -> LibraryListeningStateFilter {
        LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults)
    }

    var libraryIsCaughtUp: Bool {
        LibraryQueryEngine.libraryIsCaughtUp(libraryItems, query: libraryQuery)
    }

    var libraryHidesCompleted: Bool {
        LibraryQueryEngine.libraryHidesCompleted(query: libraryQuery)
    }

    func showCompletedLibraryItems() {
        libraryQuery.listeningState = .completed
        libraryQueryChanged()
    }

    func resetLibraryFilters() {
        // Preserve the search and sort while restoring the everyday view.
        libraryQuery.resetFilters()
        libraryQueryChanged()
    }

    func libraryQueryChanged() {
        let persisted = libraryQuery.persistedSelection
        UserDefaults.standard.set(persisted.contentType.rawValue, forKey: "libraryContentTypeFilter")
        UserDefaults.standard.set(persisted.listeningState.rawValue, forKey: "libraryListeningStateFilter")
        UserDefaults.standard.set(persisted.offlineState.rawValue, forKey: "libraryOfflineStateFilter")
        UserDefaults.standard.set(persisted.sort.rawValue, forKey: "librarySort")
    }

    var libraryFilterDescription: String {
        LibraryQueryEngine.libraryFilterDescription(query: libraryQuery)
    }

    var librarySortDescription: String {
        LibraryQueryEngine.librarySortDescription(query: libraryQuery)
    }

    func startItem(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_item") else { return }
        prepareImportedLocalAudioBridges(itemId: id); fetchCommunityMapIfNeeded(itemId: id)
        if [.waiting, .preparing].contains(libraryItems.first(where: { $0.id == id })?.startupAudioState) {
            scheduleStartupAudioPreparationIfNeeded(itemId: id)
            diagnostics["startupAudioPlayback:\(id)"] = "started_without_waiting_for_opening_buffer"
        }
        do {
            let store = try requireStore()
            if let continuation = Self.preferredContinuationSession(in: try store.loadSessions(itemId: id)),
               continuation.phase != .finished, continuation.status != "finished", continuation.completionPercent < 100 {
                resumeSession(continuation)
            } else {
                startNewSession(id: id)
            }
        } catch {
            reportFailure(error, context: "Continue listening failed")
        }
    }

    func startNewSession(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_new_session") else { return }
        // Before ending what's playing: a blocked start must not stop a downloaded episode.
        guard !blockOfflineEpisodeStart(itemId: id) else { return }
        endUnfinishedReview()
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        resetMixWithOtherAudioForNewSession()
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        cancelSleepTimer()
        sharedMarginOffers.removeAll()
        pendingImportedCommentary = nil
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if hasActiveSession, let engine {
            _ = try? endEngineSession(engine, reason: .startNewSession)
            snapshot = engine.snapshot
        }
        activeItemId = id
        start()
    }

    func openSession(_ session: Session) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_session") else { return }
        endUnfinishedReview()
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        resetMixWithOtherAudioForNewSession()
        sharedMarginOffers.removeAll()
        pendingImportedCommentary = nil
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
            try prepareSourceMediaPlayback(itemId: session.itemId)
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
        guard !rejectNavigationOrSessionMutationWhileRecording("resume_session") else { return }
        guard !blockOfflineEpisodeStart(itemId: session.itemId) else { return }
        endUnfinishedReview()
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        resetMixWithOtherAudioForNewSession()
        cancelSleepTimer()
        sharedMarginOffers.removeAll()
        pendingImportedCommentary = nil
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
            try prepareSourceMediaPlayback(itemId: session.itemId)
            let completion = (try? store.loadSession(id: session.id))?.completionPercent ?? session.completionPercent // the row on screen can lag a skip (#2102)
            do {
                if completion >= 100 {
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
            reportSuccess(completion >= 100
                ? "Opened completed session. Use Play from Beginning to restart."
                : "Resumed session at \(completion)% complete.")
        } catch {
            reportFailure(error, context: "Resume session failed")
        }
    }

    func prioritizeOfflinePreparation(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if libraryItems.first(where: { $0.id == id })?.offlineState == .readyOffline {
                reportConfirmation("\(item.title) is already available offline.")
                return
            }

            switch item.media?.sourceType {
            case .some(.nativeMediaFile):
                reportConfirmation("\(item.title) is already available offline.")
            case .some(.remoteStream):
                guard let rawURL = item.media?.url, let remoteURL = URL(string: rawURL) else {
                    reportFailure("This audio item does not have a downloadable source.")
                    return
                }
                if podcastDownloadCoordinator?.downloadNow(itemId: id) != true {
                    podcastDownloadCoordinator?.register(itemId: id, remoteURL: remoteURL, userInitiated: true)
                }
                reportConfirmation("Prioritized \(item.title) for download.")
            case .some(.browserOwnedMedia):
                reportFailure("Browser-owned audio cannot be downloaded by Spoken Margins.")
            case .none, .some(.generatedTTSRealtime), .some(.generatedTTSPrerendered):
                guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    reportFailure("This item does not have text that can be prepared for offline listening.")
                    return
                }
                guard hasAcceptedCurrentTerms, ttsVoiceSelection.supertonicVoice != nil else {
                    reportWarning("Offline preparation needs James or Lily, with the Terms accepted.")
                    return
                }
                Task { [weak self] in
                    await self?.enqueueExplicitAudioPreparation(item: item)
                }
            }
        } catch {
            reportFailure(error, context: "Offline preparation failed", itemId: id)
        }
    }

    func dismissFeedback(id: UUID? = nil) {
        guard id == nil || feedbackEvent?.id == id else { return }
        feedbackEvent = nil
    }

    func clearLastFailure(itemId: String) { itemFailures.clear(itemId: itemId) }

    /// Trying an action again answers its Retry banner, so a stale one can't linger over the result.
    func withdrawRetryOffer(_ key: String) { if feedbackEvent?.retry?.key == key { feedbackEvent = nil } }

    func redownloadSelectedPodcast() {
        guard let coordinator = podcastDownloadCoordinator else { return }
        let alreadyDownloading = coordinator.recordsByItemId[selectedItem.id]?.state == .downloading
        requestedPodcastTransportReplacements.insert(selectedItem.id)
        if coordinator.recordsByItemId[selectedItem.id] == nil {
            prioritizeOfflinePreparation(id: selectedItem.id)
        } else { coordinator.redownload(itemId: selectedItem.id) }
        reportConfirmation(alreadyDownloading ? "Already downloading. Progress shows on this screen." : "Downloading a fresh copy of the podcast.")
    }

    func downloadSelectedPodcastNow() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download is unavailable.")
            return
        }
        if podcastDownloadCoordinator?.downloadNow(itemId: selectedItem.id) == true {
            reportSuccess("Starting podcast download. Available storage will be checked first.")
        } else {
            reportWarning("The download could not start yet. Check the connection and try again.")
        }
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

    func autoPlayCompletedTurn(
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
        guard snapshot.phase == .finished else { return }
        if let store {
            try? refreshLibraryRows(store: store)
        }
        refreshMarginRows()
        diagnostics["completedSessionPresentation"] = "retained_finished_session"
        reportConfirmation("Session complete and saved.")
    }

    func shouldDeferGeneratedTurnPlayback(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: turnId,
            completedCurrentAudio: completedCurrentAudio
        )
    }

    private func enqueuePendingAutoPlayTurn(_ turnId: String) {
        pendingAutoPlayQueue.enqueue(turnId)
        updatePendingAutoPlayDiagnostics(reason: "waiting_for_current_audio")
    }

    func clearPendingAutoPlayTurns() {
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

    func importedCommentaryPrompts(includeAnnounced: Bool) -> [ImportedCommentaryPrompt] {
        SharedMarginPrompts.prompts(
            layers: selectedItem.importedCommentaryLayers,
            recordsByLayerID: selectedItem.importedCommentaryInterjections,
            announcedIDs: includeAnnounced ? [] : sharedMarginOffers.announcedIDs, // nextOffer's autoclosure runs inside its modify of sharedMarginOffers
            includeAnnounced: includeAnnounced
        )
    }

    nonisolated static func isPlayableImportedCommentaryResolution(_ resolution: ImportedAnchorResolution) -> Bool {
        SharedMarginPrompts.isPlayable(resolution)
    }

    func refreshDiagnostics() {
        run { engine in
            diagnostics = try engine.diagnostics()
            diagnostics["providerProbe"] = providerProbeStatus
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
            settingsValueChanged()
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            if let structure = selectedItem.documentStructure {
                recordPDFExtractionDiagnostics(structure)
            }
            refreshImportInbox()
            reportSuccess("Diagnostics refreshed.")
        }
    }

    /// What the diagnostics export reads from the running app, copied here on the main actor (#1191).
    func diagnosticsExportInputs() -> DiagnosticsExportInputs {
        DiagnosticsExportInputs(
            live: diagnostics,
            store: store,
            fixed: DiagnosticsExport.Fixed(
                developerBuild: developerDiagnosticBuild,
                developerRecording: developerRecording.exportJSON(),
                playbackEvents: playbackEventRecording.exportJSON(),
                exportedAt: Date(),
                playbackStatus: snapshot.status.rawValue,
                sessionPhase: snapshot.phase.rawValue,
                targetType: snapshot.targetType,
                pendingAIJobs: snapshot.pendingAiJobCount
            )
        )
    }

    func normalizedSharingURL(_ value: String?) -> String? {
        SharedItemIdentityBuilder.normalizedSharingURL(value)
    }

    func handleIncomingURL(_ url: URL) {
        if let marginLink = MarginDeepLink(url: url) { openMargin(marginLink); return }
        if ShareLinkURL.isOnShareHost(url) { openShareLink(url); return }
        if url.isFileURL, url.pathExtension.lowercased() == "json" { importListeningEditionFile(url); return }
        if url.scheme == "spokenmargins", url.host == "listening-edition" {
            do {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                importListeningEditionFile(try ListeningEditionStore.stagedFile(id: id))
            } catch { reportFailure(error, context: "Listening edition handoff failed") }
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == SpokenMarginsPackageArchive.fileExtension { stageSpokenMarginsPackageImport(from: url); return }
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
                    // With something in Now Playing the import still shows its item and never touches playback (#1437).
                    let hadSession = hasActiveSession
                    if importClippedPage(handoff) {
                        try? handoffStore.deletePayload(payloadID: payloadID)
                        if hadSession { diagnostics["lastBrowserTextPayloadCleanup"] = "imported_without_session_replacement" }
                    }
                } else if let handoff = Gate5BrowserTextHandoffURL.handoff(from: url) {
                    importClippedPage(handoff)
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

    var hasActiveSession: Bool {
        snapshot.sessionId != nil
    }

    static func isResumableSession(_ session: Session) -> Bool {
        SessionContinuation.isResumableSession(session)
    }

    static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        SessionContinuation.preferredContinuationSession(in: sessions)
    }

    var selectedItemPreferredContinuationSession: Session? {
        Self.preferredContinuationSession(in: selectedItem.sessions)
    }

    var selectedItemStartupAudioState: NativeTextStartupAudioState {
        libraryItems.first(where: { $0.id == selectedItem.id })?.startupAudioState ?? .notRequired
    }

    var selectedItemStartupAudioProgressDescription: String {
        guard let row = libraryItems.first(where: { $0.id == selectedItem.id }), row.startupAudioState != .waiting,
              row.startupAudioTargetChunkCount > 0 else {
            return selectedItemStartupAudioState == .waiting ? "Waiting to prepare audio" : "Preparing audio"
        }
        return "Preparing audio · \(row.startupAudioCompletedChunkCount) of \(row.startupAudioTargetChunkCount)"
    }

    var shouldShowMiniPlayer: Bool {
        miniPlayerVisibility.visible
    }

    var isMediaPlaybackSnapshot: Bool {
        snapshot.targetType == TargetType.transcriptBackedMedia.rawValue ||
            snapshot.targetType == TargetType.browserOwnedMedia.rawValue
    }

    /// Starter audio represents only a bounded prefix of a text source. Exposing
    /// a full-range scrubber in that state would imply that every destination is
    /// already prepared, so the player falls back to truthful progress until the
    /// complete render is available.
    var canShowFullPlaybackScrubber: Bool {
        guard snapshot.targetType == TargetType.itemTextTTS.rawValue else { return true }
        return snapshot.preparedTextAudioStatus != "starter_ready"
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

    var canSummarizeInterjections: Bool {
        aiSummaryExperienceAvailable && hasActiveSession && !unsummarizedInterjectionsForCurrentTarget().isEmpty
    }

    var isSummarizingInterjections: Bool {
        latestPendingJob(kind: "interjection_summary") != nil
    }

    var summaryActionTitle: String {
        if isSummarizingInterjections { return "Summarizing" }
        return canRetryLocalSummary ? "Retry Summary" : "Summarize Notes"
    }

    private var playbackChapterContext: PlaybackChapterContext {
        let session = engine?.currentSession
        return PlaybackChapterContext(
            snapshot: snapshot,
            id: selectedItem.id,
            title: selectedItem.title,
            chapters: selectedItem.chapters,
            mediaChapters: selectedItem.mediaChapters,
            listeningMapScenes: selectedItem.listeningMapScenes,
            turns: selectedItem.turns,
            sessionItemId: session?.itemId,
            sessionChapterId: session?.position.chapterId
        )
    }

    var playbackHeaderTitle: String {
        PlaybackChapterLocator.playbackHeaderTitle(playbackChapterContext)
    }

    var playbackItemHeaderTitle: String {
        // The mini player appears on every screen, so it names what is playing, not whichever item page is open.
        if let playingId = snapshot.itemId, playingId != selectedItem.id {
            let title = (libraryItems.first { $0.id == playingId }?.title ?? snapshot.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var exportSourceTextAvailable: Bool {
        !selectedItem.isNativeAudio
    }

    func openCurrentPlaybackItem() {
        guard let itemId = snapshot.itemId ?? (selectedItem.id.isEmpty ? nil : selectedItem.id) else { return }
        openItem(id: itemId)
    }

    func isCurrentTimelineChapter(_ chapter: Chapter, turnId: String? = nil) -> Bool {
        PlaybackChapterLocator.isCurrentTimelineChapter(chapter, turnId: turnId, context: playbackChapterContext)
    }

    func isCurrentTimelineMediaChapter(_ chapter: MediaTimelineChapter) -> Bool {
        PlaybackChapterLocator.isCurrentTimelineMediaChapter(chapter, context: playbackChapterContext)
    }

    func isCurrentTimelineListeningMapScene(_ scene: MediaTimelineChapter) -> Bool {
        PlaybackChapterLocator.isCurrentTimelineListeningMapScene(scene, context: playbackChapterContext)
    }

    static func supportsOnDeviceSpeechGenerationStatus(targetType: String?) -> Bool {
        PlaybackStatusWording.supportsOnDeviceSpeechGenerationStatus(targetType: targetType)
    }

    var currentChapter: Chapter? {
        PlaybackChapterLocator.currentChapter(playbackChapterContext)
    }

    func performGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        recordDeveloperDiagnostic("transport.request", [
            "command": command.rawValue, "origin": origin,
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1),
            "requestedMediaTimeMs": String(mediaTimeMs ?? -1)
        ])
        if command.movesPlaybackPosition { marginMomentConductor?.sourceMoved() } // before any return below (#1656)
        if command == .beginInterjection, !snapshot.isRecording, snapshot.skimBridgeState == nil,
           !handOffPlayingMarginToRecording() { return }
        if snapshot.isRecording, heldMarginVoice != nil, command == .finishInterjection || command == .cancelInterjection { // the model plays the held voice on (#1672)
            if command == .finishInterjection { finishInterjection() } else { cancelInterjection() }
            return
        }
        if !snapshot.isRecording, marginMomentConductor?.isPlayingVoice == true || ownMarginVoiceHasTransport { // Play and Pause reach the voice, not the source behind it (#1672)
            switch command {
            case .play: resumePlayback(); return
            case .pause: pause(); return
            case .togglePlayPause: playPause(); return
            default: break
            }
        }
        if playingImportedCommentary != nil, !(command == .beginInterjection && marginVoiceHeldForRecording != nil) {
            switch command {
            case .play: resumePlayback()
            case .pause: pause()
            case .togglePlayPause: playPause()
            default:
                reportWarning("Return to Source before using source controls.")
            }
            return
        }
        if command == .skimForward {
            skimForward()
            diagnostics["gate2LastCommand"] = command.rawValue
            return
        }
        if command == .skimBackward {
            skimBackward()
            diagnostics["gate2LastCommand"] = command.rawValue
            return
        }
        if handlesLiveActivityNextChapter(command, chapterId: chapterId) {
            diagnostics["gate2LastCommand"] = command.rawValue
            return
        }
        if snapshot.skimBridgeState != nil {
            switch command {
            case .play:
                setSkimBridgePaused(false)
                return
            case .pause:
                setSkimBridgePaused(true)
                return
            case .togglePlayPause:
                playPause()
                return
            case .skipBack, .skipForward, .seekToMediaTime, .jumpToChapter:
                restoreSkimOriginBeforeCanonicalTransport()
            case .beginInterjection:
                reportWarning("Margins are unavailable while a scene summary is playing.")
                return
            case .setPlaybackRate:
                if let playbackRate { setMediaPlaybackRate(playbackRate) }
                return
            case .finishInterjection, .cancelInterjection,
                 .generateInterjectionSummary, .submitFollowup, .skimBackward, .skimForward:
                break
            }
        }
        if (snapshot.isRecording && command != .finishInterjection && command != .cancelInterjection)
            || (isRequestingRecordingPermission && command != .beginInterjection) {
            diagnostics["recordingNavigationGuard"] = "blocked_compact_\(command.rawValue)"
            return
        }
        let canonicalTransportCommands: Set<CompactControlCommand> = [
            .play, .pause, .togglePlayPause, .skipBack, .skipForward, .jumpToChapter
        ]
        let normalizedPlaybackRate = command == .setPlaybackRate
            ? playbackRate.map { SpeechRateRule.quarterStepMultiplier($0) }
            : playbackRate
        synchronizeSpeechAnchorForCompactCommand(command, canonicalTransport: canonicalTransportCommands.contains(command))
        if command == .beginInterjection {
            streamingSpeechQueue.pauseForInterjection()
        }
        guard let captureVerdict = verdictForCompactCommand(command) else { return }
        do {
            let result = try gate2CompactControls.dispatch(
                command,
                chapterId: chapterId,
                unit: compactSkipUnit(for: command),
                mediaTimeMs: mediaTimeMs,
                playbackRate: normalizedPlaybackRate,
                origin: origin
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate2CompactState()
            }
            if command == .beginInterjection, snapshot.isRecording {
                marginCapture.setPresentationContext(RecordingPresentationContext(
                    snapshot: snapshot,
                    startedAt: Date()
                ))
            }
            if command == .setPlaybackRate,
               let playbackRate = normalizedPlaybackRate {
                if isMediaPlaybackSnapshot {
                    mediaPlaybackRate = playbackRate
                    UserDefaults.standard.set(mediaPlaybackRate, forKey: "mediaPlaybackRate")
                    diagnostics["mediaPlaybackRate"] = String(format: "%.2f", mediaPlaybackRate)
                } else {
                    speechRate = playbackRate * 0.5
                    UserDefaults.standard.set(speechRate, forKey: "speechRate")
                }
            }
            refreshSelectedItem()
            if command == .finishInterjection {
                recordSavedInterjectionForOnboarding()
            }
            if command == .finishInterjection, result.delegatedToCanonicalRuntime { transcribeAndRecordSavedSpokenMargin() }
            if command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
                if !snapshot.isRecording {
                    marginCapture.clearPresentationContext()
                    refreshMarginRows()
                }
            }
            if canonicalTransportCommands.contains(command) {
                streamingSpeechQueue.relinquishToCanonicalPlayback()
            }
            reportSuccess("Compact control \(command.rawValue) \(result.delegatedToCanonicalRuntime ? "delegated" : "handled").")
            if command == .finishInterjection { reportMarginSaved(captureVerdict) }
        } catch {
            if command == .finishInterjection { recordSpokenMarginSavedBeforeFailure(engine?.lastScheduledTranscriptionInterjectionId) }
            if command == .beginInterjection || command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
            }
            if command == .beginInterjection, !snapshot.isRecording { resumeHeldMarginVoice(heldMarginVoice) } // no recording came of it (#1672)
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

    func synchronizeStreamingSpeechAnchorIfNeeded() {
        guard let engine,
              let turnId = streamingSpeechQueue.currentTurnId,
              let presentationOffset = streamingSpeechQueue.currentPresentationOffset else {
            return
        }
        do {
            let next = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: presentationOffset); if next != snapshot { snapshot = next } // an equal write publishes to every screen
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
                let next = try engine.updateStreamingTurnPosition(turnId: observation.turnId, charOffset: observation.charOffset)
                if next != snapshot { snapshot = next } // an equal write publishes to every screen
            case .failed:
                diagnostics["streamingSpeechFailure:\(observation.turnId)"] = "offset:\(observation.charOffset)"
            }
        } catch {
            diagnostics["streamingSpeechObservationError"] = String(describing: error)
        }
    }

    @Published private(set) var renderedSourceFraction: Double?
    private var frontierSignatures: [String: TTSRenderSignature] = [:]
    private var frontierPublicationKey: String?
    var renderedFractionForPlayback: Double? {
        guard frontierPublicationKey == renderFrontierKey else { return nil }
        if ttsVoiceSelection.isOnDeviceVoice,
           snapshot.targetType == TargetType.itemTextTTS.rawValue,
           onDeviceSpeechGenerationProgress.totalChunks > 0 {
            return Double(onDeviceSpeechGenerationProgress.percent) / 100
        }
        return renderedSourceFraction
    }
    var renderFrontierKey: String { "\(snapshot.itemId ?? "")|\(snapshot.targetType ?? "")|\(ttsVoiceSelection.rawValue)" }

    /// Runs only while the playback surface is present; publication never reads disk in body.
    func observeRenderedFrontier() async {
        let key = renderFrontierKey
        renderedSourceFraction = nil
        frontierPublicationKey = key
        guard let itemID = snapshot.itemId, let voice = ttsVoiceSelection.supertonicVoice,
              [TargetType.itemTextTTS.rawValue, TargetType.transcriptBackedMedia.rawValue].contains(snapshot.targetType ?? ""),
              let store else { return }
        do {
            let signature: TTSRenderSignature
            if let cached = frontierSignatures[voice.rawValue] { signature = cached }
            else {
                // Saved audio shows before the model is downloaded too (#1820).
                signature = try await Task.detached(priority: .utility) {
                    try SupertonicRenderIdentity.current(voice: voice)
                }.value
                frontierSignatures[voice.rawValue] = signature
            }
            let root = try applicationSupportDirectory().appendingPathComponent("PreparedAudio")
            while !Task.isCancelled, renderFrontierKey == key {
                let item = try store.loadItem(id: itemID)
                guard let text = PreparedSpeechHooks.preparedText(of: item, in: store), !text.isEmpty else { return }
                let source = try store.loadCanonicalSource(itemId: itemID)
                let manifest = try store.loadPreparedAudioManifests(itemId: itemID).first { $0.signature == signature }
                let canonical = source?.segments.map(\.text).joined(separator: "\n\n") ?? ""
                let fraction = await Task.detached(priority: .utility) {
                    PreparedRenderFrontier.fraction(manifest: manifest, signature: signature, sourceText: text, canonicalSourceText: canonical, root: root)
                }.value
                guard !Task.isCancelled, renderFrontierKey == key else { return }
                if renderedSourceFraction != fraction { renderedSourceFraction = fraction }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            if renderFrontierKey == key, !Task.isCancelled { renderedSourceFraction = nil }
        }
    }

    func activateListeningEditionAudio(itemId: String, timeline: TranscriptTimeline) {
        guard let edition = try? ListeningEditionStore.application().load(itemID: itemId), let store else { return }
        do {
            let (proposal, projection) = try edition.audioMap(timeline: timeline)
            try store.savePortableListeningMapProposal(proposal, itemId: itemId)
            try store.saveResolvedListeningMapProjection(projection)
            if selectedItem.id == itemId { refreshSelectedItem() }
            prepareImportedLocalAudioBridges(itemId: itemId)
            Task { await ListeningReadyNotifications.notify(itemID: itemId, title: edition.title, revision: edition.revision) }
        } catch { diagnostics["listeningEditionAudio"] = "not_ready" }
    }

    // MARK: Portable listening editions and personal knowledge output
    func importListeningEditionFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw EditionError.invalid("Listening edition exceeds 8 MB.") }
            importListeningEditionData(try Data(contentsOf: url))
        } catch { reportFailure(error, context: "Listening edition file could not be opened") }
    }

    func importReadLaterDocument(_ document: ReadLaterDocument) {
        guard !isImportingReadLater else { return }
        isImportingReadLater = true
        Task {
            defer { isImportingReadLater = false }
            do {
                if let html = document.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let handoff = Self.sanitizedBrowserTextHandoff(BrowserTextHandoff(
                        captureMode: .readablePage,
                        source: BrowserTextSource(url: document.url, title: document.title), text: html,
                        contentFormat: .plainText
                    ))
                    let store = try requireStore()
                    let id = "read-later-" + ListeningEdition.digest(document.url + "\n" + handoff.text)
                    if (try? store.loadItem(id: id)) != nil {
                        reportConfirmation("This article is already in your Library.")
                        return
                    }
                    var stable = handoff; stable.itemId = id
                    try importBrowserTextInBackground(stable)
                    reportConfirmation("Added article. Your reading service has not been changed.")
                } else {
                    // URL-only services use the existing local readable-page importer,
                    // including its visible unsupported/paywall failure behavior.
                    guard let url = URL(string: document.url) else { throw EditionError.invalid("Invalid article URL.") }
                    var handoff = try await readablePageExtractor.extract(url: url)
                    let id = "read-later-" + ListeningEdition.digest(document.url + "\n" + handoff.text)
                    let store = try requireStore()
                    if (try? store.loadItem(id: id)) != nil {
                        reportConfirmation("This article is already in your Library."); return
                    }
                    handoff.itemId = id
                    try importBrowserTextInBackground(handoff)
                    reportConfirmation("Added article from its original website.")
                }
            } catch { reportFailure(error, context: "Article import failed") }
        }
    }

    private var automaticMarginGatherMaxMs = 0

    private func recordAutomaticMarginGather(ms: Int, sessions: Int, notes: Int) {
        automaticMarginGatherMaxMs = max(automaticMarginGatherMaxMs, ms)
        diagnostics["automaticMarginGather"] = "background;lastMs=\(ms);maxMs=\(automaticMarginGatherMaxMs);sessions=\(sessions);notes=\(notes)"
        // The always-on log keeps 300 events; only slow passes are worth one. The work is off the main actor now,
        // so a slow pass no longer freezes the UI; the event stays to show the cost.
        if ms >= 500 {
            recordDeveloperDiagnostic("marginOutput.gather", ["ms": String(ms), "sessions": String(sessions), "notes": String(notes)])
        }
    }

    @discardableResult
    func run(_ operation: (SessionEngine) throws -> Void) -> Bool {
        if engine == nil {
            do {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            } catch {
                reportFailure(error, context: "Playback setup failed")
            }
        }
        guard let engine else { return false }
        do {
            try hangTelemetry.labels.scoped("engine.run") { try operation(engine) }
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    func previewSpeech(label: String, mode: AppSpeechPreviewMode) {
        #if canImport(AVFoundation)
        do {
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
                utterance.rate = SpeechRateRule.systemSpeechRate(forMultiplier: speechPlaybackRateMultiplier)
            case .appVoice(let voiceIdentifier, let rate):
                utterance.rate = SpeechRateRule.systemSpeechRate(
                    forMultiplier: SpeechRateRule.multiplier(forStoredRate: rate)
                )
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

    func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func summaryScopeForCurrentTarget() -> SummaryScope {
        switch currentPlaybackTargetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return SummaryScope(targetType: "turn", turnId: currentPlaybackTargetId)
        default:
            return SummaryScope(targetType: "item")
        }
    }

    func latestPendingSummaryTurnId() -> String? {
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

    func rebuildEngineForCurrentSettings() -> Bool {
        guard let store else { return true }
        do {
            libraryAudioLoop.stopAndInvalidate()
            pendingStartupAudioPreparationItemIds.removeAll()
            let replacement = try makeEngine(store: store)
            let sessionId = engine?.currentSession?.id ?? snapshot.sessionId
            if engine?.currentSession != nil {
                snapshot = try engine?.stopPlayback() ?? snapshot
            }
            let restoredSnapshot = try sessionId.map { try replacement.inspectSession(sessionId: $0) }
            installEngine(replacement)
            try refreshLibraryRows(store: store)
            if let restoredSnapshot {
                snapshot = restoredSnapshot
                activeItemId = restoredSnapshot.itemId ?? activeItemId
                try prepareSourceMediaPlayback(itemId: activeItemId)
                refreshSelectedItem()
                diagnostics["sessionRestoredAfterRuntimeRebuild"] = sessionId
            }
            return true
        } catch {
            reportFailure(error, context: "Runtime profile update failed")
            return false
        }
    }

    func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
        let loadedProfile = try loadProfile(id: selectedProfileId)
        let profile = remoteProviderExperienceEnabled
            ? loadedProfile
            : loadedProfile.limitedToOnDeviceAI(foundationModelAvailable: localFoundationModelAvailable)
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
            recorder: reportingMarginInterruptions(recordingClientOverride ?? SystemRecordingClient()),
            aiProvider: provider,
            linkResolver: sourceLinkResolver ?? PublicPodcastLinkResolver(),
            textAudio: try makeTextAudioPreparationClient()
        )
    }

    private func makeTextAudioPreparationClient() throws -> TextAudioPreparationClient? {
        guard audioPlaybackClientOverride == nil else { return nil }
        guard ttsVoiceSelection == .system else { return nil }
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

    func prewarmTextAudioForOnDeviceVoice(itemId: String) {
        if ttsVoiceSelection.supertonicVoice != nil {
            scheduleStartupAudioPreparationIfNeeded(itemId: itemId)
            return
        }
        // AVSpeechSynthesizer serializes or competes with live utterances on real
        // devices. Only an explicitly injected preparation job may pre-render in
        // the background; production playback must stay on the immediate path.
        guard ttsVoiceSelection == .system else { return }
        guard let prewarmHandler = preparedTextAudioPrewarmHandler else { return }
        guard ttsMode != "piper" else { return }
        guard textAudioPrewarmTasks[itemId] == nil else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            let shouldSkipPreparation = PreparationChunkGate.itemAlreadyListened(
                try store.loadSessions(itemId: itemId)
            )
            guard !shouldSkipPreparation else {
                diagnostics["textAudioPrewarm:\(itemId)"] = "skipped_existing_progress"
                return
            }
            guard LibraryRowBuilder.shouldPrewarmTextAudio(for: item), let text = item.text, PreparedSpeechHooks.preparedText(of: item, in: store) == text else { return }
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

    static func startupPreparationCandidates(_ rows: [LibraryItemRow]) -> [String] {
        LibraryRowBuilder.startupPreparationCandidates(rows)
    }

    @discardableResult
    func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready",
        replaceActivePlayback: Bool = false
    ) -> Bool {
        do {
            if engine == nil, let store {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            snapshot = try engine.attachPreparedTextAudio(
                itemId: itemId,
                prepared: prepared,
                replaceActivePlayback: replaceActivePlayback
            )
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                if activeItemId == itemId || selectedItem.id == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            activateListeningEditionAudio(itemId: itemId, timeline: prepared.timeline)
            diagnostics["textAudioPrewarm:\(itemId)"] = diagnosticStatus
            preparedTextAudioStatus = preparedStatus
            snapshot.preparedTextAudioStatus = preparedStatus
            return true
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "attach_failed:\(error.localizedDescription)"
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
            return false
        }
    }

    private func finishTextAudioPrewarm(itemId: String, status: String, diagnostic: String) {
        textAudioPrewarmTasks[itemId] = nil
        diagnostics["textAudioPrewarm:\(itemId)"] = diagnostic
        preparedTextAudioStatus = status
        snapshot.preparedTextAudioStatus = status
    }

    func cancelTextAudioPrewarmTasks() {
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

    func removeEpisodeMapArtifacts(itemId: String) {
        if snapshot.itemId == itemId, snapshot.skimBridgeState != nil {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        }
        episodeMapPreparer.cancel(itemId: itemId)
        if let directory = try? episodeMapDirectory(itemId: itemId),
           FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try? purgeTransientEpisodeTranscriptionCaches(itemId: itemId)
        for job in (try? store?.loadEpisodeMapPreparationJobs()) ?? [] where job.itemId == itemId {
            try? store?.deleteEpisodeMapPreparationJob(id: job.id)
        }
    }

    func purgeExpiredEpisodeMapPreparationJobs(store: SQLiteSessionStore, now: Date = Date()) {
        let expiration = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for job in (try? store.loadEpisodeMapPreparationJobs()) ?? [] where
            job.isCancelled || job.requestedAt < expiration {
            try? purgeTransientEpisodeTranscriptionCaches(itemId: job.itemId)
            if (try? store.loadEditionFingerprintSpine(itemId: job.itemId)) == nil,
               let directory = try? episodeMapDirectory(itemId: job.itemId),
               FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
            try? store.deleteEpisodeMapPreparationJob(id: job.id)
        }
    }

    @discardableResult
    func sanitizeTTSMode() -> Bool {
        let priorMode = ttsMode
        if ttsVoiceSelection.isOnDeviceVoice, !hasAcceptedCurrentTerms {
            ttsVoiceSelection = .system
        }
        synchronizeTTSModeFromSelection()
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(ttsVoiceSelection.rawValue, forKey: "ttsVoiceSelection")
        return priorMode != ttsMode
    }

    /// What the Library row builder needs to know about the app right now.
    var startupAudioContext: StartupAudioContext {
        StartupAudioContext(
            hasAcceptedCurrentTerms: hasAcceptedCurrentTerms,
            hasSupertonicVoice: ttsVoiceSelection.supertonicVoice != nil,
            suppressedItemIds: suppressedAutomaticAudioPreparationItemIds,
            liveSpeechFallbackItemIds: liveSpeechFallbackItemIds,
            failedItemIds: failedStartupAudioPreparationItemIds,
            preparingItemId: libraryAudioPreparingItemId,
            playingItemId: snapshot.status.isPlaybackActive ? activePlaybackItemId : nil, // a paused session isn't prepared
            renderSignature: currentSupertonicRenderSignature,
            allowsRendering: SupertonicResourcePolicy.allowsRendering(),
            startupChunkCount: Self.startupAudioChunkCount)
    }

    func refreshBatchExportRows(store: SQLiteSessionStore) throws {
        let itemsById = Dictionary(uniqueKeysWithValues: try store.listItemSummaries().map { ($0.id, $0) })
        let activeCounts = try store.activeInterjectionCountsBySession()
        batchExportRows = try store.loadSessions().compactMap { session in
            guard let item = itemsById[session.itemId] else { return nil }
            return BatchSessionExportRow(
                session: session,
                itemTitle: item.title,
                interjectionCount: activeCounts[session.id] ?? 0
            )
        }
        let availableIds = Set(batchExportRows.map(\.id))
        selectedBatchExportSessionIds.formIntersection(availableIds)
    }

    func loadDeletedLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listDeletedItemSummaries().map { item in
            LibraryItemRow(id: item.id, title: item.title, status: "Recently deleted", canDelete: true)
        }
    }

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url).first
    }

    func scheduleSourceTranscriptImportIfAvailable(_ links: [SourceTranscriptLink], itemId: String) {
        guard !links.isEmpty else {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "no_links"
            return
        }
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.transcriptId == nil else { return }
        let sortedLinks = SourceTranscriptParsing.prioritizedTranscriptLinks(links)
        diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "scheduled:\(sortedLinks.count)"
        diagnostics["sourceTranscriptionStatus"] = "downloading"
        if activeItemId == itemId {
            sourceTranscriptStatus = "downloading"
            snapshot.sourceTranscriptStatus = "downloading"
        }
        Task { [weak self, itemId, sortedLinks, durationMs = item.media?.durationMs] in
            guard let self else { return }
            var lastFailure = ""
            for link in sortedLinks {
                do {
                    let data = try await Self.fetchTranscriptLink(link)
                    if let timeline = try SourceTranscriptParsing.transcriptTimeline(from: data, link: link, itemId: itemId, durationMs: durationMs),
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
                if self.activeItemId == itemId {
                    self.sourceTranscriptStatus = "unavailable"
                    self.snapshot.sourceTranscriptStatus = "unavailable"
                }
            }
        }
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

    private func scheduleFullSourceTranscriptionForListeningMap(for item: Item, localSourceURL: URL? = nil) {
        guard item.transcriptId == nil,
              let sourceURLString = item.media?.url,
              let canonicalURL = URL(string: sourceURLString) else {
            return
        }
        guard importedPodcastPlacement.beginFullSourceTranscription(itemId: item.id) else { return }
        let sourceURL = localSourceURL
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalURL
        guard sourceURL.isFileURL else {
            importedPodcastPlacement.releaseFullSourceTranscription(itemId: item.id)
            diagnostics["sourceTranscriptionStatus"] = "waiting_for_local_audio"
            return
        }
        diagnostics["sourceTranscriptionStatus"] = "transcribing"
        if activeItemId == item.id {
            sourceTranscriptStatus = "transcribing"
            snapshot.sourceTranscriptStatus = "transcribing"
            statusMessage = "Transcribing source audio..."
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: sourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                await MainActor.run {
                    self.importedPodcastPlacement.releaseFullSourceTranscription(itemId: item.id)
                    self.attachSourceTranscriptTimeline(timeline, itemId: item.id)
                }
            } catch {
                await MainActor.run {
                    self.importedPodcastPlacement.releaseFullSourceTranscription(itemId: item.id)
                    self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                    self.diagnostics["sourceTranscriptionError"] = String(describing: error)
                    if self.activeItemId == item.id {
                        self.sourceTranscriptStatus = "unavailable"
                        self.snapshot.sourceTranscriptStatus = "unavailable"
                    }
                    if self.pendingMapGenerationItemId == item.id {
                        self.pendingMapGenerationItemId = nil
                    }
                    if self.activeItemId == item.id, self.lastError == nil {
                        self.statusMessage = "Audio ready. Source transcript and Listening Map are unavailable; notes will use timestamp context."
                    }
                }
            }
        }
    }

    func attachSourceTranscriptTimeline(_ timeline: TranscriptTimeline, itemId: String) {
        let shouldGeneratePendingMap = pendingMapGenerationItemId == itemId
        run { engine in
            snapshot = try engine.attachTranscriptTimeline(itemId: itemId, timeline: timeline)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                // Transcript imports can finish long after a shared podcast was
                // added. They must never retarget the playback screen away from
                // the item/session that is still active.
                if activeItemId == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            diagnostics["sourceTranscriptionStatus"] = "complete"
            diagnostics["sourceTranscriptionItem"] = itemId
            if activeItemId == itemId {
                sourceTranscriptStatus = "ready"
                snapshot.sourceTranscriptStatus = "ready"
            }
        }
        if shouldGeneratePendingMap {
            pendingMapGenerationItemId = nil
            generateListeningMap()
        }
        retrySourceWindowContexts(itemId: itemId)
        if let store { CommunityMapUploadService.shared.transcriptAttached(itemId: itemId, store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 } }
        if let localURL = importedPodcastRecipientLocalURLs[itemId]
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
            resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
        }
    }

    func setImportedCommentaryLayerEnabled(_ layerID: String, enabled: Bool) {
        updateImportedCommentaryLayer(layerID) { $0.isEnabled = enabled }
    }

    func setImportedCommentaryLayerMuted(_ layerID: String, muted: Bool) {
        updateImportedCommentaryLayer(layerID) { $0.isMuted = muted }
    }

    func setImportedCommentaryRevealMode(_ layerID: String, mode: ImportedCommentaryRevealMode) {
        updateImportedCommentaryLayer(layerID) { $0.revealMode = mode }
    }

    var hasEnabledImportedCommentary: Bool {
        selectedItem.importedCommentaryLayers.contains { layer in
            Self.isImportedCommentaryLayerPlaybackEligible(
                layer,
                records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
            )
        }
    }

    var importedCommentaryAutoPlayEnabled: Bool {
        let enabledLayers = selectedItem.importedCommentaryLayers.filter { layer in
            Self.isImportedCommentaryLayerPlaybackEligible(
                layer,
                records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
            )
        }
        return !enabledLayers.isEmpty && enabledLayers.allSatisfy { $0.revealMode == .guided }
    }

    nonisolated static func isImportedCommentaryLayerPlaybackEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        SharedMarginPrompts.isLayerPlaybackEligible(layer, records: records)
    }

    func setImportedCommentaryAutoPlayEnabled(_ enabled: Bool) {
        do {
            let store = try requireStore()
            let layerIDs = selectedItem.importedCommentaryLayers.compactMap { layer in
                layer.deletedAt == nil && layer.isEnabled ? layer.id : nil
            }
            for layerID in layerIDs {
                guard var layer = try store.loadImportedCommentaryLayer(id: layerID) else { continue }
                layer.revealMode = enabled ? .guided : .companion
                try store.saveImportedCommentaryLayer(layer)
            }
            refreshSelectedItem()
            reportConfirmation(enabled
                ? "Shared Margins will play automatically after their cue."
                : "Shared Margins will wait for you to choose Listen or Dismiss.")
        } catch {
            reportFailure(error, context: "Shared Margin auto-play setting could not be saved")
        }
    }

    private func updateImportedCommentaryLayer(
        _ layerID: String,
        mutation: (inout ImportedCommentaryLayer) -> Void
    ) {
        do {
            let store = try requireStore()
            guard var layer = try store.loadImportedCommentaryLayer(id: layerID) else { return }
            mutation(&layer)
            try store.saveImportedCommentaryLayer(layer)
            refreshSelectedItem()
        } catch {
            reportFailure(error, context: "Shared Margin settings could not be saved")
        }
    }

    func interjectionAudioEvidence(for path: String) -> String {
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

    func recordAnchorCaptureDiagnostics(for interjection: Interjection) {
        diagnostics[Self.marginDiagnosticKey("interjectionAnchorAtCapture", interjection)] = [
            "type=\(interjection.anchor.anchorType.rawValue)",
            "media_time=\(interjection.anchor.mediaTimeMs == nil ? "missing" : "present")",
            "segment=\(interjection.anchor.transcriptSegmentId == nil ? "missing" : "present")",
            "before=\(interjection.anchor.anchorBefore.isEmpty ? "missing" : "present")",
            "after=\(interjection.anchor.anchorAfter.isEmpty ? "missing" : "present")",
            "context=\(interjection.anchorContextStatus?.rawValue ?? "legacy")"
        ].joined(separator: ";")
    }

    func summaryPrompt(interjections: [Interjection]) -> String {
        """
        I would like to have a session with you, the article, and my interjections below.
        \(sessionContextJSON(interjections: interjections, currentFollowUp: nil))
        """
    }

    func localSummaryContexts(interjections: [Interjection]) -> [String] {
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

    func conversationPrompt(followUp: String, explicitFollowUp: String, primaryInterjections: [Interjection]) -> String {
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
        interjections: [Interjection], currentFollowUp: String?,
        explicitFollowUp: String? = nil, primaryInterjections: [Interjection] = []
    ) -> String {
        DiscussionContext.contextJSON(
            itemTitle: selectedItem.title, itemText: selectedItem.text, overview: selectedItem.overview,
            chapters: selectedItem.chapters, turns: selectedItem.turns,
            currentTargetType: currentPlaybackTargetType, currentTargetId: currentPlaybackTargetId,
            interjections: interjections, currentFollowUp: currentFollowUp,
            explicitFollowUp: explicitFollowUp, primaryInterjections: primaryInterjections
        )
    }

    func currentDiscussionInterjections() -> [Interjection] {
        Gate1DiscussionContext.currentTargetInterjections(
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId,
            itemId: selectedItem.id
        )
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

    func resolvedFolderURL(_ setting: SavedFolderSetting) -> URL? {
        do {
            return try setting.resolvedURL()
        } catch {
            diagnostics["\(setting.bookmarkKey)Error"] = String(describing: error)
            return nil
        }
    }

    func obsidianItemId(fileName: String, index: Int) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "item-obsidian-\(Int(Date().timeIntervalSince1970))-\(index)-\(base.isEmpty ? "clip" : base)"
    }

    func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let url = try databaseURL()
        let store = try SQLiteSessionStore(path: url.path)
        self.store = store
        try configurePodcastDownloads(store: store)
        return store
    }

    func configureOfflineServices(store: SQLiteSessionStore) throws {
        let support = try applicationSupportDirectory()
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support)
        offlineStorageLedger = ledger
        localSourceImporter = LocalSourceImporter(
            repository: store,
            ledger: ledger,
            applicationSupportDirectory: support
        )
        followedSourceCoordinator = FollowedSourceCoordinator(repository: store, artworkFile: support.appending(path: FollowingArtworkCache.fileName), signals: .app)
        guidedOnboardingCoordinator = GuidedOnboardingCoordinator(
            directory: support.appending(path: "GuidedOnboarding", directoryHint: .isDirectory),
            ledger: ledger
        )
        startOfflineServices(store: store, ledger: ledger)
    }

    var followCandidateDiscoveryHandler: ((Item, URL) async throws -> [SourceCandidateEvidence])?

    /// Re-reads the inbox without a refresh, which skips while another one runs (#477).
    func reloadFollowedSourceEntries() async {
        if let coordinator = followedSourceCoordinator, let entries = try? await coordinator.entries() { feedSubscriptions = storedFeedSubscriptions(); followedSourceEntries = entries } // subscriptions first: New hides a back catalogue by them (#1589)
    }

    func requireLocalSourceImporter() throws -> LocalSourceImporter {
        if let localSourceImporter { return localSourceImporter }
        let store = try requireStore()
        try configureOfflineServices(store: store)
        guard let localSourceImporter else {
            throw SessionKitError.persistenceFailed("local_source_importer_unavailable")
        }
        return localSourceImporter
    }

    func databaseURL() throws -> URL {
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

    func loadFixtureItem(name: String) throws -> Item {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/items") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.item(at: url)
    }

    func loadFixtureMap(name: String) throws -> ListeningMap {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/maps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.listeningMap(at: url)
    }

    func loadProfile(id: String) throws -> RuntimeCapabilityProfile {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "fixtures/capabilities") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.profile(at: url)
    }
}

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
