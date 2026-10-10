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

private struct ObsidianImportRequest: Sendable {
    let url: URL
    let itemId: String
}

private struct ObsidianImportBatch: Sendable {
    let prepared: [PreparedObsidianImport]
    let failures: [String]
}

@MainActor
final class Gate1AppModel: ObservableObject {
    static let welcomeSampleItemId = "item-spoken-margins-overview"
    static let guidedOnboardingItemId = "guided-onboarding"
    private static let welcomeSampleSeedVersion = 2
    private static let welcomeSampleSeedVersionKey = "welcomeSampleSeedVersion"
    private static let onboardingStepsKey = "onboardingCompletedStepsV1"
    private static let guidedOnboardingStageKey = "guidedOnboardingStageV1"
    private static let guidedOnboardingSeedVersionKey = "guidedOnboardingSeedVersion"
    private static let guidedOnboardingTombstoneKey = "guidedOnboardingTombstone"
    private static let onboardingCardDismissedKey = "onboardingCardDismissedV1"
    private static let dismissedQuickAccessFilesKey = "dismissedQuickAccessFilesV1"
    private static let supertonicTTSMigrationKey = "supertonicTTSMigrationV1"
    private static let supertonicVoicePendingTermsKey = "supertonicVoicePendingTermsV1"
    private static let showsMixWithOtherAudioOptionKey = "showsMixWithOtherAudioOption"
    private static let mixedPlaybackVolumeKey = "mixedPlaybackVolume"
    private static let suppressedAudioPreparationItemIdsKey = "suppressedAudioPreparationItemIdsV1"
    static let mixedPlaybackVolumeMaximum = 1.0
    static let exportPreviewCharacterLimit = 24_000
    nonisolated static let supportedPlaybackRates: [Double] = SpeechRateRule.supportedMultipliers
    static let privateSharingNoteCharacterLimit = 500
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    private static var supportsSpeechVoiceEnumeration: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    @Published private var presentedScreen: Gate1Screen = .home
    @Published var requestedExperienceRoot: AppRoot?
    @Published private(set) var writtenMarginDraft: WrittenMarginDraft?
    @Published private(set) var recordingPermissionDenied = false
    @Published var marginCollectionQuery = MarginCollectionQuery()
    @Published private(set) var sharedMarginRows: [SharedMarginRow] = []
    private var pendingVoiceCaptureRequestID: UUID?
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
            reconcileNarrationStartupProtection()
            updateSkimAvailability(refreshResources: false)
            updateGate2CompactState()
        }
    }
    @Published var narrationVoiceNotice = NarrationVoiceNotice() // written by updateNarrationVoiceNotice() only
    private(set) var gate2CompactSnapshot: CompactControlSnapshot?
    let runtimeDiagnostics = RuntimeDiagnostics()
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

    private let playbackEventRecording = DeveloperDiagnosticRecording(
        limit: 300,
        fileURL: Gate1AppModel.isRunningUnitTests ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeveloperDiagnostics/playback-events.json"),
        automatic: true
    )
    private var lastPlaybackEventCheckpoint: TimeInterval = 0
    var speechInterruptionResumeWatch = SpeechInterruptionResumeWatch()

    func recordDeveloperDiagnostic(_ kind: String, _ fields: [String: String] = [:]) {
        developerRecording.record(kind, fields)
        // High-frequency samples and rendering events must not erase transport history.
        if kind != "sample", !kind.hasPrefix("preparation."),
           !kind.hasPrefix("scrub."), kind != "main.delayed" {
            playbackEventRecording.record(kind, fields)
        }
    }

    private func recordPlaybackEventState(previous: SessionSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let changed = previous.status != snapshot.status || previous.targetId != snapshot.targetId
            || previous.lastFailure != snapshot.lastFailure
        guard changed || (snapshot.status.isPlaybackActive && now - lastPlaybackEventCheckpoint >= 30) else { return }
        lastPlaybackEventCheckpoint = now
        playbackEventRecording.record("playback.state", playbackStateRecordFields())
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
            "workerActive": String(foregroundAudioPreparationTask != nil),
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
    @Published private(set) var feedbackEvent: UserFeedbackEvent?
    @Published private(set) var itemFailures = ItemFailureLog()
    @Published var exportPreview = ""
    @Published private(set) var exportFileURL: URL?
    @Published private(set) var exportShareCandidates: [Interjection] = []
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
    @Published private(set) var batchExportFolderName = SavedFolderSetting.sessionExport.name() ?? "No folder selected"
    /// The notes folder has its own setting (#930); the first launch with it copies the export folder.
    @Published private(set) var marginNotesFolderName: String = {
        SavedFolderSetting.separateMarginNotesFromSessionExport()
        return SavedFolderSetting.marginNotes.name() ?? "No folder selected"
    }()
    @Published private(set) var batchExportResult: BatchSessionExportResult?
    @Published private(set) var isWritingBatchExport = false
    @Published private(set) var retryingInterjectionTranscriptionIds: Set<String> = []
    @Published private(set) var playingInterjectionAudioId: String?
    @Published private(set) var playingInterjectionAudioSessionID: String?
    @Published private(set) var playingInterjectionAudioRate: Double = 1
    private var libraryPresentationRevision = 0
    private(set) var navigationRefreshTask: Task<Void, Never>?
    var navigationLibraryRead: @Sendable (SQLiteSessionStore) async throws -> LibraryReadSnapshot = { store in
        try await Task.detached(priority: .utility) { try LibraryReadSnapshot.read(store: store) }.value
    }
    private var activePlaybackDetail: ItemDetailState?
    @Published var libraryItems: [LibraryItemRow] = [] {
        didSet { cachedQuickAddCandidates = nil; libraryPresentationRevision += 1 }
    }
    @Published private(set) var audioPreparationQueue: [AudioPreparationQueueRow] = []
    @Published private(set) var recentlyPreparedAudio: [RecentlyPreparedAudioRow] = []
    @Published var libraryQuery = LibraryQuery(
        contentType: LibraryContentTypeFilter(rawValue: UserDefaults.standard.string(forKey: "libraryContentTypeFilter") ?? "") ?? .all,
        listeningState: Gate1AppModel.loadLibraryListeningFilter(defaults: .standard),
        offlineState: LibraryOfflineStateFilter(rawValue: UserDefaults.standard.string(forKey: "libraryOfflineStateFilter") ?? "") ?? .all,
        sort: LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recentlyAdded
    )
    @Published private(set) var sleepTimerState: SleepTimerState = .inactive
    @Published private(set) var sleepTimerRemainingSeconds: Int?
    @Published private(set) var libraryAccessError: String?
    @Published var recentlyDeletedItems: [LibraryItemRow] = []
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
    @Published private(set) var marginRows: [MarginRow] = []
    @Published private(set) var offlineStorageSnapshot = OfflineStorageSnapshot()
    @Published private(set) var recordingPresentationContext: RecordingPresentationContext?
    @Published private(set) var isRequestingRecordingPermission = false
    @Published var recordingCaptureHealth: MarginCaptureSupervisor.Health = .capturing // written by Gate1AppModel+MarginCapture only
    var captureWatcher = MarginCaptureWatcher()
    /// #783: the line shown before iOS's first microphone prompt.
    @Published private(set) var microphonePrimer = MicrophonePrimer()
    @Published private(set) var isFinishingInterjection = false
    @Published private(set) var isMarginCaptureCoolingDown = false
    @Published private(set) var isDismissingMiniPlayer = false
    @Published var requestedTimelineFocusMarginID: String?
    @Published var pastedAssistantResponse = ""
    @Published var sharingState = InterjectionSharingState()
    @Published var isSharingInterjectionsPresented = false
    @Published var sharedSpokenMarginsPackageURL: URL?
    @Published var isSharedSpokenMarginsPackagePresented = false
    @Published var spokenMarginsPackageImportReview: SpokenMarginsPackageImportReview?
    @Published private(set) var isImportingSpokenMarginsPackage = false
    @Published private(set) var spokenMarginsPackageImportError: String?
    @Published private(set) var pendingImportedCommentary: ImportedCommentaryPrompt? {
        didSet {
            if oldValue?.id != pendingImportedCommentary?.id {
                updateGate2CompactState()
            }
        }
    }
    @Published private(set) var playingImportedCommentary: ImportedCommentaryPrompt?
    @Published var importedCommentaryIsPaused = false
    /// What the shared Margin's voice is really doing (#941), judged from the player, not from the request to play.
    @Published var importedCommentaryPhase: SharedMarginPlaybackPhase = .loading
    var importedCommentaryHealth: SharedMarginPlaybackHealth?
    let importedMarginRemoteControls = ImportedMarginRemoteControls()
    /// "Play this moment" (#159). The sequence is published for the playback screen; the conductor runs it.
    @Published private(set) var marginMoment: MarginMomentSequence?
    @Published private(set) var marginMomentVoiceIsPaused = false
    /// Whose Margin the moment is for ("Your Margin", "Cole's Margin"), and whether its position is only a guess.
    @Published private(set) var marginMomentTitle = "Your Margin"
    @Published private(set) var marginMomentPositionIsApproximate = false
    private var marginMomentConductor: MarginMomentConductor?
    /// Heard audio around streamed Margins, written to temporary files until transcribed (#156). Keyed by margin identity.
    private var heardSourceWindows: [String: [(url: URL, startMediaTimeMs: Int, durationMs: Int)]] = [:]

    var activePlaybackIsPlaying: Bool {
        if playingImportedCommentary != nil { return importedCommentaryPhase.showsPause }
        if marginMomentConductor?.isPlayingVoice == true { return !marginMomentVoiceIsPaused }
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
    @Published var quickAccessFolderName = UserDefaults.standard.string(forKey: "quickAccessFolderName") ?? "No folder selected"
    @Published var quickAccessRecentFiles: [QuickAccessFile] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published private(set) var dismissedQuickAccessFileKeys = Set(
        UserDefaults.standard.stringArray(forKey: Gate1AppModel.dismissedQuickAccessFilesKey) ?? []
    ) { didSet { cachedQuickAddCandidates = nil } }
    @Published private(set) var sourceImportProgressMessage: String?
    @Published private(set) var isRefreshingQuickAccessFolder = false
    @Published var importInbox: [ImportInboxEntry] = []
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = ""
    @Published var importText = ""
    @Published var sourceLinkURL = ""
    @Published var followedSourceURL = ""
    @Published private(set) var followedSourceCandidates: [SourceCandidateEvidence] = []
    @Published private var storedSourceFollowSuggestionCandidates: [SourceCandidateEvidence] = []
    private var sourceFollowSuggestionItemId: String?
    var sourceFollowSuggestionCandidates: [SourceCandidateEvidence] {
        guard sourceFollowSuggestionItemId == selectedItem.id else { return [] }
        let row = libraryItems.first(where: { $0.id == selectedItem.id })
        guard !FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: row?.sourceURL, sourceTitle: row?.sourceTitle, sourceReference: row?.sourceReference,
            subscriptions: feedSubscriptions
        ) else { return [] }
        return FollowedSourceMatching.uniqueUnfollowedCandidates(storedSourceFollowSuggestionCandidates, subscriptions: feedSubscriptions)
    }
    @Published private(set) var followedSourceEntries: [FeedEntry] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published private(set) var feedSubscriptions: [FeedSubscription] = [] { didSet { cachedQuickAddCandidates = nil; listeningSignals.endListening() } }
    @Published private(set) var isRefreshingFollowedSources = false
    @Published private(set) var importingFollowedSourceEntryIds: Set<String> = []
    @Published private(set) var isFollowingSelectedSource = false
    @Published var isResolvingSourceLink = false
    @Published var sourceLinkCandidateReview: SourceLinkCandidateReviewState?
    @Published private(set) var sourceLinkImportState = "idle"
    @Published private(set) var sourceLinkImportMessage: String?
    @Published var sourceLinkSafariOffer: OpenInSafariOffer? // #145, set in Gate1AppModel+PasteAndGo.swift
    @Published private(set) var selectedListeningEdition: ListeningEdition?
    @Published var automaticMarginOutputEnabled = UserDefaults.standard.bool(forKey: "automaticMarginOutputEnabled")
    @Published var marginOutputStatus = MarginOutputStatus("Choose a folder and send a test note before enabling automatic delivery.")
    @Published private(set) var isImportingReadLater = false
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
    @Published private(set) var mixesWithOtherAudio = false
    @Published private(set) var lowersBackgroundAudio = false
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
    @Published private(set) var episodeMapPreparationStatus = "Not started"
    @Published private(set) var podcastDownloadRecords: [String: PodcastDownloadRecord] = [:]
    @Published var preparedTextAudioStatus = "Not started"
    @Published private(set) var onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.inactive.rawValue
    @Published private(set) var onDeviceSpeechGenerationStopReason: String?
    /// Why narration is in the iOS voice instead of the chosen one (I14); nil when it isn't.
    @Published private(set) var speechFallbackReason: SpeechFallbackReason?
    @Published private(set) var onDeviceSpeechGenerationProgress = RenderedSpeechGenerationProgress(
        completedChunks: 0,
        totalChunks: 0
    )
    @Published private(set) var isOnDeviceSpeechGenerationDelayed = false
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
    @Published private(set) var onboardingProgress = OnboardingProgress(
        storedSteps: UserDefaults.standard.stringArray(forKey: Gate1AppModel.onboardingStepsKey),
        storedStage: UserDefaults.standard.string(forKey: Gate1AppModel.guidedOnboardingStageKey),
        isCardDismissed: UserDefaults.standard.bool(forKey: Gate1AppModel.onboardingCardDismissedKey)
    )
    @Published var knownIssues = [
        "Physical-device product validation remains pending.",
        "Now Playing lock-screen controls require signed real-device validation.",
        "Source link, public podcast, and share-extension intake are experimental until they have their own human validation record."
    ]

    private(set) var engine: SessionEngine?
    private(set) var store: SQLiteSessionStore?
    lazy var listeningSignals = ListeningSignalsCoordinator(repository: { [weak self] in self?.store })
    private var databaseURLOverride: URL?
    let gate2CompactControls: Gate2CompactControlController
    private let featureFlags: SpokenMarginsFeatureFlags
    private let localFoundationModelClient: any LocalFoundationModelClient
    private let openAIResponsesClient = OpenAIResponsesClient()
    private let streamingSpeechQueue = StreamingSpeechQueue()
    private(set) var speechPlaybackClient: AudioPlaybackClient?
    private var sessionAudioPlaybackClient: AudioPlaybackClient?
    private var supertonicRenderer: SupertonicNarrationRenderer?
    private var preparedAudioCoordinator: PreparedAudioCoordinator?
    private var currentSupertonicRenderSignature: TTSRenderSignature? { // older prepared chunks go first when space is needed (#281)
        didSet { if let digest = currentSupertonicRenderSignature?.digest, digest != oldValue?.digest { Task { [ledger = offlineStorageLedger] in _ = try? await ledger?.markSupersededPreparedChunks(currentSignatureDigest: digest) } } }
    }
    private var renderedSpeechDiskCache: RenderedSpeechDiskCache?
    private let sourceLinkResolver: LinkResolutionClient?
    private let sourceLinkHandoffStore: SourceLinkHandoffStore?
    private let browserTextHandoffStore: Gate5BrowserTextHandoffStore?
    private let audioPlaybackClientOverride: AudioPlaybackClient?
    private var mediaPlaybackClient: AVPlayerStreamPlaybackClient?
    private(set) var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    /// Shared by the podcast downloader and the pre-play offline check (#779).
    let connectivity = ConnectivityMonitor()
    private var requestedPodcastTransportReplacements: Set<String> = []
    var offlineStorageLedger: OfflineStorageLedger?
    private var localSourceImporter: LocalSourceImporter?
    private(set) var followedSourceCoordinator: FollowedSourceCoordinator?
    /// A fresh install: the Library was empty before the welcome sample was added (B1 drawer).
    private(set) var libraryWasEmptyAtLaunch = false
    var readablePageExtractor: any ReadablePageExtracting = AppOwnedReadablePageExtractor() // tests replace it (#223)
    let sharedLinkVoiceover = SharedLinkVoiceover() // tests replace its page fetch (#810)
    private var sourceSuggestionChecks: Set<String> = []
    private var followDiscoveries: [String: Task<[SourceCandidateEvidence], Error>] = [:]
    @Published private var followOffers: [String: FollowOffer] = [:]
    private var guidedOnboardingCoordinator: GuidedOnboardingCoordinator?
    private let recordingClientOverride: RecordingClient?
    let microphonePermissionRequest: (() async -> Bool)?
    let microphonePermissionStatusOverride: (() -> PermissionPromptStatus)?
    private let forcePreparedTextGate: Bool
    private let sourceTranscriptionClient: SourceTranscriptionClient
    private let interjectionTranscriptionHandler: InterjectionTranscriptionHandler
    private let alignedInterjectionTranscriptionHandler: AlignedInterjectionTranscriptionHandler?
    private let preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler?
    private let shareMarginSilenceAnalysisHandler: ShareMarginSilenceAnalysisHandler
    private let shareMarginAudioCleanupHandler: ShareMarginAudioCleanupHandler
    private let trashUndoDismissDelay: Duration
    private(set) var activeItemId = "item-pill"
    private var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    private var playbackProgressTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var onDeviceSpeechGenerationDelayTask: Task<Void, Never>?
    private var trashUndoDismissTask: Task<Void, Never>?
    /// Background time while on-device narration starts, on every path into "starting" (#854).
    private lazy var narrationStartupProtection = NarrationStartupProtection(
        begin: NarrationStartupBackgroundTime.begin,
        record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) },
        outcomeChanged: { [weak self] in self?.diagnostics["textAudioBackgroundStartup"] = $0.rawValue }
    )
    /// Background time over each seam between two chunks of on-device narration (#540).
    private lazy var handOverBackgroundHold = HandOverBackgroundHold(
        begin: NarrationStartupBackgroundTime.begin,
        record: { [weak self] kind, fields in self?.recordDeveloperDiagnostic(kind, fields) }
    )
    #if canImport(AVFoundation)
    var interjectionAudioPlayer: AVPlayer?
    var interjectionAudioCompletionTask: Task<Void, Never>?
    private var skimBridgePlayer: AVPlayer?
    private var skimBridgeTask: Task<Void, Never>?
    private var preparingLocalAudioMapItems = Set<String>()
    private var commentaryCuePlayer: AVAudioPlayer?
    #endif
    private var sharedMarginOffers = SharedMarginOfferQueue()
    private var sourceShouldResumeAfterImportedCommentary = false
    private var sourcePausedForImportedCommentaryPrompt = false
    private var importedCommentaryAutoPlayTask: Task<Void, Never>?
    private var bulkSharePreparationTask: Task<Void, Never>?
    private var bulkSharePreparationGeneration = 0
    private var shouldForceFirstSharedSourceMissForUITesting = UITestingHooks.forcesFirstSharedSourceMiss
    private var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    var foregroundAudioPreparationTask: Task<Void, Never>?
    private let libraryAudioRenderGate = SerialWorkGate() // one Library item renders at a time (#281)
    var libraryAudioTurns = LibraryAudioPreparationTurns() // which item the two passes are on (#281, #534)
    var libraryAudioPreparingItemId: String? { get { libraryAudioTurns.preparingItemId } set { libraryAudioTurns.preparingItemId = newValue } }
    var foregroundAudioPreparationGeneration = 0
    private var episodeMapPreparationTask: Task<Void, Never>?
    private var episodeMapPreparationItemId: String?
    private var isUpdatingSkimAvailability = false
    private var backgroundPreparationPlanner = BackgroundPreparationPlanner()
    private var sourceImportTask: Task<Void, Never>?
    private var quickAccessRefreshTask: Task<Void, Never>?
    private var quickAccessRefreshID = UUID()
    private var liveSpeechFallbackItemIds: Set<String> = []
    private var suppressedAutomaticAudioPreparationItemIds = Set(
        UserDefaults.standard.stringArray(forKey: Gate1AppModel.suppressedAudioPreparationItemIdsKey) ?? []
    )
    private var pendingStartupAudioPreparationItemIds: Set<String> = []
    private var failedStartupAudioPreparationItemIds: Set<String> = []
    private var isImportingPendingSourceLinkHandoffs = false
    private var pendingAutoPlayQueue = Gate1PlaybackAutoplayQueue()
    private var completedStreamingTurnIds: Set<String> = []
    @Published private var pendingSourceContextInterjectionIds: Set<String> = []
    private let sourceWindowJobQueue = SourceWindowJobQueue()
    private var pendingFullSourceTranscriptionItemIds: Set<String> = []
    private let podcastPlacementPassCoordinator = PodcastPlacementPassCoordinator()
    private var importedPodcastResolutionURLs: [String: URL] = [:]
    var deferredPodcastPlacementURLs: [String: URL] = [:] // see Gate1AppModel+PodcastPlacementDeferral (#914)
    /// Placement work in flight, so its shared Margins read "placing", not "unresolved" (#872).
    private var sharedMarginPlacementPasses = SharedMarginPlacementPasses() { didSet {
        if oldValue.pass(itemId: activeItemId) != sharedMarginPlacementPasses.pass(itemId: activeItemId) { refreshSelectedItem() }
        if oldValue != sharedMarginPlacementPasses { refreshMarginRows() } } }
    private var importedTranscriptRetryDates: [String: Date] = [:]
    private var importedPodcastRecipientLocalURLs: [String: URL] = [:]
    private var pendingMapGenerationItemId: String?
    private var pendingProviderJobForConsent: PendingProviderJob?
    private var pendingMapGenerationAfterConsent = false
    private(set) var pendingTermsVoiceSelection: AppTTSVoiceSelection?
    var pendingPlaybackAfterTerms: PendingPlaybackAfterTerms?
    private let preparedTextAudioStarterDurationMs = 30_000
    private static let startupAudioChunkCount = 2
    var preparationSeams = PreparationPassSeams()
    var isWaitingOutPreparationHeat = false // the foreground loop sleeps until the phone cools (#905)
    private static let lastPreparedAudioNoticeDateKey = "lastPreparedAudioNoticeDateV1"
    private let sourceWindowContextBeforeMs = SourceAnchorContextResolver.windowBeforeMs
    private let sourceWindowContextAfterMs = SourceAnchorContextResolver.windowAfterMs
    private let quickAccessFolderBookmarkKey = "quickAccessFolderBookmark"
    #if canImport(AVFoundation)
    private let speechPreviewSynthesizer = AVSpeechSynthesizer()
    private var supertonicPreviewPlayer: AVAudioPlayer?
    private var supertonicPreviewURL: URL?
    #endif
    private let encoder: JSONEncoder = {
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
    private static func availableSpeechVoiceOptions() -> [SpeechVoiceChoice] {
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

    var guidedOnboardingStage: GuidedOnboardingStage { onboardingProgress.stage }

    var isOnboardingCardDismissed: Bool { onboardingProgress.isCardDismissed }

    var onboardingCoreCompletedCount: Int { onboardingProgress.coreCompletedCount }

    var hasCompletedCoreOnboarding: Bool { onboardingProgress.hasCompletedCore }

    var shouldShowOnboardingCard: Bool {
        onboardingProgress.shouldShowCard(
            suppressed: Self.isRunningUnitTests || UITestingHooks.isActive
        )
    }

    var shouldShowGuidedOnboardingCoach: Bool {
        onboardingProgress.shouldShowCoach(guidedItemIsSelected: selectedItem.id == Self.guidedOnboardingItemId)
    }

    func isOnboardingStepComplete(_ step: OnboardingStep) -> Bool {
        onboardingProgress.isComplete(step)
    }

    func markOnboardingSteps(_ steps: Set<OnboardingStep>) {
        changeOnboardingProgress { $0.mark(steps) }
    }

    private func setGuidedOnboardingStage(_ stage: GuidedOnboardingStage) {
        changeOnboardingProgress { $0.setStage(stage) }
    }

    /// Applies one transition to a copy, then stores it and writes only the UserDefaults keys it names.
    /// A transition that changes nothing leaves the published value alone, so views are not redrawn for it.
    private func changeOnboardingProgress(_ transition: (inout OnboardingProgress) -> OnboardingProgress.Change) {
        var updated = onboardingProgress
        let change = transition(&updated)
        guard !change.isEmpty else { return }
        onboardingProgress = updated
        if change.contains(.steps) {
            UserDefaults.standard.set(updated.storedSteps, forKey: Self.onboardingStepsKey)
        }
        if change.contains(.stage) {
            UserDefaults.standard.set(updated.storedStage, forKey: Self.guidedOnboardingStageKey)
        }
        if change.contains(.card) {
            UserDefaults.standard.set(updated.isCardDismissed, forKey: Self.onboardingCardDismissedKey)
        }
    }

    private func reconcileOnboardingEvidence(store: SQLiteSessionStore) throws {
        let items = try store.listItems()
        var evidence = OnboardingEvidenceClassifier.sourceSteps(items: items)
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
        changeOnboardingProgress { $0.dismissCard() }
    }

    func restoreOnboardingCard() {
        changeOnboardingProgress { $0.restoreCard() }
    }

    func pauseGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func continueGuidedOnboardingPastAI() {
        changeOnboardingProgress { $0.continuePastAI() }
    }

    func openAISettingsFromOnboarding() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings_from_onboarding") else { return }
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
        changeOnboardingProgress { $0.timelineReviewed() }
    }

    func recordSessionExported() {
        guard exportSessionId != nil else { return }
        changeOnboardingProgress { $0.sessionExported() }
    }

    #if DEBUG
    /// Tests that model a write through the app must share its serialized connection.
    /// Opening another connection also races unrelated offline-ledger startup work.
    func libraryStoreForTesting() throws -> SQLiteSessionStore {
        precondition(Self.isRunningUnitTests)
        return try requireStore()
    }
    #endif

    func resetOnboardingProgressForTesting() {
        guard Self.isRunningUnitTests else { return }
        onboardingProgress = OnboardingProgress(storedSteps: nil, storedStage: nil, isCardDismissed: false)
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
        microphonePermissionRequest: (() async -> Bool)? = nil,
        microphonePermissionStatus: (() -> PermissionPromptStatus)? = nil,
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
        self.sourceLinkResolver = sourceLinkResolver ?? UITestingHooks.ambiguousSourceLinkResolver
        self.sourceLinkHandoffStore = sourceLinkHandoffStore
        self.browserTextHandoffStore = browserTextHandoffStore
        self.audioPlaybackClientOverride = audioPlaybackClient
        self.recordingClientOverride = recordingClient
        self.microphonePermissionRequest = microphonePermissionRequest
        self.microphonePermissionStatusOverride = microphonePermissionStatus
        self.forcePreparedTextGate = forcePreparedTextGate
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
            return "This item has a private Listening Map with \(selectedItem.listeningMapScenes.count) scene\(selectedItem.listeningMapScenes.count == 1 ? "" : "s")."
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

    var selectedPodcastDownloadState: PodcastDownloadState? {
        if let state = podcastDownloadRecords[selectedItem.id]?.state { return state }
        if let item = try? store?.loadItem(id: selectedItem.id), item.media?.sourceType == .remoteStream { return .streamingOnly }
        return nil
    }

    var selectedPodcastDownloadDescription: String? {
        guard let record = podcastDownloadRecords[selectedItem.id] else { return nil }
        if record.state == .downloading, let progress = record.progress {
            return "Downloading \(Int((progress * 100).rounded()))%"
        }
        if record.state == .failed, let reason = record.failureReason {
            return "Failed: \(reason)"
        }
        switch record.state {
        case .availableOffline:
            return "Downloaded for offline playback"
        case .waitingForWiFi:
            return "Waiting for Wi-Fi · Download Now can force it"
        case .streamingOnly:
            return "Online only · Download Now saves it in the app"
        case .downloading:
            return "Downloading"
        case .failed:
            return "Download failed"
        case .evicted:
            return "Download was removed to free space"
        }
    }

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
        foregroundAudioPreparationTask?.cancel()
        sourceImportTask?.cancel()
        quickAccessRefreshTask?.cancel()
        interjectionAudioCompletionTask?.cancel()
        importedCommentaryAutoPlayTask?.cancel()
        bulkSharePreparationTask?.cancel()
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
                await MainActor.run { self?.tickPlaybackProgress() }
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

    func handleAppBecameInactiveOrBackground(entersBackground: Bool = false) {
        if entersBackground { narrationStartupProtection.appEnteredBackground() }
        marginNotesDelivery.finishBeforeBackground(); readwiseHighlightSync.stop()
        supertonicRenderer?.setBackgroundInferencePacingEnabled(true)
        if snapshot.status == .starting,
           let supertonic = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
           supertonic.ensurePlaybackStartsBeforeBackgrounding() {
            diagnostics["textAudioBackgroundStartup"] = "system_fallback_started"
        }
        syncPlaybackProgressForLifecycle()
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

    func bootstrapLibraryIfNeeded() {
        guard libraryItems.isEmpty, store == nil else { return }
        do {
            let store = try requireStore()
            libraryAccessError = nil
            purgeExpiredEpisodeMapPreparationJobs(store: store)
            switch UITestingHooks.seed {
            case .none, .keepLibrary: break
            case .fixture: resetAndSeed(); return
            case .importedPDF: resetAndSeed(); try importObsidianMarkdownFiles(urls: [UITestingLaunchSeedWriter.writePDF()]); return
            case .text, .offlinePodcast:
                try seedUITesting(store: store, item: UITestingLaunchSeedWriter.write(UITestingHooks.seed, into: store)); return
            }
            var rows = try loadLibraryRows(store: store)
            libraryWasEmptyAtLaunch = rows.isEmpty
            let storedWelcomeSampleVersion = UserDefaults.standard.integer(
                forKey: Self.welcomeSampleSeedVersionKey
            )
            if Self.shouldSeedWelcomeSample(
                libraryIsEmpty: rows.isEmpty,
                storedVersion: storedWelcomeSampleVersion,
                isUITesting: UITestingHooks.isActive
            ) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                rows = try loadLibraryRows(store: store)
                diagnostics["welcomeSample"] = "seeded:v\(Self.welcomeSampleSeedVersion)"
            }
            if !UITestingHooks.isActive,
               !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
               UserDefaults.standard.integer(forKey: Self.guidedOnboardingSeedVersionKey) < 1,
               !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                rows = try loadLibraryRows(store: store)
                diagnostics["guidedOnboardingItem"] = "bundled_fallback_seeded"
            }
            if !UITestingHooks.isActive,
               storedWelcomeSampleVersion < Self.welcomeSampleSeedVersion {
                UserDefaults.standard.set(
                    Self.welcomeSampleSeedVersion,
                    forKey: Self.welcomeSampleSeedVersionKey
                )
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            // Installing the Supertonic client establishes the current render
            // signature. Re-project rows so startup readiness never reuses a
            // manifest from an obsolete voice or model identity.
            rows = try loadLibraryRows(store: store)
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
                try prepareSourceMediaPlayback(itemId: restoredSession.itemId)
                selectedItem = try loadItemDetail(id: restoredSession.itemId, store: store)
                diagnostics["restoredSession"] = restoredSession.id
                diagnostics["restoredSessionMode"] = "paused_without_autoplay"
            } else if let first = rows.first {
                activeItemId = first.id
                selectedItem = try loadItemDetail(id: first.id, store: store)
            } else {
                selectedItem = ItemDetailState()
            }
            refreshMarginRows()
            tryRefreshOfflineStorageUsage()
            diagnostics["libraryBootstrap"] = "loaded:\(rows.count)"
            reportSuccess(rows.isEmpty ? "Add a source to begin." : "Library ready.")
            try refreshAudioPreparationPresentation(store: store, announceNewCompletions: true)
            scheduleAutomaticAudioPreparationIfNeeded()
            // Recover missing opening windows as well as durable jobs. Yield
            // between items so a populated Library remains interactive.
            let startupCandidates = Self.startupPreparationCandidates(rows)
            Task { @MainActor [weak self] in
                for itemId in startupCandidates {
                    guard !Task.isCancelled, let self else { return }
                    self.scheduleStartupAudioPreparationIfNeeded(itemId: itemId)
                    await Task.yield()
                }
            }
            startForegroundAudioPreparationIfNeeded()
        } catch {
            libraryAccessError = "This build could not open your existing library. This attempt did not reset it. Do not use Reset Library or delete the app; install a compatible build and try again. Details: \(error.localizedDescription)"
            diagnostics["libraryBootstrap"] = "failed_without_reset:\(error.localizedDescription)"
            reportFailure(error, context: "Library bootstrap failed")
        }
    }

    /// Finishes a UI-test launch whose seed writer has reset the store and added `item`.
    private func seedUITesting(store: SQLiteSessionStore, item: Item) throws {
        self.store = store
        try configurePodcastDownloads(store: store)
        installEngine(try makeEngine(store: store))
        activeItemId = item.id
        if item.mediaType == "text" { liveSpeechFallbackItemIds.insert(item.id) }
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
        reportSuccess("Loaded UI test item \(item.title).")
    }

    static func shouldSeedWelcomeSample(
        libraryIsEmpty: Bool,
        storedVersion: Int,
        isUITesting: Bool
    ) -> Bool {
        libraryIsEmpty && storedVersion < welcomeSampleSeedVersion && !isUITesting
    }

    func handleAppBecameActive() {
        narrationStartupProtection.appEnteredForeground()
        openReadyListeningEdition()
        marginNotesDelivery.start(); readwiseHighlightSync.start { [weak self] in self?.store }
        if let store { CommunityMapUploadService.shared.retryFailed(store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 } }
        supertonicRenderer?.setBackgroundInferencePacingEnabled(false)
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

    func automaticAudioPreparationPolicyChanged() {
        UserDefaults.standard.set(
            automaticAudioPreparationPolicy.rawValue,
            forKey: "automaticAudioPreparationPolicy"
        )
        diagnostics["automaticAudioPreparation"] = automaticAudioPreparationPolicy.rawValue
        scheduleAutomaticAudioPreparationIfNeeded()
    }

    func automaticEpisodeMapPreparationPolicyChanged() {
        UserDefaults.standard.set(
            automaticEpisodeMapPreparationPolicy.rawValue,
            forKey: "automaticEpisodeMapPreparationPolicy"
        )
        diagnostics["automaticEpisodeMapPreparation"] = automaticEpisodeMapPreparationPolicy.rawValue
        submitAutomaticEpisodeMapPreparationIfNeeded()
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
                items: store.listItems(), sessions: store.loadSessions(),
                loadInterjections: { try store.loadInterjections(sessionId: $0) },
                loadImportedLayers: { try store.loadImportedCommentaryLayers() },
                loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) }
            )
            sharedMarginRows = entries.sharedRows.map {
                SharedMarginRow(interjection: $0.interjection, layer: $0.layer, itemTitle: $0.itemTitle,
                                placement: sharedMarginPlacementPasses.pass(itemId: $0.layer.itemId))
            }
            marginRows = entries.privateRows.map {
                MarginRow(interjection: $0.interjection, itemTitle: $0.itemTitle, sessionDate: $0.sessionDate)
            }
            marginNotesDelivery.deliverSoon() // A Margin or its transcript may be new (#171).
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
            snapshot = try engine.playInterjectionAnchor(interjection)
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

    /// Spoken podcast Margins get the full moment: lead-in, the Margin inline, then the item's other spoken
    /// Margins as playback reaches them. Written Margins and text items keep playing from the anchor.
    private func startMarginMomentIfSpoken(_ interjection: Interjection, store: SQLiteSessionStore) {
        guard interjection.isInlineSpokenMargin, let anchorMs = interjection.anchor.mediaTimeMs else { return }
        let sessions: [Session] = (try? store.loadSessions(itemId: interjection.itemId)) ?? []
        let spoken: [Interjection] = sessions
            .flatMap { session -> [Interjection] in (try? store.loadInterjections(sessionId: session.id)) ?? [] }
            .filter(\.isInlineSpokenMargin)
        var voiceURLs: [String: URL] = [:]
        for margin in spoken + [interjection] {
            if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }
        }
        startMarginMoment(
            itemId: interjection.itemId,
            target: MarginMomentAnchor(marginId: Self.marginIdentity(interjection), mediaTimeMs: anchorMs),
            otherMargins: spoken.map {
                MarginMomentAnchor(marginId: Self.marginIdentity($0), mediaTimeMs: $0.anchor.mediaTimeMs ?? 0)
            },
            voiceURLs: voiceURLs,
            title: "Your Margin",
            isApproximate: false
        )
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
        endMarginMoment()
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID else { return }
        // The moment plays this voice; the automatic shared-Margin prompt mustn't play it again.
        sharedMarginOffers.markAnnounced(row.interjection.id)
        let targetID = "shared::\(row.layer.id)::\(row.interjection.id)"
        startMarginMoment(
            itemId: itemID,
            target: MarginMomentAnchor(marginId: targetID, mediaTimeMs: position.mediaTimeMs),
            otherMargins: [],
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

    private func startMarginMoment(
        itemId: String,
        target: MarginMomentAnchor,
        otherMargins: [MarginMomentAnchor],
        voiceURLs: [String: URL],
        title: String,
        isApproximate: Bool
    ) {
        let sequence = MarginMomentSequence(itemId: itemId, target: target, otherMargins: otherMargins)
        let conductor = MarginMomentConductor(
            sequence: sequence,
            source: .init(
                pause: { [weak self] in self?.pause() },
                resume: { [weak self] in self?.resumePlayback() },
                seek: { [weak self] in _ = self?.seekMedia(toMediaTimeMs: $0) }
            ),
            voiceURL: { voiceURLs[$0] }
        )
        conductor.voiceRate = Float(Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate))
        conductor.prepareAudioSession = {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
        }
        conductor.onVoiceUnavailable = { [weak self] (marginId: String, reason: String) in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            self?.reportWarning("That Margin's recording couldn't play, so listening continues.")
        }
        conductor.onChange = { [weak self, weak conductor] in
            guard let self, let conductor, self.marginMomentConductor === conductor else { return }
            self.marginMoment = conductor.sequence
            self.marginMomentVoiceIsPaused = conductor.isVoicePaused
            // Nothing left to play inline: the card goes away and the item simply continues.
            if conductor.sequence.phase == .listening, conductor.sequence.unplayed.isEmpty { self.endMarginMoment() }
        }
        marginMomentConductor = conductor
        marginMomentTitle = title
        marginMomentPositionIsApproximate = isApproximate
        conductor.start()
        diagnostics["marginMoment.chime"] = nil
        diagnostics["marginMoment"] = "started:lead_in_ms=\(target.mediaTimeMs - sequence.startMediaTimeMs);others=\(sequence.unplayed.count - 1);approximate=\(isApproximate)"
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
        marginMomentConductor?.cancel()
        marginMomentConductor = nil
        marginMoment = nil
        marginMomentVoiceIsPaused = false
    }

    private func observeMarginMoment(_ current: SessionSnapshot) {
        guard let conductor = marginMomentConductor else { return }
        guard current.itemId == conductor.sequence.itemId else { return endMarginMoment() }
        conductor.observe(mediaTimeMs: current.currentMediaTimeMs)
    }

    private func tryRefreshOfflineStorageUsage() {
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

    private func scheduleAutomaticAudioPreparationIfNeeded() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        let enabled = automaticAudioPreparationPolicy == .whileCharging
        Task { [weak self] in
            if enabled { await self?.enqueueAutomaticAudioPreparationJobs() }
            AudioPreparationBackgroundController.shared.submitIfEnabled(
                enabled || self?.automaticEpisodeMapPreparationPolicy == .whileCharging
            )
        }
        #endif
    }

    private func performBackgroundPreparationPass() async -> BackgroundPreparationWorkResult {
        guard let store else { return .finished }
        let progressToken = {
            BackgroundPreparationPlanner.progressToken(
                audioJobs: (try? store.loadAudioPreparationJobs()) ?? [],
                episodeJobs: (try? store.loadEpisodeMapPreparationJobs()) ?? []
            )
        }
        let progressBefore = progressToken()
        let episodeJobs = BackgroundPreparationPlanner.eligibleEpisodeJobs(
            (try? store.loadEpisodeMapPreparationJobs()) ?? [],
            episodePolicy: automaticEpisodeMapPreparationPolicy,
            hasLocalAudio: { self.podcastDownloadCoordinator?.validatedLocalURL(for: $0) != nil }
        )
        let hasAudioWork = ((try? store.loadAudioPreparationJobs()) ?? []).contains { !$0.isCancelled }
        if let job = backgroundPreparationPlanner.plan(
            hasAudioWork: hasAudioWork,
            episodeJobs: episodeJobs,
            environment: .init(
                thermalIsSerious: ProcessInfo.processInfo.thermalState == .serious
                    || ProcessInfo.processInfo.thermalState == .critical,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                episodeTaskIsRunning: episodeMapPreparationTask != nil
            )
        ) {
            prepareEpisodeMap(itemId: job.itemId, policy: job.policy)
            if let task = episodeMapPreparationTask {
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            backgroundPreparationPlanner.afterEpisodePass()
            let hasEpisodeWork = ((try? store.loadEpisodeMapPreparationJobs()) ?? []).contains {
                !$0.isCancelled && $0.stage != .completed
            }
            return BackgroundPreparationPlanner.result(
                hasRemainingWork: hasEpisodeWork || hasAudioWork,
                before: progressBefore,
                after: progressToken()
            )
        }
        let audioHasMore = await performBackgroundAudioPreparationPass()
        let hasRemainingWork = backgroundPreparationPlanner.afterAudioPass(
            audioHasMore: audioHasMore, hadAudioWork: hasAudioWork, hadEpisodeJobs: !episodeJobs.isEmpty
        )
        return BackgroundPreparationPlanner.result(
            hasRemainingWork: hasRemainingWork, before: progressBefore, after: progressToken()
        )
    }

    func handleApplicationWillTerminate() {
        stopImportedCommentaryPlayback(resumeSource: false)
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        syncPlaybackProgressForLifecycle()
        narrationStartupProtection.stop()
        gate2CompactControls.endLiveActivities()
    }

    func handleMemoryWarning() {
        Self.preparationPlanCache.removeAll()
        activePlaybackDetail = nil
        SupertonicResourcePolicy.memoryBackoff.recordWarning()
        // Cancel demand before unloading: otherwise the next chunk can reload
        // the same sessions immediately after the warning.
        foregroundAudioPreparationTask?.cancel()
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
        if let renderer = supertonicRenderer {
            Task { await renderer.unload(removingGeneratedAudio: false) }
        }
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
            refreshMarginRows()
            tryRefreshOfflineStorageUsage()
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
            if !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingTombstoneKey)
                try refreshLibraryRows(store: store)
            } else if try store.loadListeningMap(itemId: Self.guidedOnboardingItemId) == nil {
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            restoreOnboardingCard()
            isHelpPresented = false
            setGuidedOnboardingStage(onboardingProgress.tourResumeStage)
            startItem(id: Self.guidedOnboardingItemId)
        } catch {
            reportFailure(error, context: "Guided tour setup failed")
        }
    }

    private func makeAppOverviewSample() throws -> (Item, ListeningMap) {
        try WelcomeSample.make(itemId: Self.welcomeSampleItemId, remoteProviderExperienceEnabled: remoteProviderExperienceEnabled)
    }

    func importTextItem(startListening: Bool = true) {
        do {
            let store = try requireStore()
            let preservesActiveSession = !startListening && hasActiveSession && engine != nil
            let itemId = "item-import-\(UUID().uuidString.lowercased())"
            let enteredTitle = importTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try ObsidianMarkdownParser.parse(
                fileName: enteredTitle.isEmpty ? "\(importText.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")).md" : "\(enteredTitle).md",
                contents: importText,
                titleOverride: enteredTitle.isEmpty ? nil : enteredTitle
            )
            let deterministicMap = parsed.deterministicListeningMap(itemId: itemId, policy: .canonicalHeadings)
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
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            libraryItems = try loadLibraryRows(store: store)
            if !preservesActiveSession && startListening {
                activeItemId = item.id
                selectedItem = try loadItemDetail(id: item.id, store: store)
            }
            diagnostics["lastImport"] = item.id
            markOnboardingSteps([.addedOwnSource])
            importTitle = ""
            importText = ""
            if startListening {
                startItem(id: item.id)
            } else {
                reportAddedToLibrary(title: item.title, itemId: item.id)
            }
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
        let html = UIPasteboard.general.data(forPasteboardType: "public.html")
            .flatMap { $0.count <= 2_000_000 ? String(data: $0, encoding: .utf8) : nil }
        importText = Self.pastedSourceText(plainText: clipboardText, html: html)
        reportSuccess("Pasted text from Clipboard.")
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    func importObsidianMarkdownFiles(urls: [URL]) {
        beginObsidianMarkdownImport(urls: urls, securityScopedURLs: urls)
    }

    func importEPUBFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importEPUB(from: url)
                guard let store = self.store else { return }
                self.libraryItems = try self.loadLibraryRows(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
                if openWhenFinished {
                    self.selectedItem = try self.loadItemDetail(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportAddedToLibrary(title: item.title, itemId: item.id)
                }
            } catch {
                self.reportFailure(error, context: "EPUB import failed")
            }
        }
    }

    func importAudiobookFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importAudiobook(from: url)
                guard let store = self.store else { return }
                self.libraryItems = try self.loadLibraryRows(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.refreshSpokenMarginsPackageImportAfterAddingSource()
                if openWhenFinished {
                    self.selectedItem = try self.loadItemDetail(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportAddedToLibrary(title: item.title, itemId: item.id)
                }
            } catch {
                self.reportFailure(error, context: "Audiobook import failed")
            }
        }
    }

    var isImportingSources: Bool {
        sourceImportProgressMessage != nil
    }

    private var cachedQuickAddCandidates: [QuickAddCandidate]?

    var quickAddCandidates: [QuickAddCandidate] {
        if let cachedQuickAddCandidates { return cachedQuickAddCandidates }
        let candidates = Self.quickAddCandidates(
            folderFiles: quickAccessRecentFiles,
            followedEntries: followedSourceEntries,
            subscriptions: feedSubscriptions,
            libraryItems: libraryItems,
            dismissedFileKeys: dismissedQuickAccessFileKeys
        )
        cachedQuickAddCandidates = candidates
        return candidates
    }

    var isRefreshingQuickAddFeed: Bool {
        isRefreshingQuickAccessFolder || isRefreshingFollowedSources
    }

    nonisolated static func quickAddCandidates(
        folderFiles: [QuickAccessFile],
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription] = [],
        libraryItems: [LibraryItemRow] = [],
        dismissedFileKeys: Set<String> = []
    ) -> [QuickAddCandidate] {
        QuickAddFeed.candidates(
            folderFiles: folderFiles,
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems.map {
                QuickAddImportedItem(sourceReference: $0.sourceReference, title: $0.title, sourceTitle: $0.sourceTitle)
            },
            dismissedFileKeys: dismissedFileKeys
        )
    }

    func dismissQuickAccessFile(_ file: QuickAccessFile) {
        dismissedQuickAccessFileKeys.insert(file.dismissalKey)
        UserDefaults.standard.set(
            dismissedQuickAccessFileKeys.sorted(),
            forKey: Self.dismissedQuickAccessFilesKey
        )
    }

    private func beginObsidianMarkdownImport(
        urls: [URL],
        securityScopedURLs: [URL],
        refreshQuickFolderWhenFinished: Bool = false,
        openImportedItemWhenFinished: Bool = false,
        quickAccessFileToDismiss: QuickAccessFile? = nil
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
                await Self.prepareObsidianImports(requests)
            }.value
            scopedAccess.forEach { entry in
                if entry.didAccess {
                    entry.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            self.completeObsidianMarkdownImport(
                batch,
                refreshQuickFolderWhenFinished: refreshQuickFolderWhenFinished,
                openImportedItemWhenFinished: openImportedItemWhenFinished,
                quickAccessFileToDismiss: quickAccessFileToDismiss
            )
        }
    }

    private nonisolated static func prepareObsidianImports(_ requests: [ObsidianImportRequest]) async -> ObsidianImportBatch {
        var prepared: [PreparedObsidianImport] = []
        var failures: [String] = []
        for request in requests {
            do {
                let imported = try await importableText(from: request.url)
                prepared.append(try SourceFileItemBuilder.prepare(
                    imported, fileURL: request.url, itemId: request.itemId, createdAt: Date()
                ))
            } catch {
                failures.append("\(request.url.lastPathComponent): \(error)")
            }
        }
        return ObsidianImportBatch(prepared: prepared, failures: failures)
    }

    private nonisolated static func importableText(from url: URL) async throws -> ImportedSourceText {
        guard url.pathExtension.lowercased() == "pdf" else {
            return ImportedSourceText(
                text: try String(contentsOf: url, encoding: .utf8),
                documentStructure: nil
            )
        }
        #if canImport(PDFKit)
        do {
            let extracted = try NativePDFDocumentExtractor.extractStructured(from: url)
            return ImportedSourceText(
                text: extracted.document.text,
                documentStructure: extracted.documentStructure,
                structuredDocument: extracted.document,
                title: extracted.title
            )
        } catch PDFStructuredTextExtractor.ExtractionError.noExtractableText {
            throw SourceFileImportError.pdfHasNoExtractableText
        }
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    private func completeObsidianMarkdownImport(
        _ batch: ObsidianImportBatch,
        refreshQuickFolderWhenFinished: Bool,
        openImportedItemWhenFinished: Bool,
        quickAccessFileToDismiss: QuickAccessFile?
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
                    if let document = prepared.structuredDocument {
                        try store.saveStructuredDocument(document, itemId: prepared.item.id)
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
            if openImportedItemWhenFinished, let item = imported.first {
                activeItemId = item.id
                selectedItem = try loadItemDetail(id: item.id, store: store)
                screen = .item
            } else if preservesActiveSession {
                activeItemId = preservedActiveItemId
                if !preservedSelectedItemId.isEmpty {
                    selectedItem = try loadItemDetail(id: preservedSelectedItemId, store: store)
                }
            } else {
                activeItemId = imported.first?.id ?? activeItemId
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
                screen = .home
            }
            if let quickAccessFileToDismiss {
                dismissQuickAccessFile(quickAccessFileToDismiss)
            }
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            if let structure = imported.compactMap(\.documentStructure).last {
                recordPDFExtractionDiagnostics(structure)
            }
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
    func beginSourceLinkImportFromForm(startSession: Bool = true) -> Bool {
        guard !isResolvingSourceLink else { return false }
        let submittedURL = sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: submittedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host != nil else {
            sourceLinkImportState = "failure"
            sourceLinkImportMessage = submittedURL.isEmpty
                ? "Paste or enter a link to an article, podcast, feed or audio file first."
                : "Enter a valid web link (http or https) to an article, podcast, feed or audio file."
            reportFailure(sourceLinkImportMessage ?? "Enter a valid source URL.")
            return false
        }
        isResolvingSourceLink = true
        sourceLinkSafariOffer = nil
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
                startSession: startSession && !hasActiveSession
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
                sourceLinkImportMessage = imported ? "Source added." : (sourceLinkSafariOffer?.message ?? lastError ?? "This source could not be added.")
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

    /// Fills the Following feed field from the clipboard (#153). Returns false when the clipboard has no link.
    @discardableResult
    func pasteFollowedSourceFromClipboard() -> Bool {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string, let url = Self.firstURL(in: text) else { return false }
        followedSourceURL = url.absoluteString
        return true
        #else
        return false
        #endif
    }

    func resetSourceLinkImportState() {
        guard !isResolvingSourceLink else { return }
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        sourceLinkSafariOffer = nil
    }

    @discardableResult
    func importSourceLink(_ handoff: SourceLinkHandoff) -> Bool {
        importSourceLink(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(_ handoff: SourceLinkHandoff) async -> Bool {
        await importSourceLinkAsync(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(urlString: String, sourceSurface: String, startSession: Bool = true) async -> Bool {
        withdrawRetryOffer("sourceLink")
        let shouldStartSession = startSession && !hasActiveSession
        guard sourceLinkResolver == nil else {
            return importSourceLink(urlString: urlString, sourceSurface: sourceSurface, startSession: shouldStartSession)
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
            let fetched = FetchedPageMemo() // the voiceover lookup reads the post page from here (#810)
            let result = try await PublicPodcastLinkResolver().remembering(fetched).resolveAsync(request)
            if result.isPDFDocument { return try await importPDFFromLinkField(url) }
            if let article = await readLinkAsArticleOrOfferSafari(url, after: result, startSession: shouldStartSession) {
                guard let itemId = importBrowserTextItem(article) else { return false }
                rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: fetched)
                return true
            }
            return importResolvedSourceLink(request: request, result: result, startSession: shouldStartSession)
        } catch {
            offerSafariIfUnreadable(url, error: error)
            reportFailure(error, context: "Source link import failed", retry: .init(key: "sourceLink") { [weak self] in
                self?.sourceLinkURL = urlString
                _ = self?.beginSourceLinkImportFromForm(startSession: startSession)
            })
            return false
        }
    }

    @discardableResult
    func importSourceLink(urlString: String, sourceSurface: String, startSession: Bool = true) -> Bool {
        let shouldStartSession = startSession && !hasActiveSession
        if hasActiveSession, sourceLinkResolver == nil {
            Task { @MainActor in
                _ = await importSourceLinkAsync(
                    urlString: urlString,
                    sourceSurface: sourceSurface,
                    startSession: false
                )
            }
            return true
        }
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
            if !shouldStartSession, let sourceLinkResolver {
                let request = LinkResolutionRequest(
                    id: "source-link-\(Int(Date().timeIntervalSince1970))",
                    inputURL: url.absoluteString,
                    sourceSurface: sourceSurface,
                    createdAt: Date()
                )
                return importResolvedSourceLink(
                    request: request,
                    result: try sourceLinkResolver.resolve(request),
                    startSession: false
                )
            }
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
            let imported = try engine.importSourceLink(request, startSessionWhenPlayable: shouldStartSession)
            snapshot = shouldStartSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
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
               presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: shouldStartSession) {
                return false
            }
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = shouldStartSession ? .playback : .item
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
                reportConfirmation(shouldStartSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(SourceLinkFailureMessage.text(
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
            if !startSession {
                guard let item = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
                    reportFailure(SourceLinkFailureMessage.text(
                        status: result.status.rawValue,
                        reason: result.failureReason,
                        provider: result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
                    ))
                    return false
                }
                reportAddedToLibrary(title: item.title, itemId: item.id)
                return true
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
            reportFailure(SourceLinkFailureMessage.text(
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

    private func persistResolvedSourceLinkInBackground(
        request: LinkResolutionRequest,
        result: LinkResolutionResult
    ) throws -> Item? {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(request, result: result) else {
            return nil
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        scheduleSourceTranscriptImportIfAvailable(
            result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
            itemId: item.id
        )
        return item
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

    @discardableResult
    private func importSourceLinkInBackground(_ handoff: SourceLinkHandoff, feedEntry: FeedEntry? = nil, subscription: FeedSubscription? = nil) async throws -> String? {
        let trimmed = handoff.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if handoff.sourceSurface == "share_sheet_pdf_file",
           let fileURL = URL(string: trimmed),
           fileURL.isFileURL {
            let handoffStore = try SourceLinkHandoffStore.appGroup()
            guard handoffStore.isManagedPDFURL(fileURL) else {
                throw SessionKitError.persistenceFailed("The shared PDF is no longer available to import.")
            }
            try await importLocalSharedPDFInBackground(url: fileURL)
            handoffStore.deleteManagedPDF(at: fileURL)
            return nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SessionKitError.persistenceFailed("This share does not contain a valid podcast, RSS, or audio URL.")
        }
        if Self.isRemotePDFHandoff(handoff) {
            try await importRemotePDFInBackground(url: url)
            return nil
        }
        let request = LinkResolutionRequest(
            id: handoff.id,
            inputURL: url.absoluteString,
            sourceSurface: handoff.sourceSurface,
            createdAt: Date()
        )
        let fetched = FetchedPageMemo() // the voiceover lookup reads the post page from here (#810)
        let resolution = try await LinkArticleFallback.resolve(
            request, url: url, resolver: sourceLinkResolver, remembering: fetched, allowsArticle: feedEntry == nil,
            using: readablePageExtractor, record: { diagnostics["lastSourceLinkArticleFallback"] = $0 }
        )
        guard case .podcast(let result) = resolution else {
            if case .article(let article) = resolution {
                let itemId = try importBrowserTextInBackground(article)
                rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: fetched)
            }
            return nil
        }
        guard result.status == .playable else {
            if feedEntry == nil, result.isPDFDocument { try await importRemotePDFInBackground(url: url); return nil } // #758
            let provider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkFailureCategory"] = result.failureReason
                ?? result.status.rawValue
            throw SessionKitError.persistenceFailed(SourceLinkFailureMessage.text(
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
              let item = try engine.importResolvedSourceLinkInBackground(
                request,
                result: result,
                sourceIdentity: feedEntry.map { "\($0.subscriptionId):\($0.id)" }
              ) else {
            throw SessionKitError.persistenceFailed("The shared podcast did not expose playable audio.")
        }
        if let feedEntry {
            var identified = item
            let title = feedEntry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { identified.title = title }
            identified.sourceTitle = subscription?.source.title ?? identified.sourceTitle
            identified.sourceURL = subscription?.source.canonicalURL ?? identified.sourceURL
            identified.externalReference = feedEntry.canonicalURL
            identified.author = feedEntry.author ?? identified.author
            feedEntry.fillEpisodeIdentity(of: &identified, showTitle: subscription?.source.title)
            try store.saveItem(identified)
            if item.media?.url == result.selectedCandidate?.audioURL,
               try store.loadListeningMap(itemId: item.id) == nil,
               let summary = feedEntry.summary,
               let chapters = TimestampedDescriptionChapterParser.parse(summary) {
                _ = try engine.attachPublisherChapters(itemId: item.id, collection: chapters)
            }
            diagnostics["sourceEntryImport:\(feedEntry.id)"] = "item:\(item.id),subscription:\(feedEntry.subscriptionId),title:feed_entry"
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        if item.media?.url == result.selectedCandidate?.audioURL, item.transcriptId == nil {
            scheduleSourceTranscriptImportIfAvailable(
                result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                itemId: item.id
            )
        }
        return item.id
    }

    static func isRemotePDFHandoff(_ handoff: SourceLinkHandoff) -> Bool { handoff.isRemotePDF }

    private func importLocalSharedPDFInBackground(url: URL) async throws {
        #if canImport(PDFKit)
        let extracted = try await Task.detached(priority: .userInitiated) {
            try NativePDFDocumentExtractor.extractStructured(from: url)
        }.value
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = extracted.title ?? (fileTitle.isEmpty ? "Shared PDF" : fileTitle)
        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "shared.pdf"
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(
                url: "shared-file://share-sheet/\(encodedName)",
                title: title
            ),
            text: extracted.document.text,
            contentFormat: .plainText,
            documentStructure: extracted.documentStructure
        )
        try importBrowserTextInBackground(handoff, structuredDocument: extracted.document)
        diagnostics["lastSharedPDFImport"] = url.lastPathComponent
        markOnboardingSteps([.addedOwnSource, .addedFromSafari])
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    @discardableResult func importBrowserTextInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws -> String {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine else {
            throw SessionKitError.persistenceFailed("Browser text importer is unavailable.")
        }
        let item = try engine.importBrowserTextInBackground(Self.sanitizedBrowserTextHandoff(handoff), structuredDocument: structuredDocument)
        libraryItems = try loadLibraryRows(store: store)
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
        diagnostics["lastBackgroundBrowserTextImport"] = item.id
        if let structure = item.documentStructure {
            recordPDFExtractionDiagnostics(structure)
        }
        markOnboardingSteps(onboardingSteps(for: handoff))
        return item.id
    }

    private func recordPDFExtractionDiagnostics(_ structure: PDFDocumentStructure) {
        diagnostics["lastPDFExtractionEngine"] = structure.extractionEngine.rawValue
        diagnostics["lastPDFAnalysisStatus"] = structure.analysisStatus.rawValue
        diagnostics["lastPDFPageCount"] = "\(structure.pageCount)"
        diagnostics["lastPDFAnalyzedPageCount"] = "\(structure.analyzedPageCount)"
        diagnostics["lastPDFTableCount"] = "\(structure.tables.count)"
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
                    modifiedAt: entry.modifiedAt,
                    modifiedAtDescription: formatter.localizedString(for: entry.modifiedAt, relativeTo: Date())
                )
            }
            self.quickAccessFolderName = folderURL.lastPathComponent
            self.diagnostics["quickAccessFolder"] = folderURL.lastPathComponent
            self.diagnostics["quickAccessRecentFiles"] = "\(self.quickAccessRecentFiles.count)"
        }
    }

    nonisolated static func scanQuickAccessFolder(_ folderURL: URL) -> QuickAccessFolderScan {
        QuickAccessFolderScanner.scan(folderURL)
    }

    func importQuickAccessFile(_ file: QuickAccessFile, openWhenFinished: Bool = false) {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        let fileURL = folderURL.appending(path: file.relativePath)
        beginObsidianMarkdownImport(
            urls: [fileURL],
            securityScopedURLs: [folderURL],
            refreshQuickFolderWhenFinished: true,
            openImportedItemWhenFinished: openWhenFinished,
            quickAccessFileToDismiss: file
        )
    }

    func refreshQuickAddFeed(force: Bool = true) {
        refreshQuickAccessFolder()
        refreshFollowedSources(force: force)
    }

    @discardableResult
    func importBrowserText(_ handoff: BrowserTextHandoff) -> Bool {
        importBrowserTextItem(handoff) != nil
    }

    /// `importBrowserText`, returning the new item's id, or nil when the import failed.
    private func importBrowserTextItem(_ handoff: BrowserTextHandoff) -> String? {
        do {
            if hasActiveSession {
                let itemId = try importBrowserTextInBackground(handoff)
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

    /// A shared or pasted Substack post keeps its voiceover beside the article (#810). Runs after the import,
    /// so a slow page never holds up the share.
    private func rememberSharedLinkVoiceover(sharedURL: URL, article: BrowserTextHandoff, itemId: String, fetched: FetchedPageMemo) {
        guard let store = try? requireStore() else { return }
        let transcriber = sourceTranscriptionClient
        let voiceover = sharedLinkVoiceover
        Task { [weak self] in
            await voiceover.remember(sharedURL: sharedURL, article: article, itemId: itemId, fetched: fetched, store: store, transcriber: transcriber) {
                self?.diagnostics["sharedLinkVoiceover"] = $0
            }
        }
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
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
        ttsVoiceSelection.supertonicVoice != nil
            && (try? store?.loadItem(id: itemId))?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func playPause() {
        if playingImportedCommentary != nil {
            // Pause while it sounds or loads; Play (resume, or Retry after a failure) otherwise (#941).
            setImportedCommentaryPaused(importedCommentaryPhase.showsPause)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice {
            conductor.setVoicePaused(!conductor.isVoicePaused)
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
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(true)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice, !conductor.isVoicePaused {
            conductor.setVoicePaused(true)
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
            refreshSelectedItem()
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
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(false)
            return
        }
        if let conductor = marginMomentConductor, conductor.isVoicePaused {
            conductor.setVoicePaused(false)
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

    func prepareEpisodeMap(itemId: String? = nil, policy: PreparationJobPolicy = .explicit) {
        let requestedItemId = itemId ?? activeItemId
        guard episodeMapPreparationTask == nil else {
            reportWarning("An episode map is already being prepared.")
            return
        }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: requestedItemId)
            guard item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream else {
                throw SessionKitError.invalidCommandForState("episode_map_requires_native_audio")
            }
            let existingJob = (try store.loadEpisodeMapPreparationJobs()).first {
                $0.itemId == requestedItemId && !$0.isCancelled
            }
            var job = existingJob ?? EpisodeMapPreparationJob(
                id: "episode-map-job-\(safePodcastEvidenceComponent(requestedItemId))",
                itemId: requestedItemId,
                policy: policy
            )
            job.policy = policy
            if existingJob == nil {
                job.stage = .verifySource
                job.nextUnitIndex = 0
            }
            job.lastFailureCode = nil
            try store.saveEpisodeMapPreparationJob(job)

            guard let localURL = podcastDownloadCoordinator?.validatedLocalURL(for: requestedItemId)
                ?? item.media?.url.flatMap(URL.init(string:)).flatMap({ $0.isFileURL ? $0 : nil }) else {
                pendingMapGenerationItemId = requestedItemId
                episodeMapPreparationStatus = "Waiting for download"
                diagnostics["episodeMapPreparation:\(requestedItemId)"] = "waiting_for_local_audio"
                if podcastDownloadCoordinator?.downloadNow(itemId: requestedItemId) != true,
                   let remote = item.media?.url.flatMap(URL.init(string:)) {
                    podcastDownloadCoordinator?.register(
                        itemId: requestedItemId,
                        remoteURL: remote,
                        userInitiated: policy == .explicit
                    )
                }
                if policy == .explicit {
                    reportSuccess("Downloading the episode. Its private Listening Map will continue automatically.")
                }
                return
            }
            runEpisodeMapPreparation(item: item, localURL: localURL, job: job)
        } catch {
            episodeMapPreparationStatus = "Failed"
            reportFailure(error, context: "Episode map preparation failed")
        }
    }

    private func runEpisodeMapPreparation(
        item: Item,
        localURL: URL,
        job initialJob: EpisodeMapPreparationJob
    ) {
        episodeMapPreparationStatus = "Preparing"
        diagnostics["episodeMapPreparation:\(item.id)"] = "started"
        episodeMapPreparationItemId = item.id
        episodeMapPreparationTask = Task { [weak self] in
            guard let self else { return }
            var job = initialJob
            defer {
                self.episodeMapPreparationTask = nil
                self.episodeMapPreparationItemId = nil
            }
            do {
                let store = try self.requireStore()
                job.stage = .generateFingerprintSpine
                try store.saveEpisodeMapPreparationJob(job)
                let mapDirectory = try self.episodeMapDirectory(itemId: item.id)
                try FileManager.default.createDirectory(at: mapDirectory, withIntermediateDirectories: true)
                let digest = try await Task.detached(priority: .utility) {
                    try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                }.value
                try Task.checkCancellation()
                let durationMs: Int
                if let declaredDurationMs = item.media?.durationMs {
                    durationMs = declaredDurationMs
                } else if let duration = try? await AVURLAsset(url: localURL).load(.duration) {
                    durationMs = Int((CMTimeGetSeconds(duration) * 1_000).rounded())
                } else {
                    durationMs = 0
                }
                var generatedLandmarks: [EpisodeFingerprintLandmark] = []
                var gridIndex = 0
                var startMs = SparseFingerprintSchedule.initialMediaTimeMs
                while gridIndex < job.nextUnitIndex,
                      startMs + PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs <= durationMs {
                    let assetID = "episode-signature-\(self.safePodcastEvidenceComponent(item.id))-downloaded-\(gridIndex)"
                    let existingURL = mapDirectory.appending(path: "\(assetID).shazamsignature")
                    guard FileManager.default.fileExists(atPath: existingURL.path) else {
                        job.nextUnitIndex = gridIndex
                        break
                    }
                    generatedLandmarks.append(EpisodeFingerprintLandmark(
                        id: "downloaded-landmark-\(gridIndex)",
                        order: gridIndex,
                        sourceMediaStartMs: startMs,
                        sourceMediaEndMs: startMs + SparseFingerprintSchedule.targetDurationMs,
                        anchorMediaTimeMs: startMs,
                        continuityEpoch: 0,
                        trigger: .downloadedPreparation,
                        provenance: .downloadedSourceReference,
                        signatureAssetId: assetID
                    ))
                    gridIndex += 1
                    startMs += SparseFingerprintSchedule.periodicIntervalMs
                }
                while startMs + PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs <= durationMs {
                    try Task.checkCancellation()
                    let assetID = "episode-signature-\(self.safePodcastEvidenceComponent(item.id))-downloaded-\(gridIndex)"
                    let ledger = try self.requireOfflineLedger(store: store, rootDirectory: try self.applicationSupportDirectory())
                    let reservation = try await ledger.reserve(
                        ownerId: "episode-fingerprint-\(item.id)-\(gridIndex)",
                        byteCount: 2 * 1_024 * 1_024
                    )
                    let generated: GeneratedPodcastAnchorEvidence
                    do {
                        generated = try await PodcastAnchorEvidenceGenerator.generateLandmark(
                            sourceURL: localURL,
                            sourceStartMs: startMs,
                            outputDirectory: mapDirectory,
                            id: assetID
                        )
                    } catch {
                        try? await ledger.release(reservationId: reservation.id)
                        throw error
                    }
                    generatedLandmarks.append(EpisodeFingerprintLandmark(
                        id: "downloaded-landmark-\(gridIndex)",
                        order: gridIndex,
                        sourceMediaStartMs: startMs,
                        sourceMediaEndMs: startMs + generated.durationMs,
                        anchorMediaTimeMs: startMs,
                        continuityEpoch: 0,
                        trigger: .downloadedPreparation,
                        provenance: .downloadedSourceReference,
                        signatureAssetId: assetID
                    ))
                    try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                        id: assetID,
                        itemId: item.id,
                        category: .fingerprintMap,
                        relativePath: "SpokenMargins/EpisodeMaps/\(self.safePodcastEvidenceComponent(item.id))/\(assetID).shazamsignature",
                        byteCount: Int64((try? Data(contentsOf: generated.fileURL).count) ?? 0),
                        isReproducible: true,
                        protections: [.activeEpisodeMapPreparation]
                    ))
                    gridIndex += 1
                    startMs += SparseFingerprintSchedule.periodicIntervalMs
                    job.nextUnitIndex = gridIndex
                    try store.saveEpisodeMapPreparationJob(job)
                    if job.policy == .whileCharging {
                        self.episodeMapPreparationStatus = "Fingerprinting paused at landmark \(gridIndex)"
                        self.diagnostics["episodeMapPreparation:\(item.id)"] = "checkpoint:fingerprint_landmark=\(gridIndex)"
                        return
                    }
                }

                job.stage = .transcribe
                try store.saveEpisodeMapPreparationJob(job)
                self.episodeMapPreparationStatus = "Transcribing on device"
                let supportDirectory = try self.applicationSupportDirectory()
                var timeline: TranscriptTimeline
                if let relativePath = job.transientTranscriptRelativePath,
                   let cached = try? Data(contentsOf: supportDirectory.appending(path: relativePath)),
                   let decoded = try? JSONDecoder().decode(TranscriptTimeline.self, from: cached) {
                    timeline = decoded
                } else {
                    timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                        url: localURL,
                        itemId: item.id,
                        durationMs: durationMs
                    )
                    let transcriptData = try JSONEncoder().encode(timeline)
                    let safeItemID = self.safePodcastEvidenceComponent(item.id)
                    let relativePath = "SpokenMargins/EpisodeMaps/\(safeItemID)/Transient/timeline.json"
                    let transcriptURL = supportDirectory.appending(path: relativePath)
                    try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let ledger = self.requireOfflineLedger(store: store, rootDirectory: supportDirectory)
                    let reservation = try await ledger.reserve(
                        ownerId: "episode-transcript-\(item.id)",
                        byteCount: Int64(transcriptData.count)
                    )
                    do {
                        try transcriptData.write(to: transcriptURL, options: .atomic)
                        try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                            id: "episode-transcript-\(safeItemID)",
                            itemId: item.id,
                            category: .transientEpisodeTranscript,
                            relativePath: relativePath,
                            byteCount: Int64(transcriptData.count),
                            isReproducible: true,
                            protections: [.activeEpisodeMapPreparation]
                        ))
                    } catch {
                        try? await ledger.release(reservationId: reservation.id)
                        try? FileManager.default.removeItem(at: transcriptURL)
                        throw error
                    }
                    job.transientTranscriptRelativePath = relativePath
                    try store.saveEpisodeMapPreparationJob(job)
                }
                try self.purgeSourceTranscriptionAudioCaches(itemId: item.id)
                if let publisherChapters = try store.loadTranscriptTimeline(itemId: item.id)?.timeline.chapters,
                   !publisherChapters.isEmpty {
                    timeline.chapters = publisherChapters
                }
                CommunityMapUploadService.shared.episodeTranscribed(itemId: item.id, timeline: timeline, store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 }

                job.stage = .generatePhraseSketch
                try store.saveEpisodeMapPreparationJob(job)
                let sketch = TranscriptPhraseSketchBuilder.makeArtifact(
                    id: "episode-sketch-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    timeline: timeline
                )

                let existingPlaybackLandmarks = try store.loadEditionFingerprintSpine(itemId: item.id)?.landmarks
                    .filter { $0.provenance == .observedDecodedPlayback } ?? []
                let allLandmarks = (existingPlaybackLandmarks + generatedLandmarks)
                    .sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }
                    .enumerated().map { index, landmark in
                        let sketchWindow = sketch.windows.first {
                            landmark.anchorMediaTimeMs >= $0.sourceStartMs
                                && landmark.anchorMediaTimeMs < $0.sourceEndMs
                        }
                        return EpisodeFingerprintLandmark(
                            id: landmark.id,
                            order: index,
                            sourceMediaStartMs: landmark.sourceMediaStartMs,
                            sourceMediaEndMs: landmark.sourceMediaEndMs,
                            anchorMediaTimeMs: landmark.anchorMediaTimeMs,
                            continuityEpoch: landmark.continuityEpoch,
                            trigger: landmark.trigger,
                            provenance: landmark.provenance,
                            signatureAssetId: landmark.signatureAssetId,
                            transcriptSketchWindowId: sketchWindow?.id,
                            generatorVersion: landmark.generatorVersion
                        )
                    }
                let spine = EditionFingerprintSpineArtifact(
                    id: "episode-spine-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    canonicalURL: item.externalReference ?? item.media?.url,
                    producingEditionDurationMs: durationMs,
                    producingEditionSHA256: digest,
                    landmarks: allLandmarks
                )

                job.stage = .segmentScenes
                try store.saveEpisodeMapPreparationJob(job)
                let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)
                var scenes: [PortableListeningMapScene] = []
                job.stage = .generateSummaries
                try store.saveEpisodeMapPreparationJob(job)
                for draft in drafts {
                    try Task.checkCancellation()
                    let text = timeline.segments
                        .filter { $0.endMs > draft.startMs && $0.startMs < draft.endMs }
                        .map(\.text)
                        .joined(separator: " ")
                    var label: ListeningMapSummaryValidator.SceneLabel?
                    if self.localFoundationModelClient.availability().isAvailable, !text.isEmpty {
                        for _ in 0..<2 where label == nil {
                            if let candidate = try? await self.localFoundationModelClient.labelListeningMapChapter(
                                text: text,
                                chapterNumber: draft.order + 1
                            ) {
                                label = try? ListeningMapSummaryValidator.validate(candidate, sourceText: text)
                            }
                        }
                    }
                    let nearestEvidence = allLandmarks.min {
                        abs($0.anchorMediaTimeMs - draft.startMs) < abs($1.anchorMediaTimeMs - draft.startMs)
                    }?.signatureAssetId
                    let machineEvidence = nearestEvidence.map { [$0] } ?? []
                    let eligibility = label?.eligibility ?? .unknown
                    scenes.append(PortableListeningMapScene(
                        id: draft.id,
                        order: draft.order,
                        title: label?.title ?? draft.publisherTitle,
                        summaryText: ListeningMapSummaryValidator.storedSummary(for: label).text,
                        summaryAssetId: nil,
                        summaryProvenance: ListeningMapSummaryValidator.storedSummary(for: label).provenance,
                        eligibility: eligibility,
                        eligibilityReason: label?.eligibilityReason,
                        startAnchor: PortableAnchorEvidence(
                            anchorType: .transcript,
                            mediaTimeMs: draft.startMs,
                            transcriptSegmentId: draft.startTranscriptSegmentId,
                            chapterTitle: label?.title ?? draft.publisherTitle,
                            machineEvidenceAssetIds: machineEvidence
                        ),
                        endAnchor: PortableAnchorEvidence(
                            anchorType: .transcript,
                            mediaTimeMs: draft.endMs,
                            transcriptSegmentId: draft.endTranscriptSegmentId,
                            chapterTitle: label?.title ?? draft.publisherTitle,
                            machineEvidenceAssetIds: machineEvidence
                        )
                    ))
                }
                let proposal = PortableListeningMapProposalArtifact(
                    id: "episode-map-proposal-\(self.safePodcastEvidenceComponent(item.id))",
                    createdAt: Date(),
                    generator: self.localFoundationModelClient.availability().isAvailable
                        ? "on-device-scene-map.v1"
                        : "deterministic-scene-boundaries.v1",
                    scenes: scenes
                )

                job.stage = .renderBridges
                try store.saveEpisodeMapPreparationJob(job)
                for scene in scenes where scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                    try Task.checkCancellation()
                    _ = try await self.prepareSummaryBridgeAsset(
                        itemId: item.id,
                        proposalId: proposal.id,
                        scene: scene,
                        store: store
                    )
                }

                job.stage = .commit
                try store.saveEpisodeMapPreparationJob(job)
                try store.saveEditionFingerprintSpine(spine)
                try store.saveTranscriptPhraseSketch(sketch)
                try store.savePortableListeningMapProposal(proposal, itemId: item.id)
                let identityMatches = allLandmarks.map { landmark in
                    FingerprintLandmarkMatch(
                        id: "exact-\(landmark.id)",
                        landmarkId: landmark.id,
                        sourceMediaTimeMs: landmark.anchorMediaTimeMs,
                        recipientMediaTimeMs: landmark.anchorMediaTimeMs,
                        acousticConfidence: 1,
                        transcriptCorroborated: true,
                        isUniqueWithinEpisode: true
                    )
                }
                try store.saveResolvedListeningMapProjection(EpisodeFingerprintAlignment.makeProjection(
                    id: "episode-projection-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    proposalId: proposal.id,
                    recipientEditionSHA256: digest,
                    matches: identityMatches,
                    exactEdition: true
                ))
                for asset in try store.loadOwnedOfflineAssets() where
                    asset.itemId == item.id && asset.category == .fingerprintMap {
                    try store.updateOwnedOfflineAsset(id: asset.id) { $0.protections.remove(.activeEpisodeMapPreparation) }
                }
                try self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                job.stage = .completed
                try store.saveEpisodeMapPreparationJob(job)
                try store.deleteEpisodeMapPreparationJob(id: job.id)
                self.episodeMapPreparationStatus = scenes.contains(where: { $0.summaryText != nil })
                    ? "Ready with scene summaries"
                    : "Fingerprint map ready; scene summaries unavailable"
                self.diagnostics["episodeMapPreparation:\(item.id)"] =
                    "complete:landmarks=\(allLandmarks.count):scenes=\(scenes.count):transcript_deleted"
                if item.id == self.activeItemId {
                    self.refreshSelectedItem()
                    self.updateSkimAvailability()
                    self.reportConfirmation(self.episodeMapPreparationStatus)
                }
            } catch is CancellationError {
                job.isCancelled = true
                job.lastFailureCode = "cancelled"
                try? self.store?.saveEpisodeMapPreparationJob(job)
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.episodeMapPreparationStatus = "Cancelled"
            } catch {
                job.lastFailureCode = String(describing: error)
                try? self.store?.saveEpisodeMapPreparationJob(job)
                self.episodeMapPreparationStatus = "Failed"
                self.diagnostics["episodeMapPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
                if item.id == self.activeItemId { self.reportFailure(error, context: "Episode map preparation failed", itemId: item.id) }
            }
        }
    }

    private func episodeMapDirectory(itemId: String) throws -> URL {
        try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(itemId), directoryHint: .isDirectory)
    }

    private func currentSummaryBridgeVoiceKey() -> String {
        let systemIdentifier = ttsVoiceSelection == .system ? speechVoiceIdentifier : ""
        return safePodcastEvidenceComponent("\(ttsVoiceSelection.rawValue)-\(systemIdentifier)-\(SummaryBridgeRatePolicy.cacheVersion)")
    }

    /// Why a friend's shared map couldn't be placed on this item's copy, as stored on its packets (#481).
    func sharedListeningMapRefusal(itemId: String) -> String? {
        guard let store, let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              let hasMap = try? Self.listenerHasListeningMap(itemId: itemId, store: store) else { return nil }
        return SharedListeningMapPlacement.storedRefusalReason(layers: layers, listenerHasMap: hasMap)
    }

    /// The listener's own map or the publisher's chapters, which a friend's map never replaces.
    private static func listenerHasListeningMap(itemId: String, store: SQLiteSessionStore) throws -> Bool {
        try !store.loadPortableListeningMapProposals(itemId: itemId).isEmpty
            || store.loadTranscriptTimeline(itemId: itemId)?.timeline.chapters.isEmpty == false
    }

    private func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String? = nil) -> String {
        let voiceKey = suppliedAssetId.map { "supplied-\(safePodcastEvidenceComponent($0))" } ?? currentSummaryBridgeVoiceKey()
        return "summary-bridge-\(safePodcastEvidenceComponent(itemId))-\(safePodcastEvidenceComponent(proposalId))-\(safePodcastEvidenceComponent(sceneId))-\(voiceKey)"
    }

    private func prepareSummaryBridgeAsset(
        itemId: String,
        proposalId: String,
        scene: PortableListeningMapScene,
        store: SQLiteSessionStore
    ) async throws -> OwnedOfflineAsset? {
        guard let summary = scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: scene.summaryAssetId)
        if let existing = try store.loadOwnedOfflineAssets().first(where: {
            $0.id == assetID && $0.integrity == .valid
        }), resolvedApplicationSupportAssetURL(for: existing.relativePath) != nil { return existing }
        // An authored voice is part of the imported experience, not a request
        // to silently synthesize replacement speech in the current system voice.
        guard scene.summaryAssetId == nil else { return nil }
        let directory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "SummaryBridges", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = try requireOfflineLedger(store: store, rootDirectory: try applicationSupportDirectory())
        let reservation = try await ledger.reserve(
            ownerId: "summary-bridge-\(assetID)",
            byteCount: 64 * 1_024 * 1_024
        )
        do {
            let sourceURL: URL
            if let voice = ttsVoiceSelection.supertonicVoice {
                let renderer = try makeSupertonicRenderer()
                let result = try await renderer.render(
                    text: summary,
                    voice: voice,
                    language: "en",
                    speed: SummaryBridgeRatePolicy.synthesisSpeed,
                    synthesisSteps: 8
                )
                sourceURL = result.audioURL
            } else {
                let title = scene.title ?? "Scene summary"
                // An injected preparation job renders in place of the system voice, as it does for text items.
                let prepared: PreparedTextAudio?
                if let prewarm = preparedTextAudioPrewarmHandler {
                    prepared = try await prewarm(
                        assetID, title, summary, directory, speechVoiceIdentifier, SummaryBridgeRatePolicy.systemSynthesisRate
                    ).get()
                } else {
                    prepared = try SystemTextAudioPreparationClient(
                        outputDirectory: directory,
                        voiceIdentifier: speechVoiceIdentifier,
                        speechRate: SummaryBridgeRatePolicy.systemSynthesisRate,
                        allowsSynchronousRendering: true
                    ).prepareTextAudio(itemId: assetID, title: title, text: summary)
                }
                guard let prepared, let value = prepared.media.url, let url = URL(string: value) else {
                    try? await ledger.release(reservationId: reservation.id)
                    return nil
                }
                sourceURL = url
            }
            let destination = directory.appending(path: "\(assetID).\(sourceURL.pathExtension.isEmpty ? "caf" : sourceURL.pathExtension)")
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
            let bytes = (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let asset = OwnedOfflineAsset(
                id: assetID,
                itemId: itemId,
                category: .summaryBridge,
                relativePath: "SpokenMargins/EpisodeMaps/\(safePodcastEvidenceComponent(itemId))/SummaryBridges/\(destination.lastPathComponent)",
                byteCount: bytes,
                isReproducible: true
            )
            try await ledger.commit(reservationId: reservation.id, asset: asset)
            return asset
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    @Published private(set) var skimForwardDestinationMs: Int?
    @Published private(set) var skimBackwardDestinationMs: Int?
    var skimForwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimForwardDestinationMs, backward: false) }
    var skimBackwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimBackwardDestinationMs, backward: true) }
    private var skimResourceContext: SkimResourceContext?
    #if DEBUG
    private(set) var skimResourceLoadCount = 0
    var skimAudioTransportRate: Float? { skimBridgePlayer?.rate }
    func refreshSkimAvailabilityForTesting() { updateSkimAvailability() }
    #endif

    private func updateSkimAvailability(refreshResources: Bool = true) {
        if refreshResources { skimResourceContext = nil }
        guard !isUpdatingSkimAvailability else { return }
        let effectiveTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? snapshot.currentMediaTimeMs
        let forward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) }
        let backward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .backward, at: $0) }
        let forwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        let destinationsChanged = skimForwardDestinationMs != forwardTime || skimBackwardDestinationMs != backwardTime
        if destinationsChanged { (skimForwardDestinationMs, skimBackwardDestinationMs) = (forwardTime, backwardTime) }
        let canForward = forwardTime != nil, canBackward = backwardTime != nil
        // A map can move where Skim lands with no availability flip (paused, say); the Lock Screen still needs it (#115).
        guard snapshot.canSkimForward != canForward || snapshot.canSkimBackward != canBackward else { if destinationsChanged { updateGate2CompactState() }; return }
        isUpdatingSkimAvailability = true
        snapshot.canSkimForward = canForward
        snapshot.canSkimBackward = canBackward
        isUpdatingSkimAvailability = false
    }

    func resolvedSkimPlaybackPlan(
        direction: SkimDirection,
        at recipientMediaTimeMs: Int
    ) -> ResolvedSkimPlaybackPlan? {
        guard isMediaPlaybackSnapshot, !snapshot.isRecording, let store else { return nil }
        if skimResourceContext?.itemId != activeItemId {
            #if DEBUG
            skimResourceLoadCount += 1
            #endif
            let projection = try? store.loadResolvedListeningMapProjection(itemId: activeItemId)
            skimResourceContext = SkimResourceContext(
                itemId: activeItemId,
                projection: projection,
                proposal: SharedListeningMapPlacement.proposal(
                    for: projection, committed: (try? store.loadPortableListeningMapProposals(itemId: activeItemId)) ?? [],
                    layers: (try? store.loadImportedCommentaryLayers(itemId: activeItemId)) ?? []),
                assets: (try? store.loadOwnedOfflineAssets()) ?? []
            )
        }
        guard let resources = skimResourceContext, let projection = resources.projection else { return nil }
        guard let proposal = resources.proposal else { return nil }
        guard let plan = SceneStarts(scenes: proposal.scenes, projection: projection).skimPlan(
            direction: direction, at: recipientMediaTimeMs,
            durationMs: snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs
        ) else { return nil }
        let summaryScene = plan.summaryScene
        let assetID = summaryBridgeAssetID(
            itemId: activeItemId,
            proposalId: SharedListeningMapPlacement.isSharedProjection(id: projection.id) ? projection.id : proposal.id,
            sceneId: summaryScene.id,
            suppliedAssetId: summaryScene.summaryAssetId
        )
        guard let asset = resources.assets.first(where: {
            $0.id == assetID && $0.category == .summaryBridge && $0.integrity == .valid
        }), let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) else {
            return nil
        }
        return ResolvedSkimPlaybackPlan(
            direction: direction,
            itemId: activeItemId,
            originMediaTimeMs: recipientMediaTimeMs,
            summarySceneId: summaryScene.id,
            destinationSceneId: plan.destinationSceneId,
            destinationMediaTimeMs: plan.destinationMediaTimeMs,
            summaryAssetId: assetID,
            summaryAudioURL: url
        )
    }

    func skimForward() {
        performSkim(direction: .forward)
    }

    func skimBackward() {
        performSkim(direction: .backward)
    }

    private func performSkim(direction: SkimDirection) {
        if snapshot.skimBridgeState != nil {
            // A second tap exits the current bridge at its destination. Do not
            // resolve another summary against the asynchronous source seek.
            completeSkimBridge()
            return
        }
        let effectiveTime = snapshot.currentMediaTimeMs ?? 0
        guard let plan = resolvedSkimPlaybackPlan(direction: direction, at: effectiveTime) else {
            reportWarning("Skim is unavailable until a verified scene summary is ready.")
            return
        }
        startSkimBridge(plan)
    }

    func startSkimBridge(_ plan: ResolvedSkimPlaybackPlan, continueAfterSummary: Bool = false) {
        #if canImport(AVFoundation)
        guard let engine else { return }
        let wasPlaying = snapshot.status.isPlaybackActive || continueAfterSummary
        do {
            snapshot = try engine.pause()
            var state = SkimBridgeState(
                direction: plan.direction,
                itemId: plan.itemId,
                originMediaTimeMs: plan.originMediaTimeMs,
                summarySceneId: plan.summarySceneId,
                destinationSceneId: plan.destinationSceneId,
                destinationMediaTimeMs: plan.destinationMediaTimeMs,
                summaryAssetId: plan.summaryAssetId,
                wasSourcePlaying: wasPlaying,
                status: .preparing
            )
            snapshot.skimBridgeState = state
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: true)
            let player = AVPlayer(url: plan.summaryAudioURL)
            skimBridgePlayer = player
            state.status = .playing
            snapshot.skimBridgeState = state
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            skimBridgeTask?.cancel()
            skimBridgeTask = Task { @MainActor [weak self, weak player] in
                while !Task.isCancelled {
                    guard let self, let player, let item = player.currentItem else { return }
                    if item.status == .failed {
                        self.cancelSkimBridge(restoringOrigin: true, resumeSource: false)
                        self.reportWarning("The scene summary could not be played. Your original position was restored.")
                        return
                    }
                    let duration = CMTimeGetSeconds(item.duration)
                    let current = CMTimeGetSeconds(player.currentTime())
                    if duration.isFinite, duration > 0, current >= duration - 0.08 {
                        self.completeSkimBridge()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            reportSuccess(plan.direction == .forward ? "Skimming forward." : "Skimming backward.")
        } catch {
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: false)
            reportFailure(error, context: "Skim failed")
        }
        #else
        reportWarning("Skim audio is unavailable on this device.")
        #endif
    }

    func completeSkimBridge() {
        guard var bridge = snapshot.skimBridgeState, let engine else { return }
        bridge.status = .completing
        snapshot.skimBridgeState = bridge
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        do {
            snapshot.skimBridgeState = nil
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: bridge.destinationMediaTimeMs)
            if bridge.destinationSceneId == nil {
                snapshot = try engine.pause()
                reportConfirmation("Finished the final scene summary.")
            } else if bridge.wasSourcePlaying {
                snapshot = try engine.resumePlayback()
            } else {
                snapshot = try engine.pause()
            }
            refreshSelectedItem()
        } catch {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
            reportFailure(error, context: "Completing Skim failed")
        }
    }

    private func setSkimBridgePaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard var bridge = snapshot.skimBridgeState, let player = skimBridgePlayer else { return }
        if paused {
            player.pause()
            bridge.status = .paused
        } else {
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            bridge.status = .playing
        }
        snapshot.skimBridgeState = bridge
        #endif
    }

    func returnFromSkim() {
        cancelSkimBridge(restoringOrigin: true, resumeSource: true)
    }

    private func cancelSkimBridge(restoringOrigin: Bool, resumeSource: Bool) {
        guard var bridge = snapshot.skimBridgeState else { return }
        bridge.status = .cancelled
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        snapshot.skimBridgeState = nil
        guard restoringOrigin, let engine else { return }
        snapshot = (try? seekOrStageMedia(engine, toMediaTimeMs: bridge.originMediaTimeMs)) ?? snapshot
        if resumeSource && bridge.wasSourcePlaying {
            snapshot = (try? engine.resumePlayback()) ?? snapshot
        } else {
            snapshot = (try? engine.pause()) ?? snapshot
        }
    }

    private func restoreSkimOriginBeforeCanonicalTransport() {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        guard let bridge = snapshot.skimBridgeState else { return }
        cancelSkimBridge(restoringOrigin: true, resumeSource: bridge.wasSourcePlaying)
    }

    private func protectSummaryBridgeAsset(_ assetID: String, protected: Bool) {
        _ = try? store?.updateOwnedOfflineAsset(id: assetID) { asset in
            if protected {
                asset.protections.insert(.activeSummaryBridge)
            } else {
                asset.protections.remove(.activeSummaryBridge)
            }
        }
    }

    private func purgeTransientEpisodeTranscriptionCaches(itemId: String) throws {
        try purgeSourceTranscriptionAudioCaches(itemId: itemId)
        let transientDirectory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "Transient", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: transientDirectory.path) {
            try FileManager.default.removeItem(at: transientDirectory)
        }
        if let store {
            for asset in try store.loadOwnedOfflineAssets() where
                asset.itemId == itemId && asset.category == .transientEpisodeTranscript {
                try store.deleteOwnedOfflineAsset(id: asset.id)
            }
        }
    }

    private func purgeSourceTranscriptionAudioCaches(itemId: String) throws {
        try SourceTranscriptionCaches.purge(itemId: itemId)
    }

    private func submitAutomaticEpisodeMapPreparationIfNeeded() {
        guard automaticEpisodeMapPreparationPolicy == .whileCharging,
              let store else { return }
        let candidates = libraryItems.compactMap { row -> Item? in
            guard (try? store.loadEditionFingerprintSpine(itemId: row.id)) == nil,
                  let item = try? store.loadItem(id: row.id),
                  item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream,
                  podcastDownloadCoordinator?.validatedLocalURL(for: row.id) != nil else { return nil }
            return item
        }
        for item in candidates {
            let id = "episode-map-job-\(safePodcastEvidenceComponent(item.id))"
            if let existing = try? store.loadEpisodeMapPreparationJobs().first(where: { $0.id == id && !$0.isCancelled }) {
                _ = existing
                continue
            }
            try? store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(
                id: id,
                itemId: item.id,
                policy: .whileCharging
            ))
        }
        #if canImport(BackgroundTasks) && canImport(UIKit)
        AudioPreparationBackgroundController.shared.submitIfEnabled(!candidates.isEmpty)
        #endif
    }

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

    var nextPlaybackChapter: Chapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.itemTextTTS.rawValue,
              let index = selectedItem.chapters.firstIndex(where: { isCurrentTimelineChapter($0) }),
              selectedItem.chapters.indices.contains(index + 1) else { return nil }
        return selectedItem.chapters[index + 1]
    }

    var nextPlaybackMediaChapter: MediaTimelineChapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let position = snapshot.currentMediaTimeMs else { return nil }
        let chapters = selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters
        return chapters.sorted { $0.startMs < $1.startMs }.first { $0.startMs > position }
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

    func jumpToMediaChapter(_ chapter: MediaTimelineChapter, fromTimeline: Bool = false) {
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

    func jumpToListeningMapScene(_ scene: MediaTimelineChapter, fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.jumpToChapter(scene.id, fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: scene.startMs)
            if !snapshot.status.isPlaybackActive {
                snapshot = try engine.resumePlayback()
            }
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(scene.title).")
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
        try prepareSourceMediaPlayback(itemId: activeItemId)
        if let session = engine.currentSession, session.itemId == activeItemId,
           session.status != "finished", session.phase != .finished, session.completionPercent < 100 {
            return false
        }
        resetMixWithOtherAudioForNewSession()
        if engine.currentSession != nil {
            snapshot = try endEngineSession(engine)
        }
        let started = try engine.startSession(itemId: activeItemId)
        snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
        return true
    }

    var activePlaybackItemId: String? {
        snapshot.sessionId == nil ? nil : snapshot.itemId
    }

    var recordingNavigationIsLocked: Bool {
        isRequestingRecordingPermission || snapshot.isRecording || writtenMarginDraft != nil
    }

    @discardableResult
    private func rejectNavigationOrSessionMutationWhileRecording(_ operation: String) -> Bool {
        guard recordingNavigationIsLocked else { return false }
        diagnostics["recordingNavigationGuard"] = "blocked_\(operation)"
        statusMessage = "Finish or cancel this Margin before leaving its listening position."
        return true
    }

    func openHome() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_home") else { return }
        screen = .home
        // Reflect the known source position without loading every saved item.
        if let index = libraryItems.firstIndex(where: { $0.id == snapshot.itemId }), snapshot.sessionId != nil {
            libraryItems[index].hasContinuationSession = true
            libraryItems[index].continuationProgressPercent = snapshot.sourceProgressPercent
        }
        navigationRefreshTask?.cancel()
        guard let store else { return }
        let revision = libraryPresentationRevision
        let read = navigationLibraryRead
        navigationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let data = try await read(store)
                try Task.checkCancellation()
                guard let self, self.screen == .home,
                      self.libraryPresentationRevision == revision else { return }
                let rows = self.libraryRows(from: data)
                if self.libraryItems != rows { self.libraryItems = rows }
                self.recentlyDeletedItems = data.items.filter { $0.deletedAt != nil }
                    .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }.map {
                    LibraryItemRow(id: $0.id, title: $0.title, status: "Recently deleted", canDelete: true)
                }
            } catch is CancellationError {
            } catch {
                self?.diagnostics["homeLibraryRefreshError"] = String(describing: error)
            }
        }
    }

    func openMargins() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margins") else { return }
        openHome()
        requestedExperienceRoot = .margins
    }

    func openLibrary() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_library") else { return }
        openHome()
        requestedExperienceRoot = .library
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
        libraryQuery.contentType = .all
        libraryQuery.listeningState = .unfinished
        libraryQuery.offlineState = .all
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

    func openSettings() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_settings") else { return }
        screen = .settings
    }

    func openHelp() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_help") else { return }
        isHelpPresented = true
    }

    func openAISettingsFromSummaryPrompt() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings") else { return }
        isAISetupNeededPresented = false
        screen = .settings
    }

    func openPlayback() {
        guard !isRequestingRecordingPermission else { return }
        guard hasActiveSession else { return }
        screen = .playback
        if let itemId = snapshot.itemId, let store {
            activeItemId = itemId
            if selectedItem.id != itemId {
                if let detail = activePlaybackDetail, detail.id == itemId {
                    selectedItem = detail
                } else {
                    navigationRefreshTask?.cancel()
                    navigationRefreshTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, let self, self.screen == .playback,
                              self.snapshot.itemId == itemId,
                              let detail = try? self.loadItemDetail(id: itemId, store: store) else { return }
                        self.selectedItem = detail
                    }
                }
            }
        }
    }

    func openTimeline(focusMarginID: String? = nil) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_timeline") else { return }
        guard hasActiveSession else { return }
        requestedTimelineFocusMarginID = focusMarginID
        screen = .timeline
    }

    func openOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_offline_storage") else { return }
        tryRefreshOfflineStorageUsage()
        screen = .offlineStorage
    }

    func refreshOfflineStoragePresentation() {
        tryRefreshOfflineStorageUsage()
    }

    func returnToSettingsFromOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("return_to_settings") else { return }
        screen = .settings
    }

    func openExport() {
        openExport(sessionId: nil)
    }

    func openExport(sessionId: String?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        exportSessionId = sessionId
            ?? (snapshot.itemId == selectedItem.id ? snapshot.sessionId : nil)
            ?? selectedItem.sessions.first?.id
        screen = .export
        refreshExportPreview(reportStatus: false)
    }

    func openBatchExport() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_batch_export") else { return }
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

    var hasBatchExportFolder: Bool { SavedFolderSetting.sessionExport.hasFolder() }
    var hasMarginNotesFolder: Bool { SavedFolderSetting.marginNotes.hasFolder() }

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
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        defer { recordDeveloperDiagnostic("item.open.end", ["durationMs": String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStart) * 1000))]) }
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            prepareImportedLocalAudioBridges(itemId: id)
            scheduleTextAudioPrewarmIfNeeded(itemId: id); PublisherAudioTextMapper.resume(itemId: id, store: store, transcriber: sourceTranscriptionClient) { [weak self] in self?.diagnostics["publisherAudioTextMap"] = "\(id): \($0)" }
            listeningMapJSON = ""
            screen = .item
            discoverFollowOfferIfEligible(itemId: id, store: store)
            offerFollowSuggestionIfEligible(itemId: id, store: store)
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    func startItem(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_item") else { return }
        prepareImportedLocalAudioBridges(itemId: id)
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
        resetMixWithOtherAudioForNewSession()
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        cancelSleepTimer()
        sharedMarginOffers.removeAll()
        pendingImportedCommentary = nil
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if hasActiveSession, let engine {
            _ = try? endEngineSession(engine)
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
        guard !rejectNavigationOrSessionMutationWhileRecording("open_session") else { return }
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

    func markItemCompleted(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_completed") else { return }
        do {
            let store = try requireStore()
            // Completion is an item-level fact, not fabricated listening history.
            guard let item = try ManualItemCompletion.markComplete(itemId: id, in: store) else { return }
            listeningSignals.finish(itemId: id)
            try refreshLibraryRows(store: store)
            if selectedItem.id == id { selectedItem = try loadItemDetail(id: id, store: store) }
            presentCompletionUndo(itemId: id, title: item.title, markedAt: item.sourceCompletedAt ?? Date())
        } catch {
            reportFailure(error, context: "Mark complete failed")
        }
    }

    func undoMarkedCompletion(itemId: String, markedAt: Date) {
        clearMarkedCompletion(id: itemId, markedAt: markedAt)
    }

    /// Any time after the undo banner is gone (#273). Only a completion set by hand.
    func markItemUnfinished(id: String) { clearMarkedCompletion(id: id, markedAt: nil) }

    private func clearMarkedCompletion(id: String, markedAt: Date?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_unfinished") else { return }
        do {
            let store = try requireStore()
            // Never a later completion, and never natural session completion.
            guard let item = try ManualItemCompletion.markUnfinished(itemId: id, markedAt: markedAt, in: store) else { return }
            try refreshLibraryRows(store: store)
            if selectedItem.id == id { selectedItem = try loadItemDetail(id: id, store: store) }
            reportConfirmation(markedAt == nil
                ? ManualCompletionMessages.unfinished(title: item.title)
                : ManualCompletionMessages.undone(title: item.title))
        } catch { reportFailure(error, context: "Mark unfinished failed") }
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
                    reportWarning("Choose a bundled voice and accept its terms before preparing this item offline.")
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

    func moveItemToTrash(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("move_item_to_trash") else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if id == Self.guidedOnboardingItemId {
                UserDefaults.standard.set(true, forKey: Self.guidedOnboardingTombstoneKey)
            }
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

    func dismissFeedback(id: UUID? = nil) {
        guard id == nil || feedbackEvent?.id == id else { return }
        feedbackEvent = nil
    }

    func clearLastFailure(itemId: String) { itemFailures.clear(itemId: itemId) }

    /// Trying an action again answers its Retry banner, so a stale one can't linger over the result.
    private func withdrawRetryOffer(_ key: String) { if feedbackEvent?.retry?.key == key { feedbackEvent = nil } }

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
            let recordings = try store.loadInterjections(itemId: id)
            podcastDownloadCoordinator?.removeItem(id)
            removeDurableGeneratedAudio(for: item)
            removeEpisodeMapArtifacts(itemId: id)
            try store.deleteItem(id: id)
            removeMarginRecordings(recordings, store: store)
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
            let items = try ids.map { try store.loadItem(id: $0) }
            for item in items {
                guard item.deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            let recordings = try ids.flatMap { try store.loadInterjections(itemId: $0) }
            ids.forEach { podcastDownloadCoordinator?.removeItem($0) }
            items.forEach(removeDurableGeneratedAudio)
            ids.forEach(removeEpisodeMapArtifacts)
            try store.deleteItems(ids: ids)
            removeMarginRecordings(recordings, store: store)
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
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.skipBack(unit: skipUnitForCurrentTarget())
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipBackMedia() {
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipBack(unit: mediaSkipUnit(seconds: mediaSkipBackSeconds))
            refreshSelectedItem()
        }
    }

    func skipForward() {
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            let unit = skipUnitForCurrentTarget()
            snapshot = try engine.skipForward(unit: unit)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped forward.")
        }
    }

    func skipForwardMedia() {
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipForward(unit: mediaSkipUnit(seconds: mediaSkipForwardSeconds))
            refreshSelectedItem()
        }
    }

    func mediaSkipSettingsChanged() {
        mediaSkipBackSeconds = MediaSkipRule.validated(mediaSkipBackSeconds)
        mediaSkipForwardSeconds = MediaSkipRule.validated(mediaSkipForwardSeconds)
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
        guard !rejectNavigationOrSessionMutationWhileRecording("set_media_playback_rate") else { return }
        let clamped = SpeechRateRule.quarterStepMultiplier(rate)
        mediaPlaybackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "mediaPlaybackRate")
        if var bridge = snapshot.skimBridgeState {
            if bridge.status == .playing {
                skimBridgePlayer?.rate = SummaryBridgeRatePolicy.transportRate(clamped)
            }
            snapshot.playbackRate = clamped
            bridge.status = snapshot.skimBridgeState?.status ?? bridge.status
            snapshot.skimBridgeState = bridge
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
            return
        }
        run { engine in
            snapshot = try engine.setPlaybackRate(clamped)
            refreshSelectedItem()
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
        }
    }

    /// Seeks the source player, or records the destination when a restored paused session
    /// has no player yet; the next playback start then opens the source there.
    private func seekOrStageMedia(_ engine: SessionEngine, toMediaTimeMs mediaTimeMs: Int) throws -> SessionSnapshot {
        do {
            return try engine.seekMedia(toMediaTimeMs: mediaTimeMs)
        } catch SessionKitError.invalidCommandForState(let reason)
            where reason == "media_seek_player_unavailable" && engine.snapshot.status == .paused {
            return try engine.stagePausedMediaPosition(toMediaTimeMs: mediaTimeMs)
        }
    }

    @discardableResult
    func seekMedia(toMediaTimeMs mediaTimeMs: Int) -> Bool {
        recordDeveloperDiagnostic("seek.media.request", ["timeMs": String(mediaTimeMs)])
        restoreSkimOriginBeforeCanonicalTransport()
        return run { engine in
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: mediaTimeMs)
            recordMediaSeekEvidence(from: engine)
            refreshSelectedItem()
        }
    }

    func cyclePlaybackRate() {
        guard !rejectNavigationOrSessionMutationWhileRecording("cycle_playback_rate") else { return }
        let current = isMediaPlaybackSnapshot ? mediaPlaybackRate : speechPlaybackRateMultiplier
        let next = Self.nextPlaybackRate(after: current)
        if isMediaPlaybackSnapshot {
            setMediaPlaybackRate(next)
        } else {
            speechRate = next * 0.5
            playbackSpeechRateChanged()
        }
    }

    func mixWithOtherAudioAvailabilityChanged() {
        UserDefaults.standard.set(
            showsMixWithOtherAudioOption,
            forKey: Self.showsMixWithOtherAudioOptionKey
        )
        if !showsMixWithOtherAudioOption, mixesWithOtherAudio {
            setMixesWithOtherAudio(false)
        }
        diagnostics["mixWithOtherAudioAvailable"] = showsMixWithOtherAudioOption ? "true" : "false"
    }

    func setMixesWithOtherAudio(_ enabled: Bool) {
        guard playingImportedCommentary == nil else {
            reportWarning("Return to Source before changing audio mixing.")
            return
        }
        guard enabled != mixesWithOtherAudio else { return }
        guard !enabled || showsMixWithOtherAudioOption else {
            reportFailure("Enable Mix with Other Audio in Settings before using it for a listening session.")
            return
        }
        let audio = sessionAudioPlaybackClient ?? audioPlaybackClientOverride
        do {
            if enabled {
                gate2CompactControls.setNowPlayingEnabled(false)
                audio?.setRemoteCommandHandlingEnabled(false)
                try audio?.setMixesWithOtherAudio(true)
                try audio?.setPlaybackVolume(Float(mixedPlaybackVolume))
            } else {
                try audio?.setLowersBackgroundAudio(false)
                try audio?.setMixesWithOtherAudio(false)
                try audio?.setPlaybackVolume(1)
                audio?.setRemoteCommandHandlingEnabled(true)
                gate2CompactControls.setNowPlayingEnabled(true)
            }
            mixesWithOtherAudio = enabled
            if !enabled { lowersBackgroundAudio = false }
            diagnostics["mixWithOtherAudio"] = enabled ? "enabled_for_session" : "disabled"
            diagnostics["spokenMarginsPlaybackVolume"] = String(format: "%.2f", enabled ? mixedPlaybackVolume : 1)
            updateGate2CompactState()
        } catch {
            if enabled {
                try? audio?.setMixesWithOtherAudio(false)
                try? audio?.setPlaybackVolume(1)
                audio?.setRemoteCommandHandlingEnabled(true)
                gate2CompactControls.setNowPlayingEnabled(true)
            } else {
                gate2CompactControls.setNowPlayingEnabled(false)
                audio?.setRemoteCommandHandlingEnabled(false)
                try? audio?.setMixesWithOtherAudio(true)
                try? audio?.setLowersBackgroundAudio(lowersBackgroundAudio)
                try? audio?.setPlaybackVolume(Float(mixedPlaybackVolume))
            }
            reportFailure(error, context: "Audio mixing update failed")
        }
    }

    func setLowersBackgroundAudio(_ enabled: Bool) {
        guard mixesWithOtherAudio, enabled != lowersBackgroundAudio else { return }
        let audio = sessionAudioPlaybackClient ?? audioPlaybackClientOverride
        do {
            try audio?.setLowersBackgroundAudio(enabled)
            lowersBackgroundAudio = enabled
        } catch {
            try? audio?.setLowersBackgroundAudio(lowersBackgroundAudio)
            reportFailure(error, context: "Background audio update failed")
        }
    }

    func mixedPlaybackVolumeChanged() {
        mixedPlaybackVolume = max(0, min(Self.mixedPlaybackVolumeMaximum, mixedPlaybackVolume))
        UserDefaults.standard.set(mixedPlaybackVolume, forKey: Self.mixedPlaybackVolumeKey)
        guard mixesWithOtherAudio else { return }
        do {
            try (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setPlaybackVolume(
                Float(mixedPlaybackVolume)
            )
            diagnostics["spokenMarginsPlaybackVolume"] = String(format: "%.2f", mixedPlaybackVolume)
        } catch {
            reportFailure(error, context: "Spoken Margins volume update failed")
        }
    }

    private func resetMixWithOtherAudioForNewSession() {
        if mixesWithOtherAudio {
            setMixesWithOtherAudio(false)
        } else {
            sessionAudioPlaybackClient?.setRemoteCommandHandlingEnabled(true)
            gate2CompactControls.setNowPlayingEnabled(true)
        }
        diagnostics["mixWithOtherAudio"] = "default_off_for_session"
    }

    nonisolated static func nextPlaybackRate(after current: Double) -> Double {
        SpeechRateRule.next(after: current)
    }

    private func recordMediaSeekEvidence(from engine: SessionEngine) {
        guard let request = engine.lastMediaSeekRequest,
              let resolution = engine.lastMediaSeekResolution else { return }
        let outcome: String
        switch resolution {
        case .pending:
            outcome = "pending"
        case .accepted(let mediaTimeMs):
            outcome = "accepted:\(mediaTimeMs)"
        case .failed(let actualMediaTimeMs, let reason):
            outcome = "failed:\(actualMediaTimeMs.map(String.init) ?? "unknown"):\(reason)"
        }
        let evidence = "id:\(request.id),requested:\(request.requestedMediaTimeMs),outcome:\(outcome)"
        if diagnostics["mediaSeek"] != evidence {
            recordDeveloperDiagnostic("seek.media.result", ["id": String(request.id),
                "requested": String(request.requestedMediaTimeMs), "outcome": outcome])
        }
        diagnostics["mediaSeek"] = evidence
    }

    @discardableResult
    func seekText(toCharOffset charOffset: Int) -> Bool {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        recordDeveloperDiagnostic("seek.text.request", ["offset": String(charOffset)])
        synchronizeStreamingSpeechAnchorIfNeeded()
        return run { engine in
            snapshot = try engine.seekText(toCharOffset: charOffset)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
        }
    }

    func playbackSpeechRateChanged() {
        guard !rejectNavigationOrSessionMutationWhileRecording("set_speech_playback_rate") else { return }
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
        let transportRate = speechPlaybackRateMultiplier
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
            let transportRate = speechPlaybackRateMultiplier
            return started.playbackRate == transportRate
                ? started
                : try engine.setPlaybackRate(transportRate)
        default:
            return started
        }
    }

    func redownloadSelectedPodcast() {
        guard let coordinator = podcastDownloadCoordinator else { return }
        requestedPodcastTransportReplacements.insert(selectedItem.id)
        if coordinator.recordsByItemId[selectedItem.id] == nil {
            prioritizeOfflinePreparation(id: selectedItem.id)
        } else { coordinator.redownload(itemId: selectedItem.id) }
        reportConfirmation("Downloading a fresh copy of the podcast.")
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

    func beginInterjection() {
        guard !isFinishingInterjection, !isMarginCaptureCoolingDown else { return }
        guard snapshot.skimBridgeState == nil else {
            reportWarning("Margins are unavailable while a scene summary is playing. Pause or cancel Skim first.")
            return
        }
        guard !recordingNavigationIsLocked, handOffPlayingMarginToRecording() else { return }
        let voiceCaptureRequestID = UUID()
        pendingVoiceCaptureRequestID = voiceCaptureRequestID
        recordingPermissionDenied = false
        isRequestingRecordingPermission = true
        statusMessage = "Starting Margin..."
        lastError = nil
        diagnostics["lastInterjectionTap"] = "begin"
        let requestedAt = Date()
        recordingPresentationContext = RecordingPresentationContext(
            itemTitle: selectedItem.title.isEmpty ? "Current item" : selectedItem.title,
            locationTitle: snapshot.chapterTitle ?? "Current listening position",
            progressPercent: snapshot.currentPlaybackProgressPercent,
            startedAt: requestedAt
        )
        if recordingClientOverride != nil, microphonePermissionRequest == nil {
            startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
            return
        }
        #if canImport(AVFoundation) && os(iOS)
        let recordPermissionIsGranted = AVAudioApplication.shared.recordPermission == .granted
        if recordPermissionIsGranted, microphonePermissionRequest == nil {
            diagnostics["lastMicrophonePermissionResult"] = "granted"
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
            }
            return
        }
        #endif
        if let status = microphonePrimerStatus(),
           microphonePrimer.holds(captureID: voiceCaptureRequestID, status: status) {
            diagnostics["lastMicrophonePermissionResult"] = "primer_shown"
            return
        }
        requestMicrophoneThenRecord(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
    }

    /// #866: Add Margin while a Margin plays records straight away. The voice stops without resuming the source,
    /// and the source moves to the playing Margin's place so the new Margin is anchored there. False when that move
    /// failed: nothing records, rather than recording at the wrong place.
    private func handOffPlayingMarginToRecording() -> Bool {
        let handoff: MarginCaptureHandoff
        if let prompt = playingImportedCommentary {
            handoff = MarginCaptureHandoff(sharedMargin: prompt.interjection, itemId: prompt.layer.itemId)
            sharedMarginOffers.markAnnounced(prompt.id) // the rejoin mustn't offer it again
            stopImportedCommentaryPlayback(resumeSource: false)
        } else if let conductor = marginMomentConductor, conductor.isPlayingVoice {
            handoff = MarginCaptureHandoff(moment: conductor.sequence)
            endMarginMoment()
        } else if let playingID = playingInterjectionAudioId {
            // Your own Margin heard from its detail: it sits where it was recorded.
            let margin = playingInterjectionAudioSessionID.flatMap { try? store?.loadInterjections(sessionId: $0) }?.first { $0.id == playingID }
            handoff = margin.map { MarginCaptureHandoff(localMargin: $0) } ?? MarginCaptureHandoff(itemId: nil, place: nil)
            stopInterjectionAudioPlayback()
        } else {
            return true
        }
        let move = handoff.sourceMove(from: snapshot)
        diagnostics["marginCaptureHandoff"] = String(describing: move)
        let moved: Bool
        switch move {
        case .stay: return true
        case .seekMedia(let ms): moved = seekMedia(toMediaTimeMs: ms)
        case .seekText(let charOffset): moved = seekText(toCharOffset: charOffset)
        }
        if !moved { reportFailure("Couldn't go back to that Margin's place, so no Margin was started. Tap Add Margin again to record where the source is.") }
        return moved
    }

    /// #783: Continue on the line before the microphone prompt goes on to iOS's request.
    func continueMicrophonePrimer() {
        guard let captureID = microphonePrimer.continueTapped(),
              pendingVoiceCaptureRequestID == captureID else { return }
        requestMicrophoneThenRecord(requestedAt: Date(), captureID: captureID)
    }

    private func requestMicrophoneThenRecord(requestedAt: Date, captureID voiceCaptureRequestID: UUID) {
        Task {
            let granted = await requestMicrophonePermission()
            guard pendingVoiceCaptureRequestID == voiceCaptureRequestID else { return }
            guard granted else {
                isRequestingRecordingPermission = false
                recordingPresentationContext = nil
                pendingVoiceCaptureRequestID = nil
                recordingPermissionDenied = true
                reportFailure("Microphone access is required to record Margins. Enable microphone access in Settings and try again.")
                return
            }
            startInterjectionRecording(requestedAt: requestedAt, captureID: voiceCaptureRequestID)
        }
    }

    private func startInterjectionRecording(requestedAt: Date, captureID: UUID) {
        guard pendingVoiceCaptureRequestID == captureID else { return }
        defer {
            isRequestingRecordingPermission = false
            pendingVoiceCaptureRequestID = nil
        }
        synchronizeStreamingSpeechAnchorIfNeeded()
        streamingSpeechQueue.pauseForInterjection()
        run { engine in
            snapshot = try engine.beginInterjection()
            if snapshot.isRecording {
                recordingPresentationContext = RecordingPresentationContext(
                    itemTitle: selectedItem.title,
                    locationTitle: snapshot.chapterTitle ?? "Current listening position",
                    progressPercent: snapshot.currentPlaybackProgressPercent,
                    startedAt: Date()
                )
                let latencyMs = max(0, Int(Date().timeIntervalSince(requestedAt) * 1000))
                diagnostics["lastInterjectionRecordingStartLatencyMs"] = "\(latencyMs)"
            }
        }
        guard !snapshot.isRecording else { return }
        recordingPresentationContext = nil
        streamingSpeechQueue.resumeAfterInterjection() // the recorder wouldn't start and the engine put the source back (#1034)
    }

    /// Publish acknowledgement before synchronous recorder/store finalization.
    /// Keep capture gated briefly after dismissal so a second tap cannot start a new Margin.
    func requestFinishInterjection() {
        guard snapshot.isRecording, !isFinishingInterjection else { return }
        isFinishingInterjection = true
        isMarginCaptureCoolingDown = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.finishInterjection()
            self.isFinishingInterjection = false
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.isMarginCaptureCoolingDown = false
        }
    }

    func finishInterjection() {
        guard snapshot.isRecording, let verdict = verdictForSavingRecording() else { return }
        run { engine in
            defer { recordSpokenMarginSavedBeforeFailure(engine.lastScheduledTranscriptionInterjectionId) }
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            transcribeAndRecordSavedSpokenMargin()
            reportMarginSaved(verdict)
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
            refreshMarginRows()
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func recordSavedInterjectionForOnboarding() {
        changeOnboardingProgress { $0.firstInterjectionSaved() }
    }

    func cancelInterjection() {
        if isRequestingRecordingPermission && !snapshot.isRecording {
            microphonePrimer.cancel()
            pendingVoiceCaptureRequestID = nil
            isRequestingRecordingPermission = false
            recordingPresentationContext = nil
            return
        }
        recordFinalCaptureDiagnostics("cancelled")
        run { engine in
            snapshot = try engine.cancelInterjection()
            refreshSelectedItem()
            reportSuccess("Cancelled Margin.")
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
        }
        streamingSpeechQueue.resumeAfterInterjection()
    }

    func beginWrittenMargin() {
        guard !recordingNavigationIsLocked else { return }
        guard snapshot.skimBridgeState == nil, playingImportedCommentary == nil else {
            reportFailure("Return to the source before writing a Margin.")
            return
        }
        do {
            let store = try requireStore()
            if engine == nil { installEngine(try makeEngine(store: store)) }
            guard let engine else { return }
            synchronizeStreamingSpeechAnchorIfNeeded()
            streamingSpeechQueue.pauseForInterjection()
            let capture = try engine.beginWrittenInterjection()
            lastError = nil
            recordingPermissionDenied = false
            snapshot = engine.snapshot
            writtenMarginDraft = WrittenMarginDraft(
                capture: capture,
                text: "",
                itemTitle: (try? store.loadItem(id: capture.itemId).title) ?? "Current item",
                targetDescription: capture.targetType == .item ? "Source" : (capture.targetType == .assistantTurn ? "Assistant response" : "Interjection summary"),
                progressPercent: capture.roughPercent
            )
            recordingPresentationContext = nil
        } catch {
            streamingSpeechQueue.resumeAfterInterjection()
            reportFailure(error, context: "Written Margin could not start")
        }
    }

    func updateWrittenMarginText(_ text: String) {
        guard writtenMarginDraft != nil else { return }
        writtenMarginDraft?.text = text
    }

    func switchPendingVoiceCaptureToWrittenMargin() {
        guard isRequestingRecordingPermission, !snapshot.isRecording else { return }
        microphonePrimer.cancel()
        isRequestingRecordingPermission = false
        pendingVoiceCaptureRequestID = nil
        recordingPresentationContext = nil
        beginWrittenMargin()
    }

    func saveWrittenMargin(text: String) {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.saveWrittenInterjection(captureId: draft.capture.id, text: text)
            listeningSignals.writtenMargin(itemId: draft.capture.itemId, text: text)
            writtenMarginDraft = nil
            if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
            refreshSelectedItem()
            refreshMarginRows()
            if draft.priorWasPlaying && snapshot.status == .paused {
                reportWarning("Margin saved. Playback is paused; tap Play to continue.")
            } else {
                reportConfirmation("Written Margin saved.")
            }
        } catch {
            writtenMarginDraft?.text = text
            reportFailure(error, context: "Written Margin could not be saved")
        }
    }

    func cancelWrittenMargin() {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.cancelWrittenInterjection(captureId: draft.capture.id)
            writtenMarginDraft = nil
            if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
            refreshSelectedItem()
        } catch {
            reportFailure(error, context: "Written Margin could not be cancelled")
        }
    }

    func endSession() {
        guard !rejectNavigationOrSessionMutationWhileRecording("end_session") else { return }
        closeCurrentSession(navigateHome: true)
    }

    func dismissMiniPlayer() {
        recordDeveloperDiagnostic("miniPlayer.close")
        guard !rejectNavigationOrSessionMutationWhileRecording("dismiss_mini_player") else { return }
        guard !isDismissingMiniPlayer else { return }
        isDismissingMiniPlayer = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.closeCurrentSession(navigateHome: false)
            self.isDismissingMiniPlayer = false
        }
    }

    private func closeCurrentSession(
        navigateHome: Bool,
        successMessage: String = "Session saved. You can resume it later."
    ) {
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        let closedItemId = snapshot.itemId ?? activeItemId
        run { engine in
            snapshot = try endEngineSession(engine)
            activeItemId = SessionCloseSelection.itemId(closing: closedItemId, pageOnScreen: screen == .item ? selectedItem.id : nil, navigatesHome: navigateHome)
            refreshSelectedItem()
            if let store {
                try refreshLibraryRows(store: store)
            }
            reportConfirmation(successMessage)
        }
        streamingSpeechQueue.stopAndClear()
        gate2CompactControls.endLiveActivities()
        resetMixWithOtherAudioForNewSession()
        if let renderer = supertonicRenderer {
            Task { await renderer.unload() }
        }
        if navigateHome {
            screen = .home
        }
    }

    func summarize() {
        let itemId = snapshot.itemId ?? ""
        withdrawRetryOffer("summary")
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
                reportFailure("A Margin summary already exists for this session.")
                return
            }
            syncPlaybackProgressForLifecycle()
            run { engine in
                snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
                let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
                let contexts = localSummaryContexts(interjections: engine.lastSummaryCandidates)
                submitLocalSummary(itemId: itemId, turnId: turnId, contexts: contexts)
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
            reportFailure("A Margin summary already exists for this session.")
            return
        }
        syncPlaybackProgressForLifecycle()
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
            let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
            submitProviderJobIfNeeded(kind: "interjection_summary", itemId: itemId, turnId: turnId, messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
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
        guard snapshot.phase == .finished else { return }
        if let store {
            try? refreshLibraryRows(store: store)
        }
        refreshMarginRows()
        diagnostics["completedSessionPresentation"] = "retained_finished_session"
        reportConfirmation("Session complete and saved.")
    }

    private func shouldDeferGeneratedTurnPlayback(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
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
                itemId: snapshot.itemId ?? "",
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
            submitProviderJobIfNeeded(kind: job.kind, itemId: snapshot.itemId ?? "", turnId: turnId, messages: messages, force: true)
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
        exportShareCandidates = []
        guard let exportSessionId else {
            exportPreview = ""
            exportFileURL = nil
            return
        }
        run { engine in
            let store = try requireStore()
            exportShareCandidates = try store.loadInterjections(sessionId: exportSessionId)
                .filter { $0.status == "active" && $0.targetType == .item }
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

    /// Sets only the Export Sessions folder. It must not touch the notes folder or its destination ID,
    /// or the notes feature copies every Margin into the folder picked for an export (#930).
    func configureBatchExportFolder(url: URL) {
        do {
            try SavedFolderSetting.sessionExport.save(folder: url)
            batchExportFolderName = url.lastPathComponent
            batchExportResult = nil
            reportSuccess("Export folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Export folder setup failed")
        }
    }

    /// Sets the "Save Margins to Notes Folder" destination. A new destination ID makes delivery treat
    /// it as a fresh folder, so existing Margins are written there, as the setting says.
    func configureMarginNotesFolder(url: URL) {
        do {
            try SavedFolderSetting.marginNotes.save(folder: url)
            UserDefaults.standard.set(UUID().uuidString, forKey: "marginOutputDestinationID")
            marginNotesFolderName = url.lastPathComponent
            marginOutputStatus = MarginOutputStatus("Notes folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Notes folder setup failed")
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
        guard let folderURL = resolvedFolderURL(.sessionExport) else {
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
                // Timeline-level note copying is intentionally compact. Full AI
                // responses belong to the configurable Export screen; this path
                // carries only the selected notes and their bounded anchors.
                includeTurns: false,
                scope: "target",
                targetType: targetType,
                targetId: targetId
            ))
            guard !export.interjections.isEmpty else {
                reportFailure("No Margins are available for that target.")
                return
            }
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied target Margins.")
            #else
            exportPreview = text
            reportSuccess("Built target Margin export.")
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
                includeTurns: false,
                scope: "selected_interjections",
                interjectionIds: [interjection.id]
            ))
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied Margin with its anchors.")
            #else
            exportPreview = text
            reportSuccess("Built Margin export.")
            #endif
        }
    }

    static func marginIdentity(_ interjection: Interjection) -> String {
        "\(interjection.sessionId)::\(interjection.id)"
    }

    /// Margin IDs repeat per session, so per-Margin diagnostics carry a hashed session token.
    static func marginDiagnosticKey(_ name: String, sessionId: String, interjectionId: String) -> String {
        PodcastAnchorCaptureDiagnostics.marginKey(name, sessionId: sessionId, interjectionId: interjectionId)
    }

    static func marginDiagnosticKey(_ name: String, _ interjection: Interjection) -> String {
        marginDiagnosticKey(name, sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    static func marginDiagnosticKey(_ name: String, _ request: PostResumeAudioSampleRequest) -> String {
        marginDiagnosticKey(name, sessionId: request.sessionId, interjectionId: request.interjectionId)
    }

    func isPlayingInterjectionAudio(_ interjection: Interjection) -> Bool {
        playingInterjectionAudioId == interjection.id && playingInterjectionAudioSessionID == interjection.sessionId
    }

    func isRetryingInterjectionTranscription(_ interjection: Interjection) -> Bool {
        retryingInterjectionTranscriptionIds.contains(Self.marginIdentity(interjection))
    }

    func isRetryingAnchorContext(_ interjection: Interjection) -> Bool {
        pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection))
    }

    func retryAnchorContext(_ interjection: Interjection) {
        guard interjection.captureKind != .written else { return }
        guard !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return }
        if !scheduleSourceWindowContextIfNeeded(for: interjection, reportsResult: true) {
            reportWarning("Context needs a source timestamp and completed Margin transcription. Retry when transcription finishes.")
        }
    }

    func retryInterjectionTranscription(_ interjection: Interjection) {
        guard interjection.captureKind != .written, interjection.audioPath != nil else {
            reportFailure("The saved Margin audio is unavailable.")
            return
        }
        guard retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(interjection)).inserted else { return }
        scheduleTranscription(for: interjection)
        reportConfirmation("Retranscribing the saved Margin audio.")
    }

    func toggleInterjectionAudioPlayback(_ interjection: Interjection) {
        #if canImport(AVFoundation)
        guard interjection.captureKind != .written else { return }
        if isPlayingInterjectionAudio(interjection) {
            stopInterjectionAudioPlayback()
            reportConfirmation("Stopped playing your Margin.")
            return
        }
        guard let audioPath = interjection.audioPath,
              let url = resolvedInterjectionAudioURL(for: audioPath),
              FileManager.default.fileExists(atPath: url.path) else {
            reportFailure("This Margin's audio is unavailable.")
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
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            let rate = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            player.defaultRate = Float(rate)
            interjectionAudioPlayer = player
            playingInterjectionAudioId = interjection.id
            playingInterjectionAudioSessionID = interjection.sessionId
            playingInterjectionAudioRate = rate
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if item.status == .failed {
                        self?.stopInterjectionAudioPlayback()
                        self?.reportFailure("This Margin's audio couldn't be played.")
                        return
                    }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self?.stopInterjectionAudioPlayback()
                        return
                    }
                }
            }
            player.playImmediately(atRate: Float(rate))
            reportConfirmation("Playing your Margin.")
        } catch {
            stopInterjectionAudioPlayback()
            reportFailure(error, context: "Margin playback failed")
        }
        #else
        reportFailure("Margin playback is unavailable on this device.")
        #endif
    }

    func stopInterjectionAudioPlayback() {
        let hadImportedMargin = playingImportedCommentary != nil
        playingImportedCommentary = nil
        importedCommentaryIsPaused = false
        importedCommentaryHealth = nil
        importedCommentaryPhase = .loading
        sourceShouldResumeAfterImportedCommentary = false
        if hadImportedMargin {
            importedMarginRemoteControls.end()
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
        }
        #if canImport(AVFoundation)
        interjectionAudioPlayer?.pause()
        interjectionAudioPlayer?.replaceCurrentItem(with: nil)
        interjectionAudioPlayer = nil
        interjectionAudioCompletionTask?.cancel()
        interjectionAudioCompletionTask = nil
        #endif
        playingInterjectionAudioId = nil
        playingInterjectionAudioSessionID = nil
        playingInterjectionAudioRate = 1
    }

    func listenToPendingImportedCommentary() {
        guard let prompt = pendingImportedCommentary else { return }
        listenToImportedCommentary(prompt)
    }

    func dismissPendingImportedCommentary() {
        guard pendingImportedCommentary != nil else { return }
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        let shouldResume = sourcePausedForImportedCommentaryPrompt
        sourcePausedForImportedCommentaryPrompt = false
        if shouldResume, snapshot.status == .paused {
            resumePlayback()
        }
    }

    func listenToImportedCommentary(layerID: String, interjectionID: String) {
        guard let layer = selectedItem.importedCommentaryLayers.first(where: { $0.id == layerID }),
              let records = selectedItem.importedCommentaryInterjections[layerID],
              let offset = records.firstIndex(where: { $0.id == interjectionID }) else { return }
        listenToImportedCommentary(ImportedCommentaryPrompt(
            layer: layer,
            interjection: records[offset],
            index: offset + 1,
            count: records.count
        ))
    }

    func returnToSourceFromImportedCommentary() {
        stopImportedCommentaryPlayback(resumeSource: true)
    }

    func listenToImportedCommentary(_ prompt: ImportedCommentaryPrompt) {
        sharedMarginOffers.remove(id: prompt.id)
        #if canImport(AVFoundation)
        guard let audioPath = prompt.interjection.audioPath,
              let audioURL = resolvedApplicationSupportAssetURL(for: audioPath) else {
            dismissPendingImportedCommentary()
            reportFailure("This shared Margin contains reviewed text but no playable voice recording.")
            return
        }
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        let shouldResumeSource = sourcePausedForImportedCommentaryPrompt
            || snapshot.status.isPlaybackActive
            || (playingImportedCommentary != nil && sourceShouldResumeAfterImportedCommentary)
        sourcePausedForImportedCommentaryPrompt = false
        if snapshot.status.isPlaybackActive { pause() }
        stopInterjectionAudioPlayback()
        sourceShouldResumeAfterImportedCommentary = shouldResumeSource
        do {
            #if os(iOS)
            let options: AVAudioSession.CategoryOptions = mixesWithOtherAudio
                ? (lowersBackgroundAudio ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]) : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: audioURL)
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.volume = mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1
            let rate = Self.marginPlaybackRate(itemPlaybackRate: snapshot.playbackRate)
            player.defaultRate = Float(rate)
            interjectionAudioPlayer = player
            playingInterjectionAudioRate = rate
            playingImportedCommentary = prompt
            importedCommentaryIsPaused = false
            let health = SharedMarginPlaybackHealth(startedAt: ProcessInfo.processInfo.systemUptime)
            importedCommentaryHealth = health
            importedCommentaryPhase = health.phase
            let attempt = health.attemptID
            pendingImportedCommentary = nil
            (sessionAudioPlaybackClient ?? audioPlaybackClientOverride)?.setRemoteCommandHandlingEnabled(false)
            gate2CompactControls.setNowPlayingEnabled(false)
            gate2CompactControls.endLiveActivities()
            if !mixesWithOtherAudio {
                importedMarginRemoteControls.install { [weak self] command in
                    guard let self, self.playingImportedCommentary != nil else { return }
                    self.dispatchGate2CompactCommand(command, origin: "imported_margin_remote")
                }
            }
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item, weak player] in
                var heard = false
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(200))
                    // A reading from a replaced or retried attempt must not touch the current one.
                    guard !Task.isCancelled, let self, self.importedCommentaryHealth?.attemptID == attempt else { return }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    // Heard once the voice has played; a file that fails to decode stays new (#690).
                    if !heard, current.isFinite, current > 0 { heard = true; self.markSharedMarginHeard(prompt.interjection) }
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self.stopImportedCommentaryPlayback(resumeSource: true)
                        return
                    }
                    let failed = item.status == .failed || player?.status == .failed
                    self.observeImportedCommentary(playerFailed: failed, clockSeconds: current, playerAtRest: player?.timeControlStatus == .paused)
                    if self.importedCommentaryPhase.isFailed { return }
                    self.publishImportedCommentaryNowPlaying()
                }
            }
            player.playImmediately(atRate: Float(rate))
        } catch {
            stopImportedCommentaryPlayback(resumeSource: false)
            reportFailure(error, context: "Shared Margin playback failed")
        }
        #else
        reportFailure("Shared Margin playback is unavailable on this device.")
        #endif
    }

    /// Its voice started playing, so the shared Margin is no longer new to this listener (#469).
    private func markSharedMarginHeard(_ margin: ImportedCommentaryInterjection) {
        guard margin.isNewToListener, let heard = try? store?.markImportedCommentaryInterjectionHeard(id: margin.id, at: Date()) else { return }
        selectedItem.importedCommentaryInterjections = SharedMarginHearing.replacing(heard, in: selectedItem.importedCommentaryInterjections)
        sharedMarginRows = sharedMarginRows.map { $0.interjection.id == heard.id ? SharedMarginRow(interjection: heard, layer: $0.layer, itemTitle: $0.itemTitle, placement: $0.placement) : $0 }
    }

    private func stopImportedCommentaryPlayback(resumeSource: Bool) {
        let shouldResume = resumeSource && sourceShouldResumeAfterImportedCommentary
        stopInterjectionAudioPlayback()
        playingImportedCommentary = nil
        sourceShouldResumeAfterImportedCommentary = false
        if shouldResume, snapshot.status == .paused { resumePlayback() }
    }

    private func reconcileImportedCommentary(previous: SessionSnapshot, current: SessionSnapshot) {
        // Margins crossed together are offered one after another (#918).
        guard let prompt = sharedMarginOffers.nextOffer(
            previous: previous, current: current, selectedItemID: selectedItem.id,
            canOffer: pendingImportedCommentary == nil && playingImportedCommentary == nil,
            prompts: importedCommentaryPrompts(includeAnnounced: true)
        ) else { return }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: current.status.isPlaybackActive)
    }

    private func importedCommentaryPrompts(includeAnnounced: Bool) -> [ImportedCommentaryPrompt] {
        SharedMarginPrompts.prompts(
            layers: selectedItem.importedCommentaryLayers,
            recordsByLayerID: selectedItem.importedCommentaryInterjections,
            announcedIDs: includeAnnounced ? [] : sharedMarginOffers.announcedIDs, // nextOffer's autoclosure runs inside its modify of sharedMarginOffers
            includeAnnounced: includeAnnounced
        )
    }

    private func presentImportedCommentaryPrompt(
        _ prompt: ImportedCommentaryPrompt,
        sourceWasPlaying: Bool
    ) {
        sourcePausedForImportedCommentaryPrompt = sourceWasPlaying
        if sourceWasPlaying, snapshot.status.isPlaybackActive { pause() }
        if !prompt.layer.isMuted { playImportedCommentaryCue() }
        pendingImportedCommentary = prompt
        if prompt.layer.revealMode == .guided {
            importedCommentaryAutoPlayTask?.cancel()
            importedCommentaryAutoPlayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled,
                      self?.pendingImportedCommentary?.id == prompt.id else { return }
                self?.listenToPendingImportedCommentary()
            }
        }
    }

    private func jumpToImportedCommentary(interjectionID: String) -> Bool {
        guard let prompt = importedCommentaryPrompts(includeAnnounced: true)
            .first(where: { $0.interjection.id == interjectionID }) else {
            reportFailure("The selected Shared Margin is no longer available.")
            return false
        }
        let sourceWasPlaying = snapshot.status.isPlaybackActive
        sharedMarginOffers.markAnnounced(prompt.id)
        if sourceWasPlaying { pause() }
        if let mediaTimeMs = prompt.interjection.resolution.localMediaTimeMs {
            seekMedia(toMediaTimeMs: mediaTimeMs)
        } else if let charOffset = prompt.interjection.resolution.localStartChar {
            seekText(toCharOffset: charOffset)
        } else {
            reportFailure("The selected Shared Margin does not have a verified local position.")
            return false
        }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: sourceWasPlaying)
        screen = .playback
        diagnostics["lastSharedMarginNavigation"] = "opened:\(interjectionID)"
        return true
    }

    nonisolated static func isPlayableImportedCommentaryResolution(_ resolution: ImportedAnchorResolution) -> Bool {
        SharedMarginPrompts.isPlayable(resolution)
    }

    nonisolated static func marginPlaybackRate(itemPlaybackRate: Double) -> Double {
        guard itemPlaybackRate.isFinite else { return 1 }
        return max(0.25, min(3, itemPlaybackRate))
    }

    private func playImportedCommentaryCue() {
        #if canImport(AVFoundation)
        do { commentaryCuePlayer = try SharedMarginChime.play() } catch {
            diagnostics["importedCommentaryCue"] = "failed:\(error.localizedDescription)"
        }
        #endif
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
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, sessionId: interjection.sessionId, representation: "transcript")
            refreshSelectedItem()
            reportSuccess("Deleted transcript.")
        }
        refreshMarginRows()
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
            reportSuccess("Deleted Margin.")
        }
        refreshMarginRows()
    }

    func setInterjectionStarredForSharing(_ interjectionID: String, sessionId: String? = nil, starred: Bool) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCuration:\(interjectionID)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin sharing star could not be saved")
        }
    }

    func setMarginStarred(_ row: MarginRow, starred: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("star_margin") else { return }
        do {
            let store = try requireStore()
            guard var interjection = try store.loadInterjections(sessionId: row.interjection.sessionId).first(where: {
                $0.id == row.interjection.id
                    && $0.sessionId == row.interjection.sessionId
                    && $0.itemId == row.interjection.itemId
            }) else {
                throw SessionKitError.persistenceFailed("margin_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshMarginRows()
            if snapshot.sessionId == row.interjection.sessionId { refreshSelectedItem() }
            diagnostics["marginCuration:\(row.id)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin star could not be saved")
        }
    }

    func setInterjectionPrivateSharingNote(_ interjectionID: String, sessionId: String? = nil, note: String) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            let bounded = String(note.prefix(Self.privateSharingNoteCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            interjection.privateSharingNote = bounded.isEmpty ? nil : bounded
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCurationNote:\(interjectionID)"] = bounded.isEmpty ? "empty" : "saved"
        } catch {
            reportFailure(error, context: "Private sharing note could not be saved")
        }
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

    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        if command == .beginInterjection {
            guard !recordingNavigationIsLocked else { return }
            if recordingClientOverride != nil {
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
                return
            }
            isRequestingRecordingPermission = true
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    isRequestingRecordingPermission = false
                    reportFailure("Microphone access is required to record Margins from compact controls.")
                    return
                }
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
                isRequestingRecordingPermission = false
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        guard let command = CompactControlCommand(rawValue: rawCommand) else {
            if !handleGate2CompactApplicationCommand(
                rawCommand,
                targetID: Gate2CompactCommandURL.chapterId(from: url)
            ) {
                reportFailure("Unsupported compact control URL.")
            }
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
            try consumePendingSpokenMarginsPackageHandoffs(
                from: SpokenMarginsPackageHandoffStore.appGroup()
            )
        } catch {
            diagnostics["pendingSpokenMarginsPackageImport"] = "unavailable:\(error.localizedDescription)"
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

    func consumePendingSpokenMarginsPackageHandoffs(
        from packageStore: SpokenMarginsPackageHandoffStore
    ) throws {
        let payloadIDs = try packageStore.pendingPayloadIDs()
        diagnostics["pendingSpokenMarginsPackages"] = "\(payloadIDs.count)"
        for payloadID in payloadIDs where spokenMarginsPackageImportReview == nil {
            do {
                let packageURL = try packageStore.packageURL(payloadID: payloadID)
                let didOpen = stageSpokenMarginsPackageImport(from: packageURL)
                try packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = didOpen ? "opened" : "rejected"
            } catch {
                try? packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "rejected:\(error.localizedDescription)"
                reportFailure(error, context: "Shared Margins package could not be opened")
            }
        }
    }

    @discardableResult
    private func stageSpokenMarginsPackageImport(from sourceURL: URL) -> Bool {
        var workingDirectory: URL?
        do {
            bootstrapLibraryIfNeeded()
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let root = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/IncomingPackages/\(UUID().uuidString)", directoryHint: .isDirectory)
            workingDirectory = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let copiedPackage = root.appending(path: "package.spokenmargins")
            try FileManager.default.copyItem(at: sourceURL, to: copiedPackage)
            let contents = try SpokenMarginsPackageArchive.read(
                from: copiedPackage,
                extractingAssetsTo: root.appending(path: "assets", directoryHint: .isDirectory)
            )
            guard let digest = contents.manifest.contentDigest else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
            let store = try requireStore()
            if let existing = try store.loadImportedCommentaryLayer(packageDigest: digest),
               existing.sourceResolutionStatus != .wrongSource,
               let associatedItemId = existing.itemId,
               let associatedItem = try? store.loadItem(id: associatedItemId),
               associatedItem.deletedAt == nil,
               SharedPacketItemMatcher.layerHasValidItemAssociation(existing, item: associatedItem,
                   ownedAudiobookDigest: localAudiobookDigest(for: associatedItem)) {
                if let itemId = existing.itemId {
                    openItem(id: itemId)
                    if let item = try? store.loadItem(id: itemId), item.mediaType == "audiobook" {
                        Task { @MainActor [weak self] in
                            defer { try? FileManager.default.removeItem(at: root) }
                            guard let self else { return }
                            do {
                                try await self.placeOnOwnedAudio(item, contents: contents,
                                    admission: self.verifyLocalAudioForImport(item, contents: contents))
                                self.reportSuccess("Restored this listening package. Playback has not started.")
                            } catch { self.reportFailure(error, context: "Restoring listening package failed") }
                        }
                        return true
                    }
                    if let localURL = podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                    reportSuccess("These shared Margins are already in your library. Playback has not started.")
                } else {
                    reportSuccess("These shared Margins are already in your library.")
                }
                diagnostics["lastSpokenMarginsPackageImport"] = "duplicate:\(digest)"
                try? FileManager.default.removeItem(at: root)
                return true
            }
            let matchingItemId = try matchingItemID(for: contents.manifest.item, store: store)
            spokenMarginsPackageImportError = nil
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: copiedPackage,
                extractionDirectory: root,
                contents: contents,
                matchingItemId: matchingItemId
            )
            if try store.loadImportedCommentaryLayer(packageDigest: digest) == nil {
                diagnostics["lastSpokenMarginsPackageImport"] = "previewed:\(digest)"
            } else {
                diagnostics["lastSpokenMarginsPackageImport"] = "repair_previewed:\(digest)"
            }
            return true
        } catch {
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
            diagnostics["lastSpokenMarginsPackageImport"] = "rejected:\(SharedMarginsImportMessage.diagnosticDetail(error))"
            reportFailure(SharedMarginsImportMessage.userFacing(error))
            return false
        }
    }

    func createRecipientTestSessionFromLastSharedPackage() {
        guard let packageURL = sharedSpokenMarginsPackageURL else {
            reportFailure("The last shared package is unavailable.")
            return
        }
        isSharingInterjectionsPresented = false
        isSharedSpokenMarginsPackagePresented = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.stageSpokenMarginsPackageImport(from: packageURL)
        }
    }

    func cancelSpokenMarginsPackageImport() {
        guard !isImportingSpokenMarginsPackage else { return }
        let directory = spokenMarginsPackageImportReview?.extractionDirectory
        spokenMarginsPackageImportReview = nil
        spokenMarginsPackageImportError = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    /// Build 23 presentation code calls this seam instead of asking the user to
    /// reopen the package and repeat integrity verification.
    func refreshSpokenMarginsPackageImportAfterAddingSource() {
        guard let review = spokenMarginsPackageImportReview,
              review.requiresRecipientItem,
              !isImportingSpokenMarginsPackage else { return }
        do {
            let store = try requireStore()
            let matchingItemId = try matchingItemID(for: review.contents.manifest.item, store: store)
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: review.packageURL,
                extractionDirectory: review.extractionDirectory,
                contents: review.contents,
                matchingItemId: matchingItemId
            )
            if matchingItemId == nil {
                spokenMarginsPackageImportError = "That source does not match the item described by this package yet. Add the same item or cancel the import."
            } else {
                spokenMarginsPackageImportError = nil
                reportConfirmation("Source matched. Review the shared Margins before importing.")
            }
        } catch {
            spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
            diagnostics["lastSpokenMarginsPackageImport"] = "source_reconciliation_failed:\(error.localizedDescription)"
        }
    }

    func confirmSpokenMarginsPackageImport() {
        guard let review = spokenMarginsPackageImportReview,
              !isImportingSpokenMarginsPackage else { return }
        guard !review.requiresRecipientItem else {
            spokenMarginsPackageImportError = "This package does not include the item. Add the matching source, then return to this pending import."
            return
        }
        isImportingSpokenMarginsPackage = true
        spokenMarginsPackageImportError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let itemId: String?
                if let matching = review.matchingItemId {
                    itemId = matching
                } else if review.contents.manifest.itemTransport.kind == .embeddedText {
                    itemId = try self.installEmbeddedItem(from: review.contents, store: store)
                } else if review.contents.manifest.item.itemType == .podcast {
                    itemId = try await self.acquirePodcastForImportedPackage(review.contents.manifest.item)
                } else {
                    itemId = try await self.acquireArticleForImportedPackage(review.contents.manifest.item)
                }
                let item = try itemId.map { try store.loadItem(id: $0) }
                let localItem = item.map { SharedPacketItemMatcher.localIdentity(for: $0, ownedAudiobookDigest: self.localAudiobookDigest(for: $0)) }
                var localAudioAdmission: LocalAudioPacketAdmission?
                if let item, item.mediaType == "audiobook" {
                    localAudioAdmission = try await self.verifyLocalAudioForImport(item, contents: review.contents)
                }
                let itemText = item?.text
                let disposition: ImportedCommentaryImportDisposition
                if let digest = review.contents.manifest.contentDigest,
                   let existing = try store.loadImportedCommentaryLayer(packageDigest: digest) {
                    try SpokenMarginsPackageImporter.repairAssociation(
                        existing: existing,
                        contents: review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                    if let itemId { self.diagnostics["lastSpokenMarginsPackageRepair"] = "reassociated:\(existing.id):\(itemId)" }
                    disposition = .duplicate(existingLayerId: existing.id)
                } else {
                    disposition = try SpokenMarginsPackageImporter.importPackage(
                        review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                }
                switch disposition {
                case .duplicate(let existingLayerId):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "duplicate_layer:\(existingLayerId)"
                case .imported(let layerId, let interjectionIds):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "imported:\(layerId):\(interjectionIds.count)"
                    self.listeningSignals.packetImport(itemId: itemId, packetId: review.contents.manifest.packageId, marginCount: interjectionIds.count)
                }
                if let itemId {
                    self.activeItemId = itemId
                    self.libraryItems = try self.loadLibraryRows(store: store)
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                    self.screen = .item
                    if let item,
                       item.media?.sourceType == .remoteStream,
                       let rawURL = item.media?.url,
                       let remoteURL = URL(string: rawURL) {
                        self.podcastDownloadCoordinator?.register(
                            itemId: itemId,
                            remoteURL: remoteURL,
                            userInitiated: true
                        )
                    }
                    if let item, let localAudioAdmission {
                        try await self.placeOnOwnedAudio(item, contents: review.contents, admission: localAudioAdmission)
                    } else if let localURL = self.podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        self.resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                }
                self.spokenMarginsPackageImportReview = nil
                self.isImportingSpokenMarginsPackage = false
                self.reportConfirmation("Imported shared Margins. Playback has not started.")
            } catch {
                self.isImportingSpokenMarginsPackage = false
                self.spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
                self.diagnostics["lastSpokenMarginsPackageImport"] = "failed:\(error.localizedDescription)"
                self.reportFailure(error, context: "Shared Margins import failed")
            }
        }
    }

    private func verifyLocalAudioForImport(_ item: Item, contents: VerifiedSpokenMarginsPackage) async throws -> LocalAudioPacketAdmission {
        guard let url = resolvedOwnedAudiobookURL(for: item) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local source audio is unavailable")
        }
        let actualDigest = try await Task.detached(priority: .utility) {
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        }.value
        return try LocalAudioPacketAdmission.admitted(
            contents, recipient: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item)), itemId: item.id, actualDigest: actualDigest)
    }

    /// Exact maps project at the sender's times; a podcast packet on the listener's copy is placed like a download.
    private func placeOnOwnedAudio(_ item: Item, contents: VerifiedSpokenMarginsPackage, admission: LocalAudioPacketAdmission) async throws {
        if admission == .exactEdition { return try await activateImportedLocalAudioMaps(item: item, contents: contents) }
        if let url = resolvedOwnedAudiobookURL(for: item) { resolveImportedPodcastCommentary(itemId: item.id, localURL: url) }
    }

    private func activateImportedLocalAudioMaps(item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        let store = try requireStore()
        let recipient = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item))
        for proposal in contents.listeningMapProposals {
            let projection = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: item.id
            )
            for scene in proposal.scenes where scene.summaryAssetId != nil {
                try await adoptSuppliedSummary(scene: scene, proposalId: proposal.id, itemId: item.id, contents: contents, store: store)
            }
            try store.savePortableListeningMapProposal(proposal, itemId: item.id)
            try store.saveResolvedListeningMapProjection(projection)
        }
        if selectedItem.id == item.id { refreshSelectedItem() }
        prepareImportedLocalAudioBridges(itemId: item.id)
    }

    private func adoptSuppliedSummary(
        scene: PortableListeningMapScene, proposalId: String, itemId: String,
        contents: VerifiedSpokenMarginsPackage, store: SQLiteSessionStore
    ) async throws {
        guard let suppliedID = scene.summaryAssetId,
              let descriptor = contents.manifest.assets.first(where: { $0.id == suppliedID && $0.role == SpokenMarginsAssetRole.summaryVoice }),
              let sourceURL = contents.extractedAssetURLs[suppliedID],
              let checksum = descriptor.sha256, let byteCount = descriptor.byteCount else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Supplied summary audio is unavailable")
        }
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: suppliedID)
        let relativePath = "SpokenMargins/EpisodeMaps/\(safePodcastEvidenceComponent(itemId))/SummaryBridges/\(assetID).m4a"
        let support = try applicationSupportDirectory()
        let destination = support.appending(path: relativePath)
        let ledger = requireOfflineLedger(store: store, rootDirectory: support)
        let reservation = try await ledger.reserve(ownerId: assetID, byteCount: Int64(byteCount))
        do {
            try await Task.detached(priority: .utility) {
                guard try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL) == checksum else {
                    throw SpokenMarginsPackageArchiveError.invalidAsset(suppliedID)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: sourceURL).write(to: destination, options: .atomic)
            }.value
            try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                id: assetID, itemId: itemId, category: .summaryBridge, relativePath: relativePath,
                byteCount: Int64(byteCount), checksumSHA256: checksum, isReproducible: false
            ))
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    private func prepareImportedLocalAudioBridges(itemId: String) {
        guard let store, let item = try? store.loadItem(id: itemId),
              item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream || item.media?.sourceType == .generatedTTSPrerendered,
              let projection = try? store.loadResolvedListeningMapProjection(itemId: itemId),
              let proposals = try? store.loadPortableListeningMapProposals(itemId: itemId),
              let proposal = proposals.first(where: { $0.id == projection.proposalId }),
              preparingLocalAudioMapItems.insert(itemId).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparingLocalAudioMapItems.remove(itemId) }
            do {
                for scene in proposal.scenes where scene.eligibility == .eligible {
                    try Task.checkCancellation()
                    guard try await self.prepareSummaryBridgeAsset(
                        itemId: itemId, proposalId: proposal.id, scene: scene, store: store
                    ) != nil else {
                        throw SessionKitError.persistenceFailed("Summary audio was not prepared")
                    }
                    self.updateSkimAvailability()
                }
                self.diagnostics["localAudioSkim:\(itemId)"] = "ready"
            } catch {
                self.diagnostics["localAudioSkim:\(itemId)"] = "failed:\(error.localizedDescription)"
                self.reportWarning("Some Skim summaries are not ready. Reopen the item to retry, or reimport the package to restore its supplied voices.")
            }
        }
    }

    private func installEmbeddedItem(
        from contents: VerifiedSpokenMarginsPackage,
        store: SQLiteSessionStore
    ) throws -> String {
        guard contents.manifest.itemTransport.kind == .embeddedText,
              let artifactID = contents.manifest.itemTransport.embeddedArtifactId,
              let embedded = contents.embeddedTextItems.first(where: { $0.id == artifactID }),
              let digest = contents.manifest.contentDigest else {
            throw SessionKitError.persistenceFailed("shared_embedded_item_is_unavailable")
        }
        let itemID = "item-shared-\(digest.prefix(20))"
        let item = Item(
            id: itemID,
            title: contents.manifest.item.title,
            mediaType: "text",
            text: embedded.text,
            externalReference: "shared-package:\(contents.manifest.packageId)",
            status: "ready",
            externalReferenceType: "spoken_margins_package"
        )
        try store.seed(item: item)
        return itemID
    }

    private func acquirePodcastForImportedPackage(_ item: SharedItemIdentity) async throws -> String {
        guard let canonicalURL = item.canonicalURL,
              SharedPodcastResolutionPolicy.hasReference(item) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_has_no_reference")
        }
        let request = LinkResolutionRequest(
            id: "shared-package-\(UUID().uuidString)",
            inputURL: canonicalURL,
            sourceSurface: "spoken_margins_package",
            createdAt: Date()
        )
        var result: LinkResolutionResult
        do {
            if let sourceLinkResolver {
                result = try sourceLinkResolver.resolve(request)
            } else {
                result = try await PublicPodcastLinkResolver().resolveAsync(request)
            }
        } catch {
            // Keep the existing resolver path first. Some publisher pages reject
            // automated requests even when the packet has the exact enclosure.
            // In that case, use its reference through the same source persistence
            // path; anchor placement still needs recipient evidence.
            guard let packageResult = SharedPodcastResolutionPolicy.packageReferenceResolution(item: item, request: request) else {
                throw error
            }
            diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_resolution_failure"
            result = packageResult
        }
        let settled = try SharedPodcastResolutionPolicy.settle(result, item: item, request: request)
        result = settled.result
        if let diagnostic = settled.diagnostic {
            diagnostics["lastSharedPodcastAcquisition"] = diagnostic
        }
        guard result.status == .playable,
              let importedItem = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_not_created")
        }
        return importedItem.id
    }

    private func matchingItemID(
        for itemIdentity: SharedItemIdentity,
        store: SQLiteSessionStore
    ) throws -> String? {
        if shouldForceFirstSharedSourceMissForUITesting {
            shouldForceFirstSharedSourceMissForUITesting = false
            diagnostics["uiTestSharedSourceMiss"] = "forced_once"
            return nil
        }
        return SharedPacketItemMatcher.matchingItemId(
            for: itemIdentity, among: try store.listItems(), ownedAudiobookDigest: localAudiobookDigest(for:))
    }

    private func localAudiobookDigest(for item: Item) -> String? {
        item.mediaType == "audiobook" ? SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: (try? store?.loadOwnedOfflineAssets()) ?? []) : nil
    }

    private func normalizedSharingURL(_ value: String?) -> String? {
        SharedItemIdentityBuilder.normalizedSharingURL(value)
    }

    func handleIncomingURL(_ url: URL) {
        if let marginLink = MarginDeepLink(url: url) { openMargin(marginLink); return }
        if url.isFileURL, url.pathExtension.lowercased() == "json" {
            importListeningEditionFile(url); return
        }
        if url.scheme == "spokenmargins", url.host == "listening-edition" {
            do {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                importListeningEditionFile(try ListeningEditionStore.stagedFile(id: id))
            } catch { reportFailure(error, context: "Listening edition handoff failed") }
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == SpokenMarginsPackageArchive.fileExtension {
            stageSpokenMarginsPackageImport(from: url)
            return
        }
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
                    if hasActiveSession {
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
    func handleGate2CompactApplicationCommand(_ command: String, targetID: String? = nil) -> Bool {
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
        case Gate2CompactApplicationCommand.listenToSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            listenToPendingImportedCommentary()
            screen = .playback
            return true
        case Gate2CompactApplicationCommand.dismissSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            dismissPendingImportedCommentary()
            return true
        case Gate2CompactApplicationCommand.jumpToSharedMargin:
            guard let targetID, !targetID.isEmpty else { return false }
            return jumpToImportedCommentary(interjectionID: targetID)
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
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
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
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(renderedSpeechCacheLimitMB, forKey: "renderedSpeechCacheLimitMB")
        cancelTextAudioPrewarmTasks()
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsVoiceSelection"] = ttsVoiceSelection.rawValue
        diagnostics["ttsMode"] = ttsMode
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
        diagnostics["speechTranscriptionEngine"] = systemSpeechTranscriptionEngineDescription()
    }

    func refreshSpeechVoiceOptions() {
        speechVoiceOptions = Self.availableSpeechVoiceOptions()
        diagnostics["speechVoiceCount"] = "\(speechVoiceOptions.count)"
        diagnostics["speechVoice"] = speechVoiceDescription
        let selected = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.supportsSpeechVoiceEnumeration {
            diagnostics["speechVoiceAvailability"] = "system_default_on_simulator"
        } else {
            diagnostics["speechVoiceAvailability"] = selected.isEmpty || speechVoiceOptions.contains(where: { $0.id == selected })
                ? "available"
                : "unavailable"
        }
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["renderedSpeechCacheLimitMB"] = String(renderedSpeechCacheLimitMB)
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
        hasActiveSession && !isDismissingMiniPlayer && screen != .playback && snapshot.phase != .finished && snapshot.phase != .abandoned
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

    var canPlayLiveSpeechInstead: Bool {
        pendingPreparedTextStartItemId == activeItemId
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
            return String(format: "Supertonic %.2fx", speechPlaybackRateMultiplier)
        }
        return String(format: "System %.2fx", speechPlaybackRateMultiplier)
    }

    var speechPlaybackRateMultiplier: Double {
        SpeechRateRule.quarterStepMultiplier(speechRate / 0.5)
    }

    var compactPlaybackRateDescription: String {
        if isMediaPlaybackSnapshot {
            return String(format: "%.2f×", mediaPlaybackRate)
        }
        return String(format: "%.2f×", speechPlaybackRateMultiplier)
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

    var hasConfiguredProviderAPIKey: Bool {
        !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var preparedTextAudioStatusDescription: String {
        PlaybackStatusWording.humanReadableStatus(preparedTextAudioStatus)
    }

    var shouldShowOnDeviceSpeechGenerationStatus: Bool {
        Self.supportsOnDeviceSpeechGenerationStatus(targetType: snapshot.targetType)
            && ttsVoiceSelection.supertonicVoice != nil
            && onDeviceSpeechGenerationStatus != RenderedSpeechGenerationState.inactive.rawValue
    }

    static func supportsOnDeviceSpeechGenerationStatus(targetType: String?) -> Bool {
        PlaybackStatusWording.supportsOnDeviceSpeechGenerationStatus(targetType: targetType)
    }

    var canStopOnDeviceSpeechGeneration: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var isOnDeviceSpeechGenerating: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var canRetryOnDeviceSpeechGeneration: Bool {
        guard speechPlaybackClient is SupertonicSpeechPlaybackClient, snapshot.targetId != nil, snapshot.sessionId != nil else { return false }
        return onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.stopped.rawValue
            || preparedTextAudioStatus == "failed"
    }

    func retryOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
              let targetId = snapshot.targetId,
              let sessionId = snapshot.sessionId else {
            reportFailure("There is no current Supertonic response to retry.")
            return
        }
        let itemId = snapshot.itemId
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let coordinator = self.preparedAudioCoordinator,
                   let signature = self.currentSupertonicRenderSignature {
                    try await coordinator.retry(itemId: targetId, signature: signature)
                }
                guard self.snapshot.sessionId == sessionId, self.snapshot.targetId == targetId else { return }
                if let itemId { self.allowAudioPreparation(itemId: itemId) }
                guard try client.retryOnDeviceRendering() else { return }
                self.speechFallbackReason = nil
                self.preparedTextAudioStatus = "preparing"
                self.diagnostics["onDeviceSpeechGeneration"] = "retry_current_target"
                self.reportConfirmation("Retrying Supertonic at the current position.")
            } catch {
                self.reportFailure(error, context: "Prepared audio retry failed", itemId: itemId)
            }
        }
    }

    var onDeviceSpeechGenerationStatusDescription: String {
        (RenderedSpeechGenerationState(rawValue: onDeviceSpeechGenerationStatus) ?? .inactive).listenerDescription(
            progress: onDeviceSpeechGenerationProgress, isDelayed: isOnDeviceSpeechGenerationDelayed,
            stopReason: onDeviceSpeechGenerationStopReason, fallbackReason: speechFallbackReason
        )
    }

    func updateOnDeviceSpeechGenerationState(_ state: RenderedSpeechGenerationState, stopReason: String?) {
        if onDeviceSpeechGenerationStatus != state.rawValue { onDeviceSpeechGenerationStatus = state.rawValue }
        if onDeviceSpeechGenerationStopReason != stopReason { onDeviceSpeechGenerationStopReason = stopReason }
        // Rendering, ready or idle: the iOS voice isn't standing in, so an old reason is stale (#314).
        if state != .stopped, speechFallbackReason != nil { speechFallbackReason = nil }
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        diagnostics["onDeviceSpeechGeneration"] = state.rawValue
        diagnostics["onDeviceSpeechGenerationStopReason"] = stopReason
        guard state != .rendering else { return }
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        isOnDeviceSpeechGenerationDelayed = false
        if state == .inactive {
            onDeviceSpeechGenerationProgress = RenderedSpeechGenerationProgress(
                completedChunks: 0,
                totalChunks: 0
            )
        }
    }

    private func updateOnDeviceSpeechGenerationProgress(_ progress: RenderedSpeechGenerationProgress) {
        guard onDeviceSpeechGenerationProgress != progress else { return }
        onDeviceSpeechGenerationProgress = progress
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        isOnDeviceSpeechGenerationDelayed = false
        diagnostics["onDeviceSpeechGenerationProgress"] = "\(progress.completedChunks)/\(progress.totalChunks)"
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        guard progress.completedChunks < progress.totalChunks else { return }
        onDeviceSpeechGenerationDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self,
                  self.onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue,
                  self.onDeviceSpeechGenerationProgress == progress else { return }
            self.isOnDeviceSpeechGenerationDelayed = true
            self.diagnostics["onDeviceSpeechGenerationDelay"] = "chunk_\(progress.completedChunks + 1)_over_45s"
        }
    }

    var sourceTranscriptStatusDescription: String {
        PlaybackStatusWording.humanReadableStatus(sourceTranscriptStatus)
    }

    var currentChapter: Chapter? {
        PlaybackChapterLocator.currentChapter(playbackChapterContext)
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
            } applicationCommandHandler: { [weak self] command, targetID in
                self?.handleGate2CompactApplicationCommand(command, targetID: targetID) ?? false
            }
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
            updateGate2CompactState()
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
        } catch {
            diagnostics["gate2CompactSurface"] = "configuration_failed"
            diagnostics["gate2CompactError"] = String(describing: error)
        }
    }

    private func updateGate2CompactState() {
        // The source Live Activity cannot describe the separate Margin player.
        // Its native Now Playing owner supplies transport until source restoration.
        guard playingImportedCommentary == nil else { return }
        let sharedMarginPrompt = pendingImportedCommentary.map {
            Gate2SharedMarginActivityPrompt(
                senderLabel: $0.senderLabel
            )
        }
        gate2CompactControls.update(
            snapshot: snapshot, sharedMarginPrompt: sharedMarginPrompt, upcomingSharedMargins: liveActivitySharedMarginNavigationEntries(),
            skimForwardDestinationMs: skimForwardDestinationMs, skimBackwardDestinationMs: skimBackwardDestinationMs // #115
        )
        let compactSnapshot = gate2CompactControls.snapshot
        if gate2CompactSnapshot != compactSnapshot {
            gate2CompactSnapshot = compactSnapshot
        }
        let compactDiagnostics = gate2CompactControls.diagnostics()
        if compactDiagnostics.contains(where: { diagnostics[$0.key] != $0.value }) {
            diagnostics.merge(compactDiagnostics, uniquingKeysWith: { _, new in new })
        }
    }

    private func liveActivitySharedMarginNavigationEntries() -> [Gate2LiveActivityNavigationEntry] {
        let currentPercent = snapshot.sourceProgressPercent
        let mediaDurationMs = snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs
        let textLength = selectedItem.text.count
        return importedCommentaryPrompts(includeAnnounced: false).compactMap { prompt in
            let positionPercent = SharedMarginPosition.percent(
                mediaTimeMs: prompt.interjection.resolution.localMediaTimeMs,
                mediaDurationMs: mediaDurationMs,
                charOffset: prompt.interjection.resolution.localStartChar,
                textLength: textLength
            )
            guard let positionPercent,
                  positionPercent > currentPercent else { return nil }
            return Gate2LiveActivityNavigationEntry(
                kind: .sharedMargin,
                title: "Shared Margin",
                targetID: prompt.interjection.id,
                positionPercent: min(100, max(0, positionPercent))
            )
        }
    }

    private func performGate2CompactCommand(
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
        if command == .beginInterjection, !snapshot.isRecording, snapshot.skimBridgeState == nil,
           !handOffPlayingMarginToRecording() { return }
        if playingImportedCommentary != nil {
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
        if command == .beginInterjection || canonicalTransportCommands.contains(command) {
            synchronizeStreamingSpeechAnchorIfNeeded()
        }
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
                recordingPresentationContext = RecordingPresentationContext(
                    itemTitle: selectedItem.title,
                    locationTitle: snapshot.chapterTitle ?? "Current listening position",
                    progressPercent: snapshot.currentPlaybackProgressPercent,
                    startedAt: Date()
                )
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
                    recordingPresentationContext = nil
                    refreshMarginRows()
                }
            }
            if canonicalTransportCommands.contains(command) {
                streamingSpeechQueue.relinquishToCanonicalPlayback()
            }
            reportSuccess("Compact control \(command.rawValue) \(result.delegatedToCanonicalRuntime ? "delegated" : "handled").")
            if command == .finishInterjection, captureVerdict == .saveCutShort { reportMarginSaved(captureVerdict) }
        } catch {
            if command == .finishInterjection { recordSpokenMarginSavedBeforeFailure(engine?.lastScheduledTranscriptionInterjectionId) }
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

    @Published private(set) var renderedSourceFraction: Double?
    private var frontierSignatures: [String: TTSRenderSignature] = [:]
    private var frontierPublicationKey: String?
    var renderedFractionForPlayback: Double? {
        guard frontierPublicationKey == renderFrontierKey else { return nil }
        if ttsVoiceSelection.supertonicVoice != nil,
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
              let store, let resources = Bundle.main.resourceURL else { return }
        do {
            let signature: TTSRenderSignature
            if let cached = frontierSignatures[voice.rawValue] { signature = cached }
            else {
                let assets = SupertonicAssetLocation(rootURL: resources.appendingPathComponent("Supertonic"))
                let existing = currentSupertonicRenderSignature
                signature = try await Task.detached(priority: .utility) {
                    if let existing,
                       existing.voiceStyleHash == SupertonicRenderIdentity.sha256(try Data(contentsOf: assets.voiceStyleURL(for: voice))) { return existing }
                    return try SupertonicRenderIdentity.make(assets: assets, voice: voice)
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

    func openReadyListeningEdition() {
        guard !snapshot.isRecording, let id = ListeningReadyNotifications.pendingItemID else { return }
        ListeningReadyNotifications.pendingItemID = nil
        openItem(id: id)
    }
    private func activateListeningEditionAudio(itemId: String, timeline: TranscriptTimeline) {
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
    func importListeningEditionData(_ data: Data, replaceMap: Bool = false) {
        do {
            try performListeningEditionImport(data, replaceMap: replaceMap)
        } catch { reportFailure(error, context: "Listening edition import failed") }
    }

    func importListeningEditionDataForShortcut(_ data: Data) throws {
        try performListeningEditionImport(data, replaceMap: false)
    }

    private func performListeningEditionImport(_ data: Data, replaceMap: Bool) throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        let edition = try ListeningEdition.decode(data)
        let editions = try ListeningEditionStore.application()
        if let previous = try editions.load(itemID: edition.itemID), previous != edition, !replaceMap {
            throw EditionError.invalid("This source already has a different Listening Map. Use Import Listening Edition in Settings to preview and explicitly replace it.")
        }
        let store = try requireStore()
        // Stable source identity preserves every existing session and Margin on retry.
        if (try? store.loadItem(id: edition.itemID)) == nil {
            try store.saveItem(Item(id: edition.itemID, title: edition.title, mediaType: "text", text: edition.text,
                                   externalReference: edition.sourceURL, status: "ready", externalReferenceType: "url", createdAt: Date()))
        }
        if snapshot.itemId == edition.itemID, snapshot.status.isPlaybackActive {
            throw EditionError.invalid("Pause playback before importing a map for the current item.")
        }
        try editions.save(edition)
        if let engine { snapshot = try engine.attachListeningMap(edition.listeningMap()) }
        else { try store.saveListeningMap(edition.listeningMap()) }
        if let timeline = try store.loadTranscriptTimeline(itemId: edition.itemID)?.timeline {
            activateListeningEditionAudio(itemId: edition.itemID, timeline: timeline)
        }
        activeItemId = edition.itemID
        libraryItems = try loadLibraryRows(store: store)
        refreshSelectedItem()
        screen = .item
        scheduleTextAudioPrewarmIfNeeded(itemId: edition.itemID)
        reportConfirmation("Imported item and Listening Map. Audio prepares separately; playback has not started.")
    }

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

    func automaticMarginOutputChanged() {
        UserDefaults.standard.set(automaticMarginOutputEnabled, forKey: "automaticMarginOutputEnabled")
        if automaticMarginOutputEnabled { marginNotesDelivery.start() }
        else { marginNotesDelivery.stop(); marginOutputStatus = MarginOutputStatus("Automatic delivery is off. Exported files remain in your folder.") }
    }

    func testMarginOutput() {
        Task {
            do {
                guard let folder = resolvedFolderURL(.marginNotes) else { throw EditionError.invalid("Choose an output folder first.") }
                marginOutputStatus = try await marginNotesDelivery.sendTestNote(to: folder, destinationID: marginOutputDestinationID)
            } catch { marginOutputStatus = .failure(error.localizedDescription) }
        }
    }

    private var marginOutputDestinationID: String {
        UserDefaults.standard.string(forKey: "marginOutputDestinationID") ?? "initial"
    }
    private func marginNotesTarget() throws -> MarginNotesDelivery.Target {
        guard let store, let folder = resolvedFolderURL(.marginNotes) else { throw EditionError.invalid("Choose or reselect an output folder. Your Margins remain safely in the Library.") }
        return .init(store: store, folder: folder, destinationID: marginOutputDestinationID)
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

    func deliverAutomaticMargins() async { await marginNotesDelivery.pass() }

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
            try operation(engine)
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    private func previewSpeech(label: String, mode: AppSpeechPreviewMode) {
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

    #if canImport(AVFoundation)
    private func stopSpeechPreviews() {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
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

    #else
    private func stopSpeechPreviews() {}
    #endif

    func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
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
            foregroundAudioPreparationTask?.cancel()
            foregroundAudioPreparationGeneration += 1
            foregroundAudioPreparationTask = nil
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

    private func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
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
            recorder: recordingClientOverride ?? SystemRecordingClient(),
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

    private func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
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
            guard shouldPrewarmTextAudio(for: item), let text = item.text, PreparedSpeechHooks.preparedText(of: item, in: store) == text else { return }
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
        rows.filter { !$0.isCompleted && $0.startupAudioState != .ready }
            .sorted {
                let lhsDate = $0.addedAt ?? .distantPast
                let rhsDate = $1.addedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if $0.storageRecencyRank != $1.storageRecencyRank { return $0.storageRecencyRank < $1.storageRecencyRank }
                return $0.id < $1.id
            }
            .map(\.id)
    }

    private func scheduleStartupAudioPreparationIfNeeded(itemId: String) {
        guard audioPlaybackClientOverride == nil,
              hasAcceptedCurrentTerms,
              ttsVoiceSelection.supertonicVoice != nil,
              !suppressedAutomaticAudioPreparationItemIds.contains(itemId),
              !liveSpeechFallbackItemIds.contains(itemId),
              !pendingStartupAudioPreparationItemIds.contains(itemId),
              libraryItems.first(where: { $0.id == itemId })?.startupAudioState != .ready else {
            return
        }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard item.sourceCompletedAt == nil,
                  !PreparationChunkGate.itemAlreadyListened(try store.loadSessions(itemId: itemId)),
                  shouldPrewarmTextAudio(for: item),
                  item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            pendingStartupAudioPreparationItemIds.insert(itemId)
            failedStartupAudioPreparationItemIds.remove(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .waiting)
            diagnostics["startupAudioPreparation:\(itemId)"] = "queued"
            Task { @MainActor [weak self] in
                await self?.enqueueStartupAudioPreparation(itemId: itemId)
            }
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            diagnostics["startupAudioPreparation:\(itemId)"] = "enqueue_failed:\(error.localizedDescription)"
        }
    }

    private func enqueueStartupAudioPreparation(itemId: String) async {
        defer { pendingStartupAudioPreparationItemIds.remove(itemId) }
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard item.sourceCompletedAt == nil,
                  !PreparationChunkGate.itemAlreadyListened(try store.loadSessions(itemId: itemId)),
                  let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store),
                  shouldPrewarmTextAudio(for: item),
                  let voice = ttsVoiceSelection.supertonicVoice,
                  let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                updateLibraryStartupAudioState(itemId: itemId, state: .notRequired)
                return
            }
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            guard !plan.isEmpty else {
                updateLibraryStartupAudioState(itemId: itemId, state: .notRequired)
                return
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            try Task.checkCancellation()
            let support = try applicationSupportDirectory()
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            currentSupertonicRenderSignature = signature
            let manifest = try await coordinator.begin(
                itemId: item.id,
                sourceText: sourceText,
                signature: signature,
                plan: plan
            )
            let targetChunkCount = min(Self.startupAudioChunkCount, plan.count)
            if manifest.chunks.count < targetChunkCount {
                var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                    ?? AudioPreparationJob(
                        id: "job-\(manifest.id)",
                        itemId: item.id,
                        manifestId: manifest.id,
                        policy: .demandWindow
                    )
                if job.policy == .demandWindow {
                    job.requestedAt = item.createdAt ?? job.requestedAt
                    job.maximumChunkCount = targetChunkCount
                }
                job.isCancelled = false
                job.lastFailureCode = nil
                try store.saveAudioPreparationJob(job)
                diagnostics["startupAudioPreparation:\(itemId)"] = "queued_0_of_\(targetChunkCount)"
            } else if let job = try store.loadAudioPreparationJobs().first(where: {
                $0.manifestId == manifest.id && $0.policy == .demandWindow && $0.maximumChunkCount != nil
            }) {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["startupAudioPreparation:\(itemId)"] = "ready_from_cache"
            }
            try refreshLibraryRows(store: store)
            startForegroundAudioPreparationIfNeeded()
        } catch is CancellationError {
            diagnostics["startupAudioPreparation:\(itemId)"] = "cancelled"
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            diagnostics["startupAudioPreparation:\(itemId)"] = "failed:\(error.localizedDescription)"
        }
    }

    private func updateLibraryStartupAudioState(itemId: String, state: NativeTextStartupAudioState) {
        guard let index = libraryItems.firstIndex(where: { $0.id == itemId }),
              libraryItems[index].startupAudioState != state else { return }
        libraryItems[index].startupAudioState = state
    }

    @discardableResult
    private func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready",
        replaceActivePlayback: Bool = false
    ) -> Bool {
        do {
            let shouldAutoStart = pendingPreparedTextStartItemId == itemId
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

    private func shouldPrewarmTextAudio(for item: Item) -> Bool {
        guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !LibraryAudioPreparationAdmission.playsItsOwnAudio(item) else { return false }
        guard item.media?.sourceType == .generatedTTSPrerendered else { return true }
        return PreparedNarrationFallback.isMissing(item.media) || isStarterPreparedTextMedia(item.media)
    }

    private func isStarterPreparedTextMedia(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
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

    private func removeEpisodeMapArtifacts(itemId: String) {
        if snapshot.itemId == itemId, snapshot.skimBridgeState != nil {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        }
        if episodeMapPreparationItemId == itemId {
            episodeMapPreparationTask?.cancel()
        }
        if let directory = try? episodeMapDirectory(itemId: itemId),
           FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try? purgeTransientEpisodeTranscriptionCaches(itemId: itemId)
        for job in (try? store?.loadEpisodeMapPreparationJobs()) ?? [] where job.itemId == itemId {
            try? store?.deleteEpisodeMapPreparationJob(id: job.id)
        }
    }

    private func purgeExpiredEpisodeMapPreparationJobs(store: SQLiteSessionStore, now: Date = Date()) {
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
            reportFailure(error, context: "Prepare text playback failed", itemId: itemId)
            return true
        }
    }

    private func shouldGatePreparedTextPlayback(for item: Item) -> Bool {
        guard (audioPlaybackClientOverride == nil || forcePreparedTextGate),
              ttsVoiceSelection == .system,
              !liveSpeechFallbackItemIds.contains(item.id),
              shouldPrewarmTextAudio(for: item) else {
            return false
        }
        if item.media?.sourceType == .generatedTTSPrerendered {
            return false
        }
        return true
    }

    private func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        if let audioPlaybackClientOverride {
            diagnostics["sessionTTS"] = "Test audio override"
            try configureAudioPlaybackPolicy(audioPlaybackClientOverride)
            sessionAudioPlaybackClient = audioPlaybackClientOverride
            return audioPlaybackClientOverride
        }
        sanitizeTTSMode()
        let speech = try makeSpeechPlaybackClient()
        speechPlaybackClient = speech
        let routed = RoutedAudioPlaybackClient(
            speech: speech,
            media: makeMediaPlaybackClient()
        )
        try configureAudioPlaybackPolicy(routed)
        sessionAudioPlaybackClient = routed
        streamingSpeechQueue.configureSpeechClient(routed)
        return routed
    }

    private func configureAudioPlaybackPolicy(_ audio: AudioPlaybackClient) throws {
        try audio.setMixesWithOtherAudio(mixesWithOtherAudio)
        try audio.setLowersBackgroundAudio(mixesWithOtherAudio && lowersBackgroundAudio)
        try audio.setPlaybackVolume(mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1)
        audio.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
    }

    private func makeSpeechPlaybackClient() throws -> AudioPlaybackClient {
        let selectedVoice = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let appleVoiceIsAvailable = !Self.supportsSpeechVoiceEnumeration
            || selectedVoice.isEmpty
            || Self.availableSpeechVoiceOptions().contains(where: { $0.id == selectedVoice })
        if ttsVoiceSelection == .system, !appleVoiceIsAvailable {
            diagnostics["speechVoiceAvailability"] = "unavailable"
            throw SessionKitError.persistenceFailed("selected_speech_voice_unavailable")
        }
        if let voice = ttsVoiceSelection.supertonicVoice {
            let renderer = try makeSupertonicRenderer()
            let supportDirectory = try applicationSupportDirectory()
            guard let store else { throw SessionKitError.persistenceFailed("prepared_audio_store_unavailable") }
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                throw SupertonicNarrationError.missingAsset("Supertonic")
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signatureTask = Task.detached(priority: .userInitiated) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }
            let coordinator = PreparedAudioCoordinator(
                repository: store,
                rootDirectory: supportDirectory.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            let hooks = PreparedSpeechHooks(store: store, coordinator: coordinator, signatureTask: signatureTask) // #336
            Task { [weak self] in
                guard let signature = try? await signatureTask.value,
                      let self, self.ttsVoiceSelection.supertonicVoice == voice else { return }
                self.currentSupertonicRenderSignature = signature
            }
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
                renderer: supertonicOutputGuard(wrapping: renderer, systemVoice: selectedVoice),
                voice: voice,
                speed: Float(speechRate / 0.5),
                fallbackVoiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
                fallbackRate: Float(speechRate),
                diskCache: diskCache,
                preparedAudioDirectory: supportDirectory.appending(
                    path: "PreparedSupertonicAudio",
                    directoryHint: .isDirectory
                ),
                interruptionHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleSpeechPlaybackInterruption(event)
                    }
                },
                onGenerationStateChange: { [weak self] state, stopReason in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationState(state, stopReason: stopReason)
                    }
                },
                onGenerationProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationProgress(progress)
                    }
                },
                onPreparationPlan: { await hooks.planned(itemId: $0, articleIdentity: $1, plan: $2) },
                onPreparedChunk: { await hooks.rendered(itemId: $0, articleIdentity: $1, plan: $2, audioURL: $3, durationMs: $4, engine: $5) },
                articleText: { hooks.articleText(itemId: $0) },
                preparedChunkLookup: { await hooks.lookup(itemId: $0, articleIdentity: $1, plan: $2) },
                onPreparedAudio: { [weak self] itemId, prepared in
                    Task { @MainActor [weak self] in
                        guard let signature = try? await signatureTask.value, let self else { return }
                        guard let store = self.store,
                              let item = try? store.loadItem(id: itemId),
                              let canonical = prepared.canonicalized(toItemText: item.text) else {
                            self.diagnostics["supertonicPreparedCanonicalization:\(itemId)"] = "source_mismatch"
                            return
                        }
                        let attached = self.attachPreparedTextAudio(
                            canonical,
                            itemId: itemId,
                            preparedStatus: "ready",
                            diagnosticStatus: "supertonic_full_ready",
                            replaceActivePlayback: false
                        )
                        if attached {
                            try? await coordinator.complete(itemId: itemId, signature: signature, prepared: canonical)
                        }
                        if attached, let renderer = self.supertonicRenderer {
                            Task { [weak self] in
                                await renderer.unload(removingGeneratedAudio: false)
                                await MainActor.run { [weak self] in
                                    self?.diagnostics["supertonicRuntimeAfterFullAudio"] = "unloaded"
                                }
                            }
                        }
                    }
                },
                onFallback: { [weak self] reason, offset, itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.suppressAudioPreparation(itemId: itemId)
                        if let coordinator = self.preparedAudioCoordinator,
                           let signature = self.currentSupertonicRenderSignature {
                            try? await coordinator.stop(itemId: itemId, signature: signature)
                        }
                        // I14: the reason is shown and logged with the power state beside it,
                        // so a device report shows whether charging or Low Power Mode coincided.
                        let conditions = self.currentResourceConditions()
                        let fallbackReason = SpeechFallbackReason(
                            supertonicCode: reason,
                            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
                        )
                        self.recordSupertonicFallbackEvent(code: reason, reason: fallbackReason, conditions: conditions, offset: offset)
                        self.speechFallbackReason = fallbackReason
                        self.diagnostics["supertonicFallback"] = reason
                        self.diagnostics["supertonicFallbackReason"] = fallbackReason.rawValue
                        self.diagnostics["supertonicFallbackConditions"] = conditions.logDescription
                        self.diagnostics["supertonicFallbackOffset"] = "\(offset)"
                        let message = fallbackReason.listenerExplanation
                        self.statusMessage = message
                        self.presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
                    }
                },
                onRestore: { [weak self] itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.speechFallbackReason = nil
                        self.allowAudioPreparation(itemId: itemId)
                        self.diagnostics["supertonicFallbackRestored"] = itemId
                    }
                },
                onStall: { [weak self] kind, fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic(kind, fields) } },
                onSystemPause: { [weak self] kind, fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic(kind, fields) } },
                onResumeDecision: { [weak self] fields in Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic("supertonic.resume", fields) } },
                onRenderPace: { [weak self] summary in Task { @MainActor [weak self] in self?.diagnostics["onDeviceRenderPace"] = summary } },
                handOverHold: handOverBackgroundHold
            )
        }
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

    /// #240: chunks that fail the output check are read by the iOS voice; diagnostics say so.
    private func supertonicOutputGuard(wrapping renderer: SupertonicRendering, systemVoice: String) -> SupertonicOutputGuard {
        let voice = systemVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        return SupertonicOutputGuard(wrapping: renderer, systemVoiceIdentifier: voice.isEmpty ? nil : voice) { [weak self] summary in
            Task { @MainActor [weak self] in self?.diagnostics["supertonicOutputCheck"] = summary }
        }
    }

    private func makeMediaPlaybackClient() -> AudioPlaybackClient {
        let client = AVPlayerStreamPlaybackClient(
            preferredSkipBackSeconds: mediaSkipBackSeconds,
            preferredSkipForwardSeconds: mediaSkipForwardSeconds,
            interruptionHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleMediaPlaybackInterruption(event)
                }
            }
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
        client.playbackStartTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #160: resume after a spoken Margin on a stream took 2.6-9.3 s; this shows where the time goes.
                self?.recordDeveloperDiagnostic("media.start", fields)
            }
        }
        client.heardSourceWindowHandler = { [weak self] window in
            Task { @MainActor [weak self] in self?.handleHeardSourceWindow(window) }
        }
        client.playbackStallTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #166: the clock froze on a stream while the app showed "playing"; this records the player's state.
                self?.recordDeveloperDiagnostic(fields["event"] == "seek_abandoned" ? "media.seek_abandoned" : "media.stall", fields)
            }
        }
        #if canImport(AVFoundation) && canImport(ShazamKit)
        client.postResumePodcastEvidenceHandler = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePostResumePodcastEvidence(result)
            }
        }
        #endif
        mediaPlaybackClient = client
        return client
    }

    private func handleMediaPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "resume_skipped"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "resume_failed:\(error.localizedDescription)"
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
    }

    private func handleSpeechPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            // Counted so a device report can show whether chunk-boundary pauses (#183) come
            // from audio interruptions.
            diagnostics["speechPlaybackInterruptionCount"] = "\(Int(diagnostics["speechPlaybackInterruptionCount"] ?? "0").map { $0 + 1 } ?? 1)"
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["speechPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItem()
                diagnostics["speechPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                noteSpeechInterruptionResume(.skipped)
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                noteSpeechInterruptionResumeReturned()
            } catch {
                noteSpeechInterruptionResume(.failed(reason: error.localizedDescription))
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
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
        libraryRows(from: try LibraryReadSnapshot.read(store: store))
    }

    private func libraryRows(from data: LibraryReadSnapshot) -> [LibraryItemRow] {
        let items = data.items.filter { $0.deletedAt == nil }
        let sessionsByItemId = Dictionary(grouping: data.sessions, by: \.itemId)
        let manifestsByItemId = Dictionary(grouping: data.manifests, by: \.itemId)
        let preparationJobsByManifestId = Dictionary(
            grouping: data.jobs.filter { !$0.isCancelled },
            by: \.manifestId
        ).compactMapValues { jobs in
            jobs.max { $0.requestedAt < $1.requestedAt }
        }
        let podcastDownloadsByItemId = Dictionary(
            grouping: data.downloads,
            by: \.itemId
        ).compactMapValues { records in
            records.max { $0.updatedAt < $1.updatedAt }
        }
        return items.enumerated().map { storageRank, item in
            let sessions = sessionsByItemId[item.id] ?? []
            let continuation = Self.preferredContinuationSession(in: sessions)
            let isCompleted = item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(sessions)
            let compatibleManifests = manifestsByItemId[item.id]?.filter { manifest in
                currentSupertonicRenderSignature.map { manifest.signature == $0 } ?? true
            }
            let latestManifest = compatibleManifests?.max { $0.updatedAt < $1.updatedAt }
            let preparationJob = latestManifest.flatMap { preparationJobsByManifestId[$0.id] }
            let startupAudio: (state: NativeTextStartupAudioState, completed: Int, target: Int) = isCompleted ? (.notRequired, 0, 0) : libraryStartupAudioPresentation(
                item: item,
                manifest: latestManifest,
                job: preparationJob
            )
            let effectivePreparedState: PreparedAudioState? = {
                guard [.preparing, .pausedForThermal].contains(latestManifest?.state), preparationJob == nil else { // no job left: nothing will resume it
                    return latestManifest?.state
                }
                return .notPrepared
            }()
            let offlineState = LibraryOfflineStateFilter.forItem(
                preparedState: effectivePreparedState,
                mediaSourceType: item.media?.sourceType,
                podcastDownloadState: podcastDownloadsByItemId[item.id]?.state
            )
            var row = LibraryItemRow(
                id: item.id,
                title: item.title,
                status: libraryStatusLabel(for: item),
                canDelete: true,
                hasContinuationSession: continuation != nil,
                continuationProgressPercent: continuation?.completionPercent,
                isCompleted: isCompleted,
                mediaType: item.mediaType,
                hasNativeAudio: item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream,
                sourceTitle: item.sourceTitle ?? item.externalReference,
                sourceURL: item.sourceURL,
                author: item.author,
                sourceReference: item.externalReference,
                sourceReferenceType: item.externalReferenceType,
                offlineState: offlineState,
                startupAudioState: startupAudio.state,
                startupAudioCompletedChunkCount: startupAudio.completed,
                startupAudioTargetChunkCount: startupAudio.target,
                addedAt: item.createdAt,
                lastListenedAt: sessions.compactMap { $0.updatedAt ?? $0.createdAt }.max(),
                storageRecencyRank: storageRank
            )
            row.usesNewReader = data.structuredDocumentItemIds.contains(item.id)
            row.canMarkUnfinished = item.sourceCompletedAt != nil && !PreparationChunkGate.itemAlreadyListened(sessions)
            row.textCharacterCount = row.hasNativeAudio ? nil : ListeningTimeEstimator.characterCount(of: item.text)
            return row
        }
    }

    func libraryStartupAudioPresentation(
        item: Item,
        manifest: PreparedAudioManifest?,
        job: AudioPreparationJob?
    ) -> (state: NativeTextStartupAudioState, completed: Int, target: Int) {
        guard hasAcceptedCurrentTerms,
              ttsVoiceSelection.supertonicVoice != nil,
              !suppressedAutomaticAudioPreparationItemIds.contains(item.id),
              !liveSpeechFallbackItemIds.contains(item.id),
              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return (.notRequired, 0, 0)
        }
        if item.media?.sourceType == .generatedTTSPrerendered,
           !PreparedNarrationFallback.isMissing(item.media),
           !isStarterPreparedTextMedia(item.media) {
            return (.ready, Self.startupAudioChunkCount, Self.startupAudioChunkCount)
        }
        guard shouldPrewarmTextAudio(for: item) else { return (.notRequired, 0, 0) }
        let inTurn: NativeTextStartupAudioState = [libraryAudioPreparingItemId, snapshot.status.isPlaybackActive ? activePlaybackItemId : nil].contains(item.id) ? .preparing : .waiting // a paused session isn't prepared
        guard let manifest else {
            return failedStartupAudioPreparationItemIds.contains(item.id)
                ? (.failed, 0, Self.startupAudioChunkCount)
                : (inTurn, 0, Self.startupAudioChunkCount)
        }
        let target = min(Self.startupAudioChunkCount, max(1, manifest.plannedChunkCount))
        let completed = min(target, manifest.chunks.filter { $0.index < target }.count)
        if manifest.state == .readyOffline || completed >= target {
            return (.ready, completed, target)
        }
        if failedStartupAudioPreparationItemIds.contains(item.id)
            || job?.lastFailureCode?.isEmpty == false
            || manifest.state == .failed
            || manifest.state == .needsRepreparation
            || manifest.state == .stopped {
            return (.failed, completed, target)
        }
        if !SupertonicResourcePolicy.allowsRendering() { // live heat, not a stale pausedForThermal (#64)
            return (.paused, completed, target)
        }
        return (inTurn, completed, target)
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

    func applyPreparedChunkProgress(item: Item, manifest: PreparedAudioManifest, remainingJobs: [AudioPreparationJob]) {
        var manifest = manifest
        // Finishing the final chunk persists a terminal state and removes its
        // job. The caller's pre-finalization snapshot must not downgrade that
        // result. Intermediate chunks still avoid any persistence reload.
        if manifest.state == .preparing,
           manifest.chunks.count == manifest.plannedChunkCount,
           !remainingJobs.contains(where: { $0.manifestId == manifest.id && !$0.isCancelled }),
           let persisted = try? store?.loadPreparedAudioManifest(id: manifest.id) {
            manifest = persisted
        }
        let job = remainingJobs.first { $0.manifestId == manifest.id && !$0.isCancelled }
        if let index = libraryItems.firstIndex(where: { $0.id == item.id }), !libraryItems[index].isCompleted {
            let startup = libraryStartupAudioPresentation(item: item, manifest: manifest, job: job)
            var row = libraryItems[index]
            row.startupAudioState = startup.state
            row.startupAudioCompletedChunkCount = startup.completed
            row.startupAudioTargetChunkCount = startup.target
            row.offlineState = LibraryOfflineStateFilter.forItem(
                preparedState: [.preparing, .pausedForThermal].contains(manifest.state) && job == nil ? .notPrepared : manifest.state,
                mediaSourceType: item.media?.sourceType, podcastDownloadState: nil)
            if row != libraryItems[index] { libraryItems[index] = row }
        }
        let jobsByID = Dictionary(uniqueKeysWithValues: remainingJobs.filter { !$0.isCancelled }.map { ($0.id, $0) })
        let retained = audioPreparationQueue.filter { jobsByID[$0.id] != nil }.sorted {
            Self.audioPreparationJobPrecedes(jobsByID[$0.id]!, jobsByID[$1.id]!, activeItemId: activePlaybackItemId)
        }
        let rows = retained.enumerated().map { index, row in
            let current = row.id == job?.id
            let previous = index > 0 ? retained[index - 1] : nil
            let next = index + 1 < retained.count ? retained[index + 1] : nil
            let rowJob = jobsByID[row.id]!
            let pinned = row.itemId == activePlaybackItemId
            let sharesTier: (AudioPreparationQueueRow?) -> Bool = { neighbor in
                guard let neighbor, let neighborJob = jobsByID[neighbor.id] else { return false }
                return neighborJob.policy == rowJob.policy
                    && (neighborJob.maximumChunkCount != nil) == (rowJob.maximumChunkCount != nil)
                    && neighbor.itemId != self.activePlaybackItemId
            }
            return AudioPreparationQueueRow(
                id: row.id, itemId: row.itemId, title: row.title,
                policy: rowJob.policy,
                state: current ? manifest.state : row.state,
                completedChunkCount: current ? min(manifest.chunks.count, job?.maximumChunkCount ?? .max) : row.completedChunkCount,
                plannedChunkCount: current ? min(manifest.plannedChunkCount, job?.maximumChunkCount ?? .max) : row.plannedChunkCount,
                requestedAt: row.requestedAt, updatedAt: current ? manifest.updatedAt : row.updatedAt,
                failureCode: current ? job?.lastFailureCode : row.failureCode,
                isActivePlaybackItem: pinned,
                canMoveEarlier: !pinned && sharesTier(previous),
                canMoveLater: !pinned && sharesTier(next))
        }
        if audioPreparationQueue != rows { audioPreparationQueue = rows }
    }

    func refreshLibraryRows(store: SQLiteSessionStore) throws {
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = try loadDeletedLibraryRows(store: store)
        try refreshAudioPreparationPresentation(store: store)
    }

    func refreshAudioPreparationPresentation() {
        guard let store else { return }
        do {
            try refreshAudioPreparationPresentation(store: store)
        } catch {
            diagnostics["audioPreparationPresentation"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    private func refreshAudioPreparationPresentation(
        store: SQLiteSessionStore,
        announceNewCompletions: Bool = false,
        now: Date = Date()
    ) throws {
        let itemsById = Dictionary(uniqueKeysWithValues: try store.listItems().map { ($0.id, $0) })
        let manifests = try store.loadPreparedAudioManifests()
        let manifestsById = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        let activeItemId = activePlaybackItemId
        let storedJobs = try store.loadAudioPreparationJobs()
        let staleJobIds = Set(LibraryAudioPreparationAdmission.staleJobIds(
            storedJobs, items: Array(itemsById.values), sessionsByItemId: Dictionary(grouping: try store.loadSessions(), by: \.itemId)
        ))
        try store.deleteAudioPreparationJobs(ids: Array(staleJobIds))
        let jobs = storedJobs
            .filter { !$0.isCancelled && !staleJobIds.contains($0.id) }
            .sorted { lhs, rhs in
                Self.audioPreparationJobPrecedes(lhs, rhs, activeItemId: activeItemId)
            }

        audioPreparationQueue = jobs.enumerated().map { index, job in
            let manifest = manifestsById[job.manifestId]
            let previous = index > 0 ? jobs[index - 1] : nil
            let next = jobs.indices.contains(index + 1) ? jobs[index + 1] : nil
            let isPinnedActive = job.itemId == activeItemId
            let sharesTier: (AudioPreparationJob?) -> Bool = { neighbor in
                guard let neighbor else { return false }
                return neighbor.policy == job.policy
                    && (neighbor.maximumChunkCount != nil) == (job.maximumChunkCount != nil)
            }
            return AudioPreparationQueueRow(
                id: job.id,
                itemId: job.itemId,
                title: itemsById[job.itemId]?.title ?? job.itemId,
                policy: job.policy,
                state: manifest?.state ?? .failed,
                completedChunkCount: min(
                    manifest?.committedChunkCount ?? job.nextChunkIndex,
                    job.maximumChunkCount ?? manifest?.plannedChunkCount ?? .max
                ),
                plannedChunkCount: min(
                    manifest?.plannedChunkCount ?? job.maximumChunkCount ?? 0,
                    job.maximumChunkCount ?? .max
                ),
                requestedAt: job.requestedAt,
                updatedAt: manifest?.updatedAt ?? job.requestedAt,
                failureCode: job.lastFailureCode ?? manifest?.failureCode,
                isActivePlaybackItem: isPinnedActive,
                canMoveEarlier: !isPinnedActive && sharesTier(previous) && previous?.itemId != activeItemId,
                canMoveLater: !isPinnedActive && sharesTier(next) && next?.itemId != activeItemId
            )
        }

        var seenItemIds = Set<String>()
        recentlyPreparedAudio = manifests
            .filter { $0.state == .readyOffline && $0.artifact != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { manifest -> RecentlyPreparedAudioRow? in
                guard seenItemIds.insert(manifest.itemId).inserted else { return nil }
                return RecentlyPreparedAudioRow(
                    id: manifest.id,
                    itemId: manifest.itemId,
                    title: itemsById[manifest.itemId]?.title ?? manifest.itemId,
                    completedAt: manifest.updatedAt,
                    durationMs: manifest.artifact?.durationMs ?? 0
                )
            }
            .prefix(10)
            .map { $0 }

        guard announceNewCompletions else { return }
        let defaults = UserDefaults.standard
        let storedTimestamp = defaults.object(forKey: Self.lastPreparedAudioNoticeDateKey) as? Double
        let noticeBoundary = storedTimestamp.map(Date.init(timeIntervalSince1970:))
            ?? now.addingTimeInterval(-24 * 60 * 60)
        let newlyCompleted = recentlyPreparedAudio.filter { $0.completedAt > noticeBoundary }
        guard let newest = newlyCompleted.first else { return }
        defaults.set(newest.completedAt.timeIntervalSince1970, forKey: Self.lastPreparedAudioNoticeDateKey)
        let message: String
        if newlyCompleted.count == 1 {
            message = "Ready offline: \(newest.title)."
        } else {
            message = "Ready offline: \(newest.title) and \(newlyCompleted.count - 1) more. Review them in Preparing Audio."
        }
        reportConfirmation(message)
    }

    func moveAudioPreparationJobEarlier(id: String) {
        moveAudioPreparationJob(id: id, offset: -1)
    }

    func moveAudioPreparationJobLater(id: String) {
        moveAudioPreparationJob(id: id, offset: 1)
    }

    func skipAudioPreparationJob(id: String) {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs()
            guard let selected = jobs.first(where: { $0.id == id }) else { return }
            suppressAudioPreparation(itemId: selected.itemId)
            try store.deleteAudioPreparationJobs(
                ids: jobs.filter { $0.itemId == selected.itemId }.map(\.id)
            )
            pendingStartupAudioPreparationItemIds.remove(selected.itemId)
            failedStartupAudioPreparationItemIds.remove(selected.itemId)
            try refreshLibraryRows(store: store)
            diagnostics["audioPreparationSuppressed:\(selected.itemId)"] = "user"
            reportConfirmation("Removed \(itemsTitle(itemId: selected.itemId, store: store)) from audio preparation.")
        } catch {
            reportFailure(error, context: "Removing the item from audio preparation failed")
        }
    }

    func clearAudioPreparationQueue() {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            let itemIds = Set(jobs.map(\.itemId))
            foregroundAudioPreparationTask?.cancel()
            foregroundAudioPreparationGeneration += 1
            foregroundAudioPreparationTask = nil
            suppressAudioPreparation(itemIds: itemIds)
            try store.deleteAudioPreparationJobs(ids: jobs.map(\.id))
            pendingStartupAudioPreparationItemIds.subtract(itemIds)
            failedStartupAudioPreparationItemIds.subtract(itemIds)
            try refreshLibraryRows(store: store)
            diagnostics["audioPreparationQueueCleared"] = "\(jobs.count)"
            reportConfirmation("Cleared \(jobs.count) audio preparation job\(jobs.count == 1 ? "" : "s"). Existing audio and Library items were kept.")
        } catch {
            reportFailure(error, context: "Clearing the audio preparation queue failed")
        }
    }

    private func suppressAudioPreparation(itemId: String) {
        suppressAudioPreparation(itemIds: Set([itemId]))
    }

    private func suppressAudioPreparation(itemIds: Set<String>) {
        suppressedAutomaticAudioPreparationItemIds.formUnion(itemIds)
        UserDefaults.standard.set(
            suppressedAutomaticAudioPreparationItemIds.sorted(),
            forKey: Self.suppressedAudioPreparationItemIdsKey
        )
    }

    private func allowAudioPreparation(itemId: String) {
        guard suppressedAutomaticAudioPreparationItemIds.remove(itemId) != nil else { return }
        UserDefaults.standard.set(
            suppressedAutomaticAudioPreparationItemIds.sorted(),
            forKey: Self.suppressedAudioPreparationItemIdsKey
        )
    }

    private func itemsTitle(itemId: String, store: SQLiteSessionStore) -> String {
        (try? store.loadItem(id: itemId).title) ?? "this item"
    }

    func prioritizeAudioPreparationJob(id: String) {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard var selected = jobs.first(where: { $0.id == id }) else { return }
            // Pin only the selected job. Assigning ranks to the whole queue
            // would demote every future import behind all existing work.
            selected.userPriority = max(Int.min + 1, jobs.compactMap(\.userPriority).min() ?? 0) - 1
            try store.saveAudioPreparationJob(selected)
            try refreshAudioPreparationPresentation(store: store)
            startForegroundAudioPreparationIfNeeded()
        } catch {
            reportFailure(error, context: "Unable to prepare this item next")
        }
    }

    private func moveAudioPreparationJob(id: String, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        do {
            let store = try requireStore()
            var allJobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard let selected = allJobs.first(where: { $0.id == id }),
                  selected.itemId != activePlaybackItemId else { return }
            var tier = allJobs
                .filter {
                    $0.policy == selected.policy
                        && ($0.maximumChunkCount != nil) == (selected.maximumChunkCount != nil)
                        && $0.itemId != activePlaybackItemId
                }
                .sorted { Self.audioPreparationJobPrecedes($0, $1, activeItemId: nil) }
            guard let currentIndex = tier.firstIndex(where: { $0.id == id }) else { return }
            let destination = currentIndex + offset
            guard tier.indices.contains(destination) else { return }
            tier.swapAt(currentIndex, destination)
            for (priority, var job) in tier.enumerated() {
                job.userPriority = priority
                try store.saveAudioPreparationJob(job)
                if let allIndex = allJobs.firstIndex(where: { $0.id == job.id }) {
                    allJobs[allIndex] = job
                }
            }
            try refreshAudioPreparationPresentation(store: store)
            reportConfirmation("Updated the audio preparation order.")
        } catch {
            reportFailure(error, context: "Updating the audio preparation queue failed")
        }
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

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url).first
    }

    private func submitProviderJobIfNeeded(kind: String, itemId: String, turnId: String, messages: [String], force: Bool = false) {
        guard remoteProviderExperienceEnabled else {
            markProviderFailure("remote_provider_disabled", userMessage: "Remote AI is disabled in this release.", itemId: itemId)
            return
        }
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.", itemId: itemId)
            screen = .settings
            return
        }
        guard aiDataSharingConsent == .grantedV1 else {
            pendingProviderJobForConsent = PendingProviderJob(kind: kind, itemId: itemId, turnId: turnId, messages: messages, force: true)
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
                        credentials: .apiKey(providerAPIKey),
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
                    markProviderFailure(String(describing: error), userMessage: receivedText ? "Provider stream stopped; the partial response was saved." : "Provider call failed.", itemId: itemId)
                    return
                }
            }
        }
    }

    private func submitLocalSummary(itemId: String, turnId: String, contexts: [String]) {
        statusMessage = "Summarizing Margins on device."
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
                    userMessage: "On-device summary failed: \(error.localizedDescription) Tap Retry Summary to try the model again.",
                    itemId: itemId,
                    retry: .init(key: "summary") { [weak self] in self?.summarize() }
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
            let messages = [ProviderPrompts.assistantChapters(responseText: text)]
            let response = try await openAIResponsesClient.complete(
                credentials: .apiKey(providerAPIKey),
                model: model,
                instructions: "Return only strict JSON for assistant response chapters. Do not use Markdown.",
                messages: messages
            )
            let chapters = try AssistantChapterParser.chapters(from: response, responseText: text)
            if let engine {
                snapshot = try engine.aiChaptersCompleted(turnId: turnId, chapters: chapters)
                refreshSelectedItem()
            }
            diagnostics["assistantChapters:\(turnId)"] = "complete:\(chapters.count)"
        } catch {
            diagnostics["assistantChapters:\(turnId)"] = "unavailable:\(error.localizedDescription)"
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
            credentials: .apiKey(providerAPIKey),
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

    private func markProviderFailure(_ error: String, userMessage: String, itemId: String, retry: UserFeedbackEvent.Retry? = nil) {
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
        reportFailure(userMessage, itemId: itemId, retry: retry)
    }

    func latestInterjectionNeedingTranscription() -> Interjection? {
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
        guard pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        let sourceURL = localSourceURL
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalURL
        guard sourceURL.isFileURL else {
            pendingFullSourceTranscriptionItemIds.remove(item.id)
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
                    self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                    self.attachSourceTranscriptTimeline(timeline, itemId: item.id)
                }
            } catch {
                await MainActor.run {
                    self.pendingFullSourceTranscriptionItemIds.remove(item.id)
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

    /// The tap hands over what was heard around a Margin: write it to temporary files, then transcribe if the
    /// Margin's own note transcription has finished (otherwise that completion schedules this).
    func handleHeardSourceWindow(_ window: HeardAudioWindow) {
        let key = HeardAudioWindowRecorder.key(window.request)
        let diagnosticKey = Self.marginDiagnosticKey("heardSourceWindow", sessionId: window.request.sessionId, interjectionId: window.request.interjectionId)
        do {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = caches.appending(path: "HeardSourceWindows/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [(url: URL, startMediaTimeMs: Int, durationMs: Int)] = []
            for (index, segment) in window.segments.enumerated() where window.durationMs(of: segment) >= 2_000 {
                let url = directory.appending(path: "segment-\(index).caf")
                try Self.writeHeardSegment(segment.samples, sampleRate: window.sampleRate, to: url)
                files.append((url, segment.startMediaTimeMs, window.durationMs(of: segment)))
            }
            let totalMs = files.reduce(0) { $0 + $1.durationMs }
            diagnostics[diagnosticKey] = "captured:\(totalMs)ms;segments=\(files.count);before=\(window.coversBeforeAnchor ? 1 : 0);after=\(window.coversAfterAnchor ? 1 : 0);end=\(window.endReason)"
            guard !files.isEmpty else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            heardSourceWindows[key] = files
        } catch {
            diagnostics[diagnosticKey] = "write_failed:\(error.localizedDescription)"
            return
        }
        guard let store,
              let interjection = try? store.loadInterjections(sessionId: window.request.sessionId)
                .first(where: { $0.id == window.request.interjectionId }) else { return }
        if interjection.anchorContextStatus != .ready {
            scheduleSourceWindowContextIfNeeded(for: interjection)
        }
    }

    private nonisolated static func writeHeardSegment(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SessionKitError.persistenceFailed("heard_audio_buffer_unavailable")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// No heard audio yet: the tap delivers it about a minute after playback resumes. If it never arrives (the
    /// listener stopped, or the tap wasn't running), say so instead of leaving context pending forever.
    private func awaitHeardSourceWindow(for interjection: Interjection) {
        let key = Self.marginIdentity(interjection)
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "waiting:heard_audio"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(240))
            guard let self, self.heardSourceWindows[key] == nil,
                  !self.pendingSourceContextInterjectionIds.contains(key),
                  let store = self.store,
                  let current = try? store.loadInterjections(sessionId: interjection.sessionId).first(where: { $0.id == interjection.id }),
                  current.anchorContextStatus != .ready else { return }
            self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "failed:heard_audio_unavailable"
            self.run { engine in
                self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjection.id, sessionId: interjection.sessionId)
                self.refreshMarginRows()
            }
        }
    }

    private func transcribeHeardSourceWindow(
        _ files: [(url: URL, startMediaTimeMs: Int, durationMs: Int)],
        for interjection: Interjection,
        itemId: String,
        reportsResult: Bool
    ) {
        let key = Self.marginIdentity(interjection)
        guard pendingSourceContextInterjectionIds.insert(key).inserted else { return }
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "scheduled:heard_audio"
        diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = "heard_stream_audio"
        if reportsResult { reportConfirmation("Recovering source context…") }
        run { engine in
            snapshot = try engine.sourceWindowContextPending(interjectionId: interjection.id, sessionId: interjection.sessionId)
        }
        Task { [weak self] in
            guard let self else { return }
            var parts: [(startMediaTimeMs: Int, timeline: MediaTimeline)] = []
            var failure: String?
            for file in files {
                // A unique folder per segment: the transcriber reuses an existing export in the same folder.
                let scratchID = "heard-\(UUID().uuidString)"
                do {
                    let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                        url: file.url, itemId: scratchID, anchorMediaTimeMs: 0, durationMs: file.durationMs,
                        windowBeforeMs: 0, windowAfterMs: file.durationMs
                    )
                    parts.append((file.startMediaTimeMs, analysis.timeline))
                } catch {
                    failure = error.localizedDescription
                }
                if let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    try? SourceTranscriptionCaches.remove(.windows, itemId: scratchID, cachesDirectory: caches)
                }
            }
            if let directory = files.first?.url.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: directory)
            }
            await MainActor.run {
                self.heardSourceWindows[key] = nil
                self.pendingSourceContextInterjectionIds.remove(key)
                let timeline = HeardAudioWindow.episodeTimeline(parts)
                let transcriptionKey = Self.marginDiagnosticKey("sourceWindowTranscription", interjection)
                self.run { engine in
                    if timeline.segments.isEmpty {
                        self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjection.id, sessionId: interjection.sessionId)
                        self.diagnostics[transcriptionKey] = "failed:heard_audio:\(failure ?? "no_speech")"
                        if reportsResult { self.reportWarning("Source context could not be recovered from the audio you heard.") }
                    } else {
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, sessionId: interjection.sessionId, timeline: timeline)
                        self.diagnostics[transcriptionKey] = "complete:heard_audio:\(timeline.segments.count)_segments"
                        if reportsResult { self.reportConfirmation("Source context recovered.") }
                    }
                    self.refreshSelectedItem()
                    self.refreshMarginRows()
                }
            }
        }
    }

    @discardableResult
    private func scheduleSourceWindowContextIfNeeded(for interjection: Interjection, reportsResult: Bool = false) -> Bool {
        guard interjection.captureKind != .written,
              interjection.targetType == .item,
              let anchorMediaTimeMs = interjection.anchor.mediaTimeMs,
              let store,
              let item = try? store.loadItem(id: interjection.itemId),
              let sourceURLString = item.media?.url,
              let canonicalSourceURL = URL(string: sourceURLString) else {
            return false
        }
        // Acoustic evidence can fail before note transcription even starts. That
        // fallback must not race the note for the speech-recognition service.
        let saved = try? store.loadInterjections(sessionId: interjection.sessionId)
            .first(where: { $0.id == interjection.id })
        guard saved?.transcriptionStatus != "pending",
              !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return false }
        switch item.media?.sourceType {
        case .some(.nativeMediaFile), .some(.remoteStream):
            break
        default:
            return false
        }
        if let storedTimeline = try? store.loadTranscriptTimeline(itemId: item.id)?.timeline,
           let window = SourceAnchorContextResolver.sourceContextWindow(
               from: storedTimeline,
               anchorMediaTimeMs: anchorMediaTimeMs,
               windowBeforeMs: sourceWindowContextBeforeMs,
               windowAfterMs: sourceWindowContextAfterMs
           ) {
            run { engine in
                snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, sessionId: interjection.sessionId, timeline: window)
                refreshSelectedItem()
                refreshMarginRows()
                if reportsResult { reportConfirmation("Source context recovered.") }
                diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "complete:stored_transcript"
                diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = "stored_transcript"
            }
            return true
        }
        let transcriptionURL = (item.media?.sourceType == .nativeMediaFile ? resolvedOwnedAudiobookURL(for: item) : nil)
            ?? importedPodcastRecipientLocalURLs[item.id]
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalSourceURL
        if !transcriptionURL.isFileURL {
            // #156: a window can't be cut from a stream after the fact (AVFoundation stops the export). Use the
            // minute before and after the Margin that the player's tap kept, once it has been handed over.
            if let heard = heardSourceWindows[Self.marginIdentity(interjection)] {
                transcribeHeardSourceWindow(heard, for: interjection, itemId: item.id, reportsResult: reportsResult)
            } else if reportsResult {
                // A manual retry comes long after the heard audio was used or dropped.
                reportWarning("Context for a streamed episode comes from the audio around the Margin as you heard it, and that's no longer available. Download the episode to recover it.")
            } else {
                awaitHeardSourceWindow(for: interjection)
            }
            return true
        }
        if reportsResult { reportConfirmation("Recovering source context…") }
        diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", interjection)] = "scheduled"
        let provenance = transcriptionURL.isFileURL ? "downloaded_local_audio" : "bounded_remote_window"
        diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", interjection)] = provenance
        pendingSourceContextInterjectionIds.insert(Self.marginIdentity(interjection))
        run { engine in
            snapshot = try engine.sourceWindowContextPending(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
        }
        // #871: at most two of these run at once, nearest the playhead first. A finished download used to start
        // one per Margin, all together.
        let identity = Self.marginIdentity(interjection)
        sourceWindowJobQueue.enqueue(id: identity, anchorMediaTimeMs: anchorMediaTimeMs, playhead: { [weak self, itemId = item.id] in
            // Asked each time the queue picks a job, so a seek while jobs wait is followed. A retry the listener
            // asked for goes first; otherwise the order follows the playhead of the episode that's playing.
            if reportsResult { return anchorMediaTimeMs }
            guard let self, self.snapshot.itemId == itemId else { return nil }
            return self.snapshot.currentMediaTimeMs
        }) { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs, windowBeforeMs = sourceWindowContextBeforeMs, windowAfterMs = sourceWindowContextAfterMs] in
            guard let self else { return }
            // Every way out clears the mark, so a failure inside `run` can't leave the Margin stuck as pending.
            defer { self.pendingSourceContextInterjectionIds.remove(identity) }
            let request = PostResumeAudioSampleRequest(
                interjectionId: interjectionId,
                sessionId: interjection.sessionId,
                itemId: itemId,
                anchorMediaTimeMs: anchorMediaTimeMs,
                targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
            )
            // It may have waited in line a while. A Margin deleted meanwhile (kept, with status "deleted") has nothing to recover.
            guard let stored = self.storedInterjection(request: request), stored.status != "deleted" else { return }
            do {
                let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                    url: transcriptionURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: windowBeforeMs,
                    windowAfterMs: windowAfterMs
                )
                let reference = await SourceWindowReferenceEvidence.generate(
                    from: analysis,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    outputDirectory: Result { try self.podcastAnchorEvidenceDirectory(for: request) },
                    idPrefix: self.podcastAnchorEvidenceID(request: request, suffix: "source-window")
                )
                self.run { engine in
                    self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, sessionId: interjection.sessionId, timeline: analysis.timeline)
                    if !reference.evidence.isEmpty {
                        try self.persistPodcastAnchorEvidence(
                            request: request,
                            evidence: reference.evidence,
                            sourceExactEditionSHA256: nil
                        )
                    }
                    self.refreshSelectedItem()
                    self.refreshMarginRows()
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "complete:speech_window"
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = provenance
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowSignature", sessionId: interjection.sessionId, interjectionId: interjectionId)] = reference.evidence.isEmpty
                        ? "unavailable:\(reference.failure ?? "temporary_audio_unavailable")"
                        : "complete:\(reference.evidence.count)"
                    self.pendingSourceContextInterjectionIds.remove(identity)
                    if reportsResult { self.reportConfirmation("Source context recovered.") }
                }
            } catch {
                self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "failed:\(error.localizedDescription)"
                self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "unavailable"
                self.pendingSourceContextInterjectionIds.remove(identity)
                self.run { engine in
                    self.snapshot = try engine.sourceWindowContextUnavailable(interjectionId: interjectionId, sessionId: interjection.sessionId)
                    self.refreshSelectedItem()
                    self.refreshMarginRows()
                }
                if reportsResult {
                    self.reportWarning("Source context could not be recovered: \(error.localizedDescription)")
                }
                // Source-window context is redundant, best-effort evidence.
                // The Margin and its timestamp are already durable, and the
                // Timeline exposes the retry state. Do not turn this expected
                // degradation into a global error banner after every Margin.
            }
        }
        return true
    }

    private func retrySourceWindowContexts(itemId: String) {
        guard let store else { return }
        let sessions = (try? store.loadSessions(itemId: itemId)) ?? []
        for session in sessions {
            let interjections = (try? store.loadInterjections(sessionId: session.id)) ?? []
            for interjection in interjections where interjection.targetType == .item
                && interjection.anchor.mediaTimeMs != nil
                && interjection.status != "deleted"
                && interjection.anchorContextStatus != .ready
                && !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) {
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
        }
    }

    func scheduleTranscription(for interjection: Interjection) {
        guard let audioPath = interjection.audioPath else { return }
        recordAnchorCaptureDiagnostics(for: interjection)
        switch interjection.podcastAnchorEvidenceCaptureStatus {
        case .pendingPostResumeSample:
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "sampling:decoded_playback_post_resume"
        case .pendingExactLocalCapture:
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "sampling:exact_local_playback_edition"
        case .ready:
            break
        case .unavailable, nil:
            schedulePodcastAnchorEvidenceCapture(for: interjection)
        }
        diagnostics[Self.marginDiagnosticKey("interjectionAudioAtCapture", interjection)] = interjectionAudioEvidence(for: audioPath)
        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "scheduled"
        Task {
            do {
                let alignedTranscript = try await alignedInterjectionTranscriptionHandler?(audioPath)
                let transcript: String
                if let alignedTranscript {
                    transcript = alignedTranscript.text
                } else {
                    transcript = try await interjectionTranscriptionHandler(audioPath)
                }
                await MainActor.run {
                    run { engine in
                        if let alignedTranscript {
                            snapshot = try engine.transcriptionCompleted(
                                interjectionId: interjection.id,
                                sessionId: interjection.sessionId,
                                alignedTranscript: alignedTranscript
                            )
                        } else {
                            snapshot = try engine.transcriptionCompleted(
                                interjectionId: interjection.id,
                                sessionId: interjection.sessionId,
                                transcript: transcript
                            )
                        }
                        refreshSelectedItem()
                        refreshMarginRows()
                        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "complete"
                        reportSuccess("Transcribed Margin.")
                    }
                    retryingInterjectionTranscriptionIds.remove(Self.marginIdentity(interjection))
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            } catch {
                await MainActor.run {
                    let failure = String(describing: error)
                    let wasRetry = retryingInterjectionTranscriptionIds.contains(Self.marginIdentity(interjection))
                    if wasRetry {
                        diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "retry_failed:\(failure)"
                        diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                        TranscriptionFailureWording.notice(error: failure, isRetry: true).present(warning: { reportWarning($0) }, failure: { reportFailure($0) })
                    } else {
                        run { engine in
                            snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
                            refreshSelectedItem()
                        refreshMarginRows()
                            diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "failed:\(failure)"
                            diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                            TranscriptionFailureWording.notice(error: failure, isRetry: false).present(warning: { reportWarning($0) }, failure: { reportFailure($0) })
                        }
                    }
                    retryingInterjectionTranscriptionIds.remove(Self.marginIdentity(interjection))
                    scheduleSourceWindowContextIfNeeded(for: interjection)
                }
            }
        }
    }

    private func schedulePodcastAnchorEvidenceCapture(for interjection: Interjection) {
        guard interjection.targetType == .item,
              let mediaTimeMs = interjection.anchor.mediaTimeMs,
              let sourceURL = podcastDownloadCoordinator?.validatedLocalURL(for: interjection.itemId),
              mediaPlaybackClient?.isUsingPlaybackURL(sourceURL, itemId: interjection.itemId) == true else {
            markPodcastAnchorEvidenceUnavailable(
                request: PostResumeAudioSampleRequest(
                    interjectionId: interjection.id,
                    sessionId: interjection.sessionId,
                    itemId: interjection.itemId,
                    anchorMediaTimeMs: interjection.anchor.mediaTimeMs ?? 0,
                    targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                ),
                reason: "no_exact_local_playback_edition"
            )
            return
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "scheduled"
        let request = PostResumeAudioSampleRequest(
            interjectionId: interjection.id,
            sessionId: interjection.sessionId,
            itemId: interjection.itemId,
            anchorMediaTimeMs: mediaTimeMs,
            targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
        )
        guard let root = try? podcastAnchorEvidenceDirectory(for: request) else {
            markPodcastAnchorEvidenceUnavailable(request: request, reason: "storage_unavailable")
            return
        }
        markPodcastAnchorEvidencePendingLocal(request: request)
        let evidenceIDPrefix = podcastAnchorEvidenceID(request: request, suffix: "local")
        Task.detached { [weak self] in
            do {
                let digestBeforeCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                let generated = try await PodcastAnchorEvidenceGenerator.generate(
                    sourceURL: sourceURL,
                    anchorMediaTimeMs: mediaTimeMs,
                    outputDirectory: root,
                    idPrefix: evidenceIDPrefix
                )
                let digestAfterCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                guard digestBeforeCapture == digestAfterCapture else {
                    throw SessionKitError.persistenceFailed("podcast_anchor_source_changed_during_capture")
                }
                let captured = generated.map {
                    CapturedPodcastAnchorEvidence(
                        id: $0.id,
                        localPath: $0.fileURL.path,
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: .exactLocalPlaybackEdition,
                        windowRole: $0.id.hasSuffix("-pre") ? .preInterjection : .postResume
                    )
                }
                await MainActor.run {
                    do {
                        try self?.persistPodcastAnchorEvidence(
                            request: request,
                            evidence: captured,
                            sourceExactEditionSHA256: digestAfterCapture
                        )
                        self?.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "complete:\(captured.count)"
                    } catch {
                        self?.markPodcastAnchorEvidenceUnavailable(
                            request: request,
                            reason: "local_signature_persistence_failed:\(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.markPodcastAnchorEvidenceUnavailable(
                        request: request,
                        reason: "local_signature_failed:\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    #if canImport(AVFoundation) && canImport(ShazamKit)
    private func handlePostResumePodcastEvidence(_ result: PostResumePodcastEvidenceCaptureResult) {
        switch result {
        case .captured(let capture):
            do {
                let root = try podcastAnchorEvidenceDirectory(for: capture.request)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let evidenceID = podcastAnchorEvidenceID(
                    request: capture.request,
                    suffix: capture.windowRole == .preInterjection ? "stream-pre" : "stream-post"
                )
                let fileURL = root.appending(path: "\(evidenceID).shazamsignature")
                try capture.signatureData.write(to: fileURL, options: .atomic)
                try persistPodcastAnchorEvidence(
                    request: capture.request,
                    evidence: [CapturedPodcastAnchorEvidence(
                        id: evidenceID,
                        localPath: fileURL.path,
                        durationMs: capture.durationMs,
                        anchorOffsetMs: capture.anchorOffsetMs,
                        provenance: .observedDecodedPlayback,
                        windowRole: capture.windowRole == .preInterjection ? .preInterjection : .postResume
                    )],
                    sourceExactEditionSHA256: nil
                )
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", capture.request)] =
                    "complete:decoded_playback_\(capture.windowRole.rawValue):bytes=\(capture.signatureData.count)"
            } catch {
                markPodcastAnchorEvidenceUnavailable(
                    request: capture.request,
                    reason: "stream_signature_persistence_failed:\(error.localizedDescription)"
                )
            }
        case .landmark(let landmark):
            do {
                try persistSparseEpisodeFingerprintLandmark(landmark)
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "captured:\(landmark.trigger.rawValue):epoch=\(landmark.continuityEpoch)"
            } catch {
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "persistence_failed:\(error.localizedDescription)"
            }
        case .failed(let request, let reason):
            if let interjection = recordPodcastAnchorEvidenceFailureReason(request: request, reason: "stream_failed:\(reason)") {
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "stream_failed:\(reason)"
                schedulePodcastAnchorEvidenceCapture(for: interjection)
            } else {
                markPodcastAnchorEvidenceUnavailable(request: request, reason: reason)
            }
        }
    }
    #endif

    #if canImport(AVFoundation) && canImport(ShazamKit)
    private func persistSparseEpisodeFingerprintLandmark(
        _ capture: CapturedEpisodeFingerprintLandmark
    ) throws {
        guard let store else { throw SessionKitError.persistenceFailed("store_unavailable") }
        let safeItem = safePodcastEvidenceComponent(capture.itemId)
        let root = try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safeItem, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suffix = capture.gridIndex.map { "grid-\($0)" }
            ?? "epoch-\(capture.continuityEpoch)-\(capture.sourceMediaStartMs)"
        let assetID = "episode-signature-\(safeItem)-\(suffix)"
        let fileURL = root.appending(path: "\(assetID).shazamsignature")
        try capture.signatureData.write(to: fileURL, options: .atomic)

        let existing = try store.loadEditionFingerprintSpine(itemId: capture.itemId)
        var landmarks = existing?.landmarks.filter { $0.signatureAssetId != assetID } ?? []
        landmarks.append(EpisodeFingerprintLandmark(
            id: "landmark-\(suffix)",
            order: landmarks.count,
            sourceMediaStartMs: capture.sourceMediaStartMs,
            sourceMediaEndMs: capture.sourceMediaEndMs,
            anchorMediaTimeMs: capture.anchorMediaTimeMs,
            continuityEpoch: capture.continuityEpoch,
            trigger: capture.trigger,
            provenance: .observedDecodedPlayback,
            signatureAssetId: assetID
        ))
        landmarks = landmarks.sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }.enumerated().map { index, value in
            EpisodeFingerprintLandmark(
                id: value.id,
                order: index,
                sourceMediaStartMs: value.sourceMediaStartMs,
                sourceMediaEndMs: value.sourceMediaEndMs,
                anchorMediaTimeMs: value.anchorMediaTimeMs,
                continuityEpoch: value.continuityEpoch,
                trigger: value.trigger,
                provenance: value.provenance,
                signatureAssetId: value.signatureAssetId,
                transcriptSketchWindowId: value.transcriptSketchWindowId,
                generatorVersion: value.generatorVersion
            )
        }
        let item = try? store.loadItem(id: capture.itemId)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: existing?.id ?? "episode-spine-\(safeItem)",
            itemId: capture.itemId,
            canonicalURL: item?.externalReference ?? item?.media?.url,
            producingEditionDurationMs: item?.media?.durationMs,
            producingEditionSHA256: existing?.producingEditionSHA256,
            createdAt: existing?.createdAt ?? Date(),
            landmarks: landmarks
        ))
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: assetID,
            itemId: capture.itemId,
            category: .fingerprintMap,
            relativePath: "SpokenMargins/EpisodeMaps/\(safeItem)/\(assetID).shazamsignature",
            byteCount: Int64(capture.signatureData.count),
            isReproducible: false
        ))
    }
    #endif

    private func podcastAnchorEvidenceDirectory(for request: PostResumeAudioSampleRequest) throws -> URL {
        try PodcastAnchorEvidencePaths.directory(
            applicationSupport: applicationSupportDirectory(),
            sessionId: request.sessionId,
            interjectionId: request.interjectionId
        )
    }

    private func podcastAnchorEvidenceID(
        request: PostResumeAudioSampleRequest,
        suffix: String
    ) -> String {
        PodcastAnchorEvidencePaths.evidenceID(
            sessionId: request.sessionId,
            interjectionId: request.interjectionId,
            suffix: suffix
        )
    }

    private func safePodcastEvidenceComponent(_ value: String) -> String {
        PodcastAnchorEvidencePaths.safeComponent(value)
    }

    private func storedInterjection(request: PostResumeAudioSampleRequest) -> Interjection? {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId) else { return nil }
        return records.first { $0.id == request.interjectionId && $0.itemId == request.itemId }
    }

    private func persistPodcastAnchorEvidence(
        request: PostResumeAudioSampleRequest,
        evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?
    ) throws {
        guard let store,
              let interjection = try store.loadInterjections(sessionId: request.sessionId)
                .first(where: { $0.id == request.interjectionId && $0.itemId == request.itemId }) else {
            throw SessionKitError.persistenceFailed("podcast_anchor_interjection_missing")
        }
        try store.saveInterjection(PodcastAnchorEvidenceRecord.merging(
            evidence,
            sourceExactEditionSHA256: sourceExactEditionSHA256,
            into: interjection
        ))
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    private func markPodcastAnchorEvidenceUnavailable(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              let stored = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else {
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "unavailable:\(reason)"
            return
        }
        let interjection = PodcastAnchorEvidenceRecord.markingUnavailable(stored, reason: reason)
        try? store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] =
            "unavailable:\(interjection.podcastAnchorEvidenceFailureReason ?? reason)"
        scheduleSourceWindowContextIfNeeded(for: interjection)
    }

    private func markPodcastAnchorEvidencePendingLocal(request: PostResumeAudioSampleRequest) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              let stored = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else { return }
        try? store.saveInterjection(PodcastAnchorEvidenceRecord.markingPendingLocalCapture(stored))
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    /// Stores a failure without changing capture status, so a fallback that runs next can't hide it.
    private func recordPodcastAnchorEvidenceFailureReason(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) -> Interjection? {
        guard let stored = storedInterjection(request: request) else { return nil }
        let interjection = PodcastAnchorEvidenceRecord.recordingFailureReason(reason, on: stored)
        try? store?.saveInterjection(interjection)
        return interjection
    }

    func prepareExportShareInterjections() {
        do {
            let store = try requireStore()
            guard let exportSessionId, let session = try store.loadSession(id: exportSessionId) else {
                throw SessionKitError.persistenceFailed("export_session_missing")
            }
            let candidates = try store.loadInterjections(sessionId: session.id)
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            prepareShareInterjections(candidates: candidates)
            if isSharingInterjectionsPresented { sharingState.draftsPreparedForExport = true }
        } catch { reportFailure(error, context: "Prepare session sharing failed") }
    }

    func openMarginItemExport(itemID: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        do {
            selectedItem = try loadItemDetail(id: itemID, store: requireStore())
            let sessionID = selectedItem.sessionRows.first { $0.interjectionCount > 0 }?.id
            openExport(sessionId: sessionID)
        } catch { reportFailure(error, context: "Open item export failed") }
    }

    func prepareShareInterjections() {
        prepareShareInterjections(candidates: selectedItem.interjections)
    }

    private func prepareShareInterjections(candidates source: [Interjection]) {
        cancelBulkSharePreparation()
        let candidates = source.filter {
            $0.status == "active" && $0.targetType == .item
        }
        guard !candidates.isEmpty else {
            reportFailure("Record at least one Margin on this item before sharing.")
            return
        }
        let hasStarredCandidates = candidates.contains { $0.isStarredForSharing == true }
        sharingState = InterjectionSharingState(isPreparing: true)
        sharingState.draftFilter = hasStarredCandidates ? .starred : .all
        isSharingInterjectionsPresented = true
        if let item = try? requireStore().loadItem(id: selectedItem.id) {
            let reference = secureSharedItemURL(for: item)
            sharingState.itemReferenceURL = reference
            sharingState.isAppAuthoredItem = item.id == Self.welcomeSampleItemId
            sharingState.canEmbedLinklessItem = reference == nil
                && sharedItemType(for: item) != .podcast
                && !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sharingState.confirmsPrivateSharingRights = sharingState.isAppAuthoredItem
        }
        sharingState.drafts = candidates.map { interjection in
            let transcript = SharedMarginTextRequirement.initialReviewedText(for: interjection)
            let hasAudio = interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) != nil
            let context = BoundedAnchorContext.select(
                before: interjection.anchor.anchorBefore,
                after: interjection.anchor.anchorAfter
            )
            return ShareInterjectionDraft(
                interjection: interjection,
                isIncluded: !hasStarredCandidates || interjection.isStarredForSharing == true,
                approvedTranscript: transcript,
                representationChoice: hasAudio ? .original : .textOnly,
                warning: SharedMarginTextRequirement.reviewWarning(for: transcript) ?? shareAnchorWarning(for: interjection),
                anchorBefore: context.before,
                anchorAfter: context.after
            )
        }
        sharingState.isPreparing = false
    }

    var bulkSharePreparationEligibleCount: Int {
        sharingState.drafts.filter(isEligibleForBulkSharePreparation).count
    }

    func prepareAllIncludedShareDrafts() {
        guard !sharingState.isBulkPreparing else { return }
        let draftIDs = sharingState.drafts
            .filter(isEligibleForBulkSharePreparation)
            .map(\.id)
        guard !draftIDs.isEmpty else { return }

        bulkSharePreparationGeneration += 1
        let generation = bulkSharePreparationGeneration
        sharingState.isBulkPreparing = true
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = draftIDs.count
        sharingState.bulkPreparationFailureCount = 0
        sharingState.errorMessage = nil
        diagnostics["bulkSharePreparation"] = "started:total=\(draftIDs.count)"

        bulkSharePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for draftID in draftIDs {
                guard !Task.isCancelled,
                      self.bulkSharePreparationGeneration == generation else { return }
                let prepared = await self.prepareShareDraftForBulk(
                    draftID,
                    generation: generation
                )
                guard !Task.isCancelled,
                      self.bulkSharePreparationGeneration == generation else { return }
                self.sharingState.bulkPreparationCompleted += 1
                if !prepared {
                    self.sharingState.bulkPreparationFailureCount += 1
                }
            }
            guard self.bulkSharePreparationGeneration == generation else { return }
            self.sharingState.isBulkPreparing = false
            self.bulkSharePreparationTask = nil
            self.diagnostics["bulkSharePreparation"] = [
                "complete",
                "prepared=\(self.sharingState.bulkPreparationCompleted)",
                "fallbacks=\(self.sharingState.bulkPreparationFailureCount)"
            ].joined(separator: ";")
        }
    }

    func cancelBulkSharePreparation() {
        guard sharingState.isBulkPreparing || bulkSharePreparationTask != nil else { return }
        bulkSharePreparationGeneration += 1
        bulkSharePreparationTask?.cancel()
        bulkSharePreparationTask = nil
        sharingState.isBulkPreparing = false
        for index in sharingState.drafts.indices {
            let wasInFlight = sharingState.drafts[index].isAnalyzingPauses
                || sharingState.drafts[index].isPreparingCleanup
            sharingState.drafts[index].isAnalyzingPauses = false
            sharingState.drafts[index].isPreparingCleanup = false
            if wasInFlight,
               sharingState.drafts[index].currentEditState.automaticCleanupEnabled,
               sharingState.drafts[index].canUndoEdit {
                let hasOriginalAudio = originalAudioURL(forShareDraft: sharingState.drafts[index].id) != nil
                _ = sharingState.drafts[index].undoEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false)
            }
        }
        diagnostics["bulkSharePreparation"] = [
            "cancelled",
            "prepared=\(sharingState.bulkPreparationCompleted)",
            "total=\(sharingState.bulkPreparationTotal)"
        ].joined(separator: ";")
    }

    private func isEligibleForBulkSharePreparation(_ draft: ShareInterjectionDraft) -> Bool {
        draft.isIncluded
            && draft.interjection.alignedTranscript != nil
            && !draft.currentEditState.automaticCleanupEnabled
    }

    private func prepareShareDraftForBulk(
        _ id: String,
        generation: Int
    ) async -> Bool {
        guard let initialIndex = sharingState.drafts.firstIndex(where: { $0.id == id }),
              let aligned = sharingState.drafts[initialIndex].interjection.alignedTranscript else {
            return false
        }
        sharingState.drafts[initialIndex].preparationMessage = nil
        recordShareEdit(for: id, renderCleanedAudio: false) {
            $0.automaticCleanupEnabled = true
        }
        sharingState.automaticallyCleanedDraftIDs.insert(id)

        guard let analysisIndex = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let audioPath = sharingState.drafts[analysisIndex].interjection.audioPath
        let sourceURL = audioPath.flatMap(resolvedInterjectionAudioURL(for:))
        var analysisFailure: String?
        if let sourceURL {
            sharingState.drafts[analysisIndex].isAnalyzingPauses = true
            let analyzer = shareMarginSilenceAnalysisHandler
            let analysis = await Task.detached {
                do {
                    return (try analyzer(sourceURL, aligned), nil as String?)
                } catch {
                    return ([], error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled,
                  bulkSharePreparationGeneration == generation,
                  let current = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
                return false
            }
            sharingState.drafts[current].isAnalyzingPauses = false
            sharingState.drafts[current].acousticPauseDecisions = analysis.0
            analysisFailure = analysis.1
            applyShareEditState(at: current, renderCleanedAudio: false)
        } else if audioPath != nil {
            analysisFailure = "The saved voice recording is unavailable; reviewed text remains available."
        }

        guard !Task.isCancelled,
              bulkSharePreparationGeneration == generation else { return false }
        let rendered = await renderBulkCleanup(forShareDraft: id, generation: generation)
        guard bulkSharePreparationGeneration == generation,
              let finalIndex = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let analysisFailure {
            let analysisMessage =
                "Pause analysis was unavailable (\(analysisFailure)). Filler and manual text edits remain reviewable."
            if let renderMessage = sharingState.drafts[finalIndex].preparationMessage {
                sharingState.drafts[finalIndex].preparationMessage = "\(renderMessage) \(analysisMessage)"
            } else {
                sharingState.drafts[finalIndex].preparationMessage = analysisMessage
            }
        }
        return rendered && analysisFailure == nil
    }

    private func renderBulkCleanup(
        forShareDraft id: String,
        generation bulkGeneration: Int
    ) async -> Bool {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard let decisions = sharingState.drafts[index].cleanup?.decisions else {
            return true
        }
        guard let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath) else {
            sharingState.drafts[index].representationChoice = .textOnly
            sharingState.drafts[index].preparationMessage =
                "Cleaned voice could not be prepared because the saved recording is unavailable. Reviewed text remains available."
            return false
        }
        guard let root = try? applicationSupportDirectory()
            .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            sharingState.drafts[index].preparationMessage =
                "Cleaned voice storage is unavailable. Original voice and reviewed text remain available."
            return false
        }
        sharingState.drafts[index].renderGeneration += 1
        let renderGeneration = sharingState.drafts[index].renderGeneration
        sharingState.drafts[index].isPreparingCleanup = true
        let destination = root.appending(path: "cleaned-\(safePodcastEvidenceComponent(id)).m4a")
        let renderer = shareMarginAudioCleanupHandler
        let result: (duration: Int?, failure: String?)
        do {
            result = (try await renderer(sourceURL, destination, decisions), nil)
        } catch {
            result = (nil, error.localizedDescription)
        }
        guard !Task.isCancelled,
              bulkSharePreparationGeneration == bulkGeneration,
              let current = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[current].renderGeneration == renderGeneration else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        sharingState.drafts[current].isPreparingCleanup = false
        if let duration = result.duration {
            sharingState.drafts[current].cleanedAudioURL = destination
            sharingState.drafts[current].cleanedAudioDurationMs = duration
            sharingState.drafts[current].representationChoice = .cleaned
            return true
        }
        sharingState.drafts[current].cleanedAudioURL = nil
        sharingState.drafts[current].cleanedAudioDurationMs = nil
        sharingState.drafts[current].representationChoice =
            originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
        sharingState.drafts[current].preparationMessage =
            "Cleaned voice could not be prepared (\(result.failure ?? "unknown error")). Original voice or reviewed text remains available."
        return false
    }

    func setShareDraftIncluded(_ id: String, included: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setIncluded(included)
    }

    func setShareDraftsIncluded(_ ids: [String], included: Bool) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        for index in sharingState.drafts.indices where targetIDs.contains(sharingState.drafts[index].id) {
            sharingState.drafts[index].setIncluded(included)
        }
    }

    func setShareAutoCleanSelectedEnabled(_ enabled: Bool) {
        ShareAutoCleanPreference.record(enabled: enabled)
        sharingState.needsAutoCleanDecision = false
        sharingState.autoCleanSelectedEnabled = enabled
        if enabled {
            prepareAllIncludedShareDrafts()
        } else {
            cancelBulkSharePreparation()
            undoAutomaticallyCleanedShareDrafts()
        }
    }

    func prepareAutomaticallyCleanedShareDraftsIfEnabled() {
        guard sharingState.autoCleanSelectedEnabled else { return }
        prepareAllIncludedShareDrafts()
    }

    private func undoAutomaticallyCleanedShareDrafts() {
        let draftIDs = sharingState.automaticallyCleanedDraftIDs
        for id in draftIDs {
            recordShareEdit(for: id, renderCleanedAudio: false) {
                $0.disableAutomaticCleanup()
            }
        }
        sharingState.automaticallyCleanedDraftIDs.removeAll()
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = 0
        sharingState.bulkPreparationFailureCount = 0
    }

    func setShareDraftRepresentation(_ id: String, choice: ShareMarginRepresentationChoice) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        sharingState.drafts[index].setRepresentation(choice, hasOriginalAudio: hasOriginalAudio)
    }

    func setShareDraftAnchorBefore(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setAnchorBefore(value)
    }

    func setShareDraftAnchorAfter(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setAnchorAfter(value)
    }

    func originalAudioURL(forShareDraft id: String) -> URL? {
        sharingState.drafts.first(where: { $0.id == id })?
            .interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))
    }

    func prepareCleanup(forShareDraft id: String) {
        guard !sharingState.isBulkPreparing else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
            sharingState.drafts[index].preparationMessage = nil
        }
        recordShareEdit(for: id) { $0.automaticCleanupEnabled = true }
        analyzeAcousticPauses(forShareDraft: id)
    }

    func setCleanupDecision(draftID: String, decisionID: String, accepted: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: draftID) != nil
        if sharingState.drafts[index].setCleanupDecision(decisionID: decisionID, accepted: accepted, hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: draftID)
        }
    }

    func toggleShareDraftWord(draftID: String, segmentID: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: draftID) != nil
        if sharingState.drafts[index].toggleWord(segmentID: segmentID, hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: draftID)
        }
    }

    func isShareDraftWordDeleted(draftID: String, segmentID: String) -> Bool {
        sharingState.drafts.first(where: { $0.id == draftID })?.isWordDeleted(segmentID: segmentID) ?? false
    }

    func undoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].undoEdit(hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    func redoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].redoEdit(hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    func restoreOriginalShareDraft(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        let anchorWarning = shareAnchorWarning(for: sharingState.drafts[index].interjection)
        sharingState.drafts[index].restoreOriginal(hasOriginalAudio: hasOriginalAudio, anchorWarning: anchorWarning)
    }

    private func recordShareEdit(
        for id: String,
        renderCleanedAudio: Bool = true,
        mutate: (inout ShareMarginEditState) -> Void
    ) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].recordEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio, mutate: mutate) {
            renderCleanup(forShareDraft: id)
        }
    }

    private func applyShareEditState(at index: Int, renderCleanedAudio: Bool = true) {
        guard sharingState.drafts.indices.contains(index) else { return }
        let id = sharingState.drafts[index].id
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    private func analyzeAcousticPauses(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].acousticPauseDecisions.isEmpty,
              !sharingState.drafts[index].isAnalyzingPauses,
              let aligned = sharingState.drafts[index].interjection.alignedTranscript,
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath) else { return }
        sharingState.drafts[index].isAnalyzingPauses = true
        let analyzer = shareMarginSilenceAnalysisHandler
        Task.detached { [weak self] in
            let result: ([InterjectionCleanupDecision], String?)
            do {
                result = (try analyzer(sourceURL, aligned), nil)
            } catch {
                result = ([], error.localizedDescription)
            }
            await MainActor.run {
                guard let self,
                      let current = self.sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
                self.sharingState.drafts[current].isAnalyzingPauses = false
                self.sharingState.drafts[current].acousticPauseDecisions = result.0
                if let failure = result.1 {
                    self.sharingState.drafts[current].preparationMessage =
                        "Pause analysis was unavailable (\(failure)). Filler and manual text edits remain reviewable."
                }
                self.applyShareEditState(at: current)
            }
        }
    }

    private func renderCleanup(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath),
              let decisions = sharingState.drafts[index].cleanup?.decisions,
              let root = try? applicationSupportDirectory()
                .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
                sharingState.drafts[index].warning = [
                    shareAnchorWarning(for: sharingState.drafts[index].interjection),
                    "The cleaned audio preview could not be prepared. You can still share original voice or text."
                ].compactMap { $0 }.joined(separator: " ")
            }
            return
        }
        sharingState.drafts[index].renderGeneration += 1
        let generation = sharingState.drafts[index].renderGeneration
        sharingState.drafts[index].isPreparingCleanup = true
        let destination = root.appending(path: "cleaned-\(safePodcastEvidenceComponent(id)).m4a")
        let renderer = shareMarginAudioCleanupHandler
        Task.detached { [weak self] in
            do {
                let duration = try await renderer(sourceURL, destination, decisions)
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = destination
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = duration
                    self?.sharingState.drafts[current].representationChoice = .cleaned
                    if let interjection = self?.sharingState.drafts[current].interjection {
                        self?.sharingState.drafts[current].warning = self?.shareAnchorWarning(for: interjection)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = nil
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = nil
                    self?.sharingState.drafts[current].representationChoice =
                        self?.originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
                    self?.sharingState.drafts[current].preparationMessage =
                        "Cleaned voice could not be prepared. Original voice or reviewed text remains available."
                    if let interjection = self?.sharingState.drafts[current].interjection {
                        self?.sharingState.drafts[current].warning = [
                            self?.shareAnchorWarning(for: interjection),
                            "Cleaned audio could not be regenerated. Original voice and reviewed text are still available."
                        ].compactMap { $0 }.joined(separator: " ")
                    }
                }
            }
        }
    }

    private func shareAnchorWarning(for interjection: Interjection) -> String? {
        SharedMarginExport.anchorWarning(for: interjection, isNativeAudio: selectedItem.isNativeAudio)
    }

    func exportSharedInterjections(presentsReadySheet: Bool = true) {
        guard !sharingState.isBulkPreparing else {
            sharingState.errorMessage = "Finish or cancel bulk preparation before sharing."
            return
        }
        let (drafts, omission) = SharedMarginTextRequirement.shareable(sharingState.drafts.filter(\.isIncluded), text: \.approvedTranscript)
        guard !drafts.isEmpty else {
            sharingState.errorMessage = omission ?? "Select at least one Margin with reviewed text."
            return
        }
        sharingState.isExporting = true
        sharingState.errorMessage = nil
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: selectedItem.id)
            let itemIdentity = sharedItemIdentity(for: item, drafts: drafts)
            let itemTransport = SharedMarginExport.itemTransport(item: item, identity: itemIdentity, isAppAuthored: sharingState.isAppAuthoredItem, confirmsPrivateRights: sharingState.confirmsPrivateSharingRights)
            var machineEvidence: [ReviewedMachineEvidenceAsset] = []
            var selections: [ReviewedInterjectionSelection] = []

            for (index, draft) in drafts.enumerated() {
                let revisionID = "share-revision-\(UUID().uuidString.lowercased())"
                let cleanedPath = draft.representationChoice == .cleaned ? draft.cleanedAudioURL?.path : nil
                let revision = InterjectionShareRevision(
                    id: revisionID,
                    interjectionId: draft.interjection.id,
                    itemId: draft.interjection.itemId,
                    sessionId: draft.interjection.sessionId,
                    createdAt: Date(),
                    approvedTranscript: draft.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                    cleanedAudioPath: cleanedPath,
                    cleanedAudioDurationMs: draft.representationChoice == .cleaned ? draft.cleanedAudioDurationMs : nil,
                    decisions: draft.cleanup?.decisions ?? [],
                    anchorBefore: draft.anchorBefore,
                    anchorAfter: draft.anchorAfter,
                    status: .senderApproved
                )
                try store.saveInterjectionShareRevision(revision)

                let evidence = sharingState.includesAcousticEvidence
                    ? (draft.interjection.podcastAnchorEvidence ?? []).filter { FileManager.default.fileExists(atPath: $0.localPath) }
                    : []
                machineEvidence.append(contentsOf: evidence.map {
                    ReviewedMachineEvidenceAsset(
                        id: $0.id,
                        path: "assets/evidence/\($0.id).shazamsignature",
                        sourceURL: URL(fileURLWithPath: $0.localPath),
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: ($0.provenance ?? .exactLocalPlaybackEdition).rawValue
                    )
                })
                let anchor = SharedMarginExport.anchor(
                    for: draft.interjection,
                    item: item,
                    isNativeAudio: selectedItem.isNativeAudio,
                    mediaChapters: selectedItem.mediaChapters,
                    machineEvidenceAssetIds: evidence.map(\.id)
                )
                let representation: ReviewedRepresentationSelection
                switch draft.representationChoice {
                case .original:
                    guard let url = draft.interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)),
                          let duration = audioDurationMs(at: url) else {
                        throw SessionKitError.persistenceFailed("selected_original_margin_audio_unavailable")
                    }
                    representation = .originalAudio(sourceURL: url, durationMs: duration)
                case .cleaned:
                    guard let url = draft.cleanedAudioURL else {
                        throw SessionKitError.persistenceFailed("selected_cleaned_margin_audio_unavailable")
                    }
                    representation = .cleanedAudio(sourceURL: url)
                case .textOnly:
                    representation = .textOnly
                }
                selections.append(ReviewedInterjectionSelection(
                    packageScopedId: String(format: "margin-%04d", index + 1),
                    revision: revision,
                    anchor: anchor,
                    representation: representation, replyTo: draft.interjection.replyTo
                ))
            }

            let mapProposals = SharedMarginExport.mapProposals(try store.loadPortableListeningMapProposals(itemId: item.id))
            let fingerprintSpines = sharingState.includesAcousticEvidence
                ? try store.loadEditionFingerprintSpine(itemId: item.id).map { [$0] } ?? []
                : []
            let phraseSketches = try store.loadTranscriptPhraseSketch(itemId: item.id).map { [$0] } ?? []
            if let spine = fingerprintSpines.first {
                let directory = try episodeMapDirectory(itemId: item.id)
                let existingEvidenceIDs = Set(machineEvidence.map(\.id))
                for landmark in spine.landmarks where !existingEvidenceIDs.contains(landmark.signatureAssetId) {
                    let url = directory.appending(path: "\(landmark.signatureAssetId).shazamsignature")
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    machineEvidence.append(ReviewedMachineEvidenceAsset(
                        id: landmark.signatureAssetId,
                        path: "assets/evidence/\(landmark.signatureAssetId).shazamsignature",
                        sourceURL: url,
                        durationMs: max(1, landmark.sourceMediaEndMs - landmark.sourceMediaStartMs),
                        anchorOffsetMs: 0,
                        provenance: landmark.provenance.rawValue
                    ))
                }
            }

            let packageID = "package-\(UUID().uuidString.lowercased())"
            let prepared = try SpokenMarginsPackageBuilder.prepare(
                packageId: packageID,
                createdAt: Date(),
                item: itemIdentity,
                itemTransportSelection: itemTransport,
                selections: selections,
                mapProposals: mapProposals, localSourceTexts: [item.text, store.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.text).joined(separator: " ")].compactMap { $0 },
                fingerprintSpines: fingerprintSpines,
                phraseSketches: phraseSketches,
                machineEvidence: machineEvidence,
                senderDisplayLabel: sharingState.senderDisplayLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            let directory = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/SharedPackages", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(SharedMarginExport.fileName(item.title))-\(packageID.suffix(8)).spokenmargins")
            let writtenManifest = try SpokenMarginsPackageArchive.write(prepared, to: destination); try? SpokenMarginsPackageExportRecord.recordExport(manifest: writtenManifest, selections: selections, repository: store) // replies link back through the recorded identity; the share still succeeds without it (#473)
            listeningSignals.export(itemId: item.id, packetId: packageID, marginCount: drafts.count, packetURL: destination)
            UserDefaults.standard.set(sharingState.senderDisplayLabel, forKey: "sharingSenderDisplayLabel")
            sharedSpokenMarginsPackageURL = destination
            sharingState.isExporting = false
            if presentsReadySheet {
                isSharingInterjectionsPresented = false
                isSharedSpokenMarginsPackagePresented = true
            }
            diagnostics["lastSharedPackage"] = "margins=\(drafts.count);evidence=\(machineEvidence.count);map=\(mapProposals.isEmpty ? "preparing_or_unavailable" : "included")"
            if let omission { reportWarning(omission) }
        } catch {
            sharingState.isExporting = false
            sharingState.errorMessage = error.localizedDescription
            diagnostics["lastSharedPackageFailure"] = String(describing: error)
        }
    }

    private func sharedItemIdentity(
        for item: Item,
        drafts: [ShareInterjectionDraft]
    ) -> SharedItemIdentity {
        SharedItemIdentityBuilder.exportIdentity(
            for: item,
            draftEditionDigests: drafts.map(\.interjection.sourceExactEditionSHA256),
            localAudioDigest: localAudiobookDigest(for: item)
        )
    }

    /// Mirrors the link the packet builder keeps, so the share screen never promises a private feed link (#168).
    private func secureSharedItemURL(for item: Item) -> String? {
        ShareableLinkPolicy.shareableLink(
            item.externalReference.flatMap(SharedItemIdentityBuilder.normalizedSharingURL)
                ?? item.media?.url.flatMap(SharedItemIdentityBuilder.normalizedSharingURL)
        )
    }

    private func sharedItemType(for item: Item) -> SharedItemType {
        SharedPacketItemMatcher.itemType(for: item)
    }

    private func audioDurationMs(at url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return max(1, Int((Double(file.length) / file.processingFormat.sampleRate * 1_000).rounded()))
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

    func resolvedInterjectionAudioURL(for path: String) -> URL? {
        Self.resolvedInterjectionAudioURL(
            for: path,
            applicationSupportDirectory: try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        )
    }

    private func resolvedApplicationSupportAssetURL(for path: String) -> URL? {
        Self.resolvedApplicationSupportAssetURL(
            for: path,
            applicationSupportDirectory: try? applicationSupportDirectory()
        )
    }

    private func recordAnchorCaptureDiagnostics(for interjection: Interjection) {
        diagnostics[Self.marginDiagnosticKey("interjectionAnchorAtCapture", interjection)] = [
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

    private func currentDiscussionInterjections() -> [Interjection] {
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

    private func resolvedFolderURL(_ setting: SavedFolderSetting) -> URL? {
        do {
            return try setting.resolvedURL()
        } catch {
            diagnostics["\(setting.bookmarkKey)Error"] = String(describing: error)
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

    func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    /// Records a successful outcome and presents it only when the result is not
    /// otherwise apparent from the current interface.
    func reportConfirmation(_ message: String, action: UserFeedbackEvent.Action? = nil) {
        reportSuccess(message)
        presentFeedback(UserFeedbackEvent(kind: .success, message: message, action: action))
    }

    /// Presents degraded-but-successful behavior without styling it as either a
    /// normal confirmation or a failure.
    func reportWarning(_ message: String) {
        statusMessage = message
        lastError = nil
        presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    func reportFailure(_ error: Error, context: String? = nil, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil) {
        let message: String
        if let urlError = error as? URLError {
            message = Self.userFacingMessage(for: urlError)
        } else if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "), itemId: itemId, retry: retry)
    }

    func reportFailure(_ message: String, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil) {
        statusMessage = "Error"
        lastError = message
        presentFeedback(UserFeedbackEvent(kind: .error, message: message, retry: retry))
        itemFailures.record(message, itemId: itemId, visibleItemId: screen == .item ? selectedItem.id : screen == .playback ? snapshot.itemId ?? "" : "")
        diagnostics["recentFailure"] = message
    }

    func presentFeedback(_ event: UserFeedbackEvent) {
        guard feedbackEvent?.mayBeReplaced(by: event) ?? true else { return }
        feedbackEvent = event
    }

    private func refreshSelectedItem() {
        guard let store, !activeItemId.isEmpty else { return }
        if let detail = try? loadItemDetail(id: activeItemId, store: store) {
            selectedItem = detail
            selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: activeItemId)
            offerFollowSuggestionIfEligible(itemId: activeItemId, store: store)
        }
    }

    private func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard UITestingHooks.seed.seedsGeneratedTimeline,
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
        guard let note = UITestingHooks.summaryInterjectionNote,
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
        var map = try store.loadListeningMap(itemId: id)
        let canonicalSource = try store.loadCanonicalSource(itemId: id)
        if map == nil,
           let canonicalSource,
           let derivedMap = canonicalSource.derivedListeningMap() {
            try store.saveListeningMap(derivedMap)
            map = derivedMap
        }
        let mediaTimeline = try store.loadTranscriptTimeline(itemId: id)?.timeline
        let mediaChapters = mediaTimeline?.chapters ?? []
        let projection = try store.loadResolvedListeningMapProjection(itemId: id)
        let proposal = SharedListeningMapPlacement.proposal(
            for: projection, committed: try store.loadPortableListeningMapProposals(itemId: id),
            layers: try store.loadImportedCommentaryLayers(itemId: id))
        let listeningMapScenes = SceneStarts(scenes: proposal?.scenes ?? [], projection: projection).chapters
        let sessions = try store.loadSessions(itemId: id)
        // A snapshot session is valid only for its own item. Without this
        // ownership check, an asynchronous selection bug can display one
        // item's title with another item's interjections and turns.
        let snapshotSessionId = snapshot.itemId == id ? snapshot.sessionId : nil
        let activeSessionId = snapshotSessionId.flatMap { candidate in
            sessions.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? sessions.first?.id
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
        let importedLayers = try store.loadImportedCommentaryLayers(itemId: id)
            .filter { $0.deletedAt == nil }
        let importedInterjections = Dictionary(uniqueKeysWithValues: importedLayers.map { layer in
            (layer.id, (try? store.loadImportedCommentaryInterjections(layerId: layer.id)) ?? [])
        })
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            overview: map?.overview ?? "",
            navigation: canonicalSource?.navigation ?? [],
            chapters: map?.chapters ?? [],
            mediaChapters: mediaChapters,
            listeningMapScenes: listeningMapScenes,
            mediaDurationMs: item.media?.durationMs ?? mediaTimeline?.durationMs,
            isNativeAudio: isNativeAudio,
            documentStructure: item.documentStructure,
            sessions: sessions,
            sessionRows: sessionRows,
            interjections: interjections,
            importedCommentaryLayers: importedLayers,
            importedCommentaryInterjections: importedInterjections,
            sharedMarginPlacement: sharedMarginPlacementPasses.pass(itemId: item.id),
            turns: turns
        )
    }

    private func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let url = try databaseURL()
        let store = try SQLiteSessionStore(path: url.path)
        self.store = store
        try configurePodcastDownloads(store: store)
        return store
    }

    private func configurePodcastDownloads(store: SQLiteSessionStore) throws {
        try configureOfflineServices(store: store)
        podcastDownloadCoordinator?.shutdown()
        let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) ?? .defaultValue
        let coordinator = try PodcastDownloadCoordinator(
            store: store,
            ledger: try requireOfflineLedger(
                store: store,
                rootDirectory: try applicationSupportDirectory()
            ),
            applicationSupportDirectory: try applicationSupportDirectory(),
            cacheLimit: limit,
            monitorsNetwork: !Self.isRunningUnitTests,
            connectivity: connectivity,
            usesBackgroundSession: !Self.isRunningUnitTests
        )
        coordinator.onRecordChanged = { [weak self] record in
            guard let self else { return }
            podcastDownloadRecords[record.itemId] = record
            if let index = libraryItems.firstIndex(where: { $0.id == record.itemId }) {
                let state = LibraryOfflineStateFilter.forItem(
                    preparedState: nil,
                    mediaSourceType: nil,
                    podcastDownloadState: record.state
                )
                if libraryItems[index].offlineState != state {
                    libraryItems[index].offlineState = state
                }
            }
            if diagnostics["podcastDownload:\(record.itemId)"] != record.state.rawValue {
                recordDeveloperDiagnostic("download.state", ["item": DeveloperDiagnosticRecording.token(record.itemId),
                    "state": record.state.rawValue, "bytes": String(record.bytesWritten),
                    "failure": DeveloperDiagnosticRecording.token(record.failureReason)])
            }
            diagnostics["podcastDownload:\(record.itemId)"] = record.state.rawValue
        }
        coordinator.onLocalAssetReady = { [weak self] itemId, url in
            self?.podcastLocalAssetDidBecomeReady(itemId: itemId, url: url)
        }
        podcastDownloadCoordinator = coordinator
        podcastDownloadRecords = coordinator.recordsByItemId
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
    }

    private func enqueueExplicitAudioPreparation(item: Item) async {
        guard let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store),
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        do {
            allowAudioPreparation(itemId: item.id)
            failedStartupAudioPreparationItemIds.remove(item.id)
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                reportFailure("The bundled speech assets are unavailable.")
                return
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            currentSupertonicRenderSignature = signature
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            guard !plan.isEmpty else { return }
            let manifest = try await coordinator.begin(
                itemId: item.id,
                sourceText: sourceText,
                signature: signature,
                plan: plan
            )
            guard manifest.state != .readyOffline else {
                try refreshLibraryRows(store: store)
                reportConfirmation("\(item.title) is already available offline.")
                return
            }
            var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                ?? AudioPreparationJob(
                    id: "job-\(manifest.id)",
                    itemId: item.id,
                    manifestId: manifest.id,
                    policy: .explicit
                )
            job.policy = .explicit
            job.userPriority = 0
            job.maximumChunkCount = nil
            job.requestedAt = Date()
            job.isCancelled = false
            try store.saveAudioPreparationJob(job)
            try refreshLibraryRows(store: store)
            diagnostics["explicitAudioPreparation:\(item.id)"] = "queued"
            reportConfirmation("Prioritized \(item.title) for audio preparation.")
            startForegroundAudioPreparationIfNeeded()
        } catch {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
            reportFailure(error, context: "Preparing audio failed to start")
        }
    }

    private func startForegroundAudioPreparationIfNeeded() {
        requestContinuedAudioPreparationIfNeeded() // before the guard: a loop may already be running when the listener asks (#905)
        guard foregroundAudioPreparationTask == nil else { return }
        foregroundAudioPreparationGeneration += 1
        let generation = foregroundAudioPreparationGeneration
        foregroundAudioPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runForegroundPreparationLoop { await self.performBackgroundAudioPreparationPass(foregroundDemandOnly: true) }
            let ownsLoop = self.foregroundAudioPreparationGeneration == generation
            if ownsLoop || self.foregroundAudioPreparationTask == nil {
                // Also when cancelled between passes: its item stops showing progress (#281).
                let resume = ownsLoop ? self.libraryAudioTurns.foregroundLoopEnded() : false
                if !ownsLoop { self.libraryAudioTurns.stopped(.foreground) }
                if ownsLoop { self.foregroundAudioPreparationTask = nil }
                if ownsLoop, Task.isCancelled || resume, self.playbackAllowsLibraryAudioPreparation {
                    self.startForegroundAudioPreparationIfNeeded()
                }
                if let store = self.store {
                    try? self.refreshLibraryRows(store: store)
                }
            }
        }
    }

    #if canImport(BackgroundTasks) && canImport(UIKit)
    /// The background task stopped: its item stops showing progress, and the foreground loop picks its own work again (#534).
    private func libraryAudioBackgroundDrainEnded() {
        libraryAudioTurns.stopped(.background)
        if let store { try? refreshLibraryRows(store: store) }
        if canPrepareLibraryAudio, UIApplication.shared.applicationState == .active { startForegroundAudioPreparationIfNeeded() }
    }
    #endif

    private func enqueueAutomaticAudioPreparationJobs() async {
        guard automaticAudioPreparationPolicy == .whileCharging,
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        do {
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else { return }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            currentSupertonicRenderSignature = signature
            let sessionsByItemId = Dictionary(grouping: try store.loadSessions(), by: \.itemId)
            for row in libraryItems {
                guard let item = try? store.loadItem(id: row.id),
                      !LibraryAudioPreparationAdmission.playsItsOwnAudio(item),
                      let text = PreparedSpeechHooks.preparedText(of: item, in: store),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suppressedAutomaticAudioPreparationItemIds.contains(item.id) else { continue }
                guard LibraryAudioPreparationAdmission.admitsAutomatically(item, sessions: sessionsByItemId[item.id] ?? []) else {
                    diagnostics["automaticAudioPreparation:\(item.id)"] = "skipped_existing_progress"
                    continue
                }
                let plan = await Task.detached(priority: .utility) {
                    Self.preparedChunkPlan(for: text)
                }.value
                guard !plan.isEmpty else { continue }
                let manifest = try await coordinator.begin(
                    itemId: item.id,
                    sourceText: text,
                    signature: signature,
                    plan: plan
                )
                guard manifest.state != .readyOffline else { continue }
                var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                    ?? AudioPreparationJob(id: "job-\(manifest.id)", itemId: item.id, manifestId: manifest.id, policy: .whileCharging, requestedAt: item.createdAt ?? Date())
                let unfinishedStartupHorizon = job.policy == .demandWindow
                    && job.maximumChunkCount.map { manifest.chunks.count < $0 } == true
                if !unfinishedStartupHorizon {
                    job.policy = .whileCharging
                    job.maximumChunkCount = nil
                }
                job.isCancelled = false
                try store.saveAudioPreparationJob(job)
            }
            try refreshAudioPreparationPresentation(store: store)
            diagnostics["automaticAudioPreparationQueue"] = "queued"
        } catch {
            diagnostics["automaticAudioPreparationQueue"] = "failed:\(error.localizedDescription)"
        }
    }

    private var canPrepareLibraryAudio: Bool {
        !preparationSeams.memoryBackoffActive() && playbackAllowsLibraryAudioPreparation
    }

    /// The foreground loop and the background task take turns, so two Library items never render at once (#281).
    func performBackgroundAudioPreparationPass(foregroundDemandOnly: Bool = false) async -> Bool {
        await libraryAudioRenderGate.run { await self.preparationPassInTurn(foregroundDemandOnly: foregroundDemandOnly) }
    }

    private func preparationPassInTurn(foregroundDemandOnly: Bool) async -> Bool {
        var attemptedJob: AudioPreparationJob?
        let caller: LibraryAudioPreparationCaller = foregroundDemandOnly ? .foreground : .background
        // Live speech owns the serial renderer while the listener has active
        // demand. A stale/background job must not queue ahead of its next chunk.
        guard canPrepareLibraryAudio else { libraryAudioTurns.stopped(caller); return false }
        guard (foregroundDemandOnly || automaticAudioPreparationPolicy == .whileCharging),
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { libraryAudioTurns.blocked(caller); return false } // settles until these change (#647)
        let device = preparationSeams.deviceConditions() // heat and Low Power Mode, checked per chunk (#64)
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            var queuedJobs = try store.loadAudioPreparationJobs()
                .filter({ !PreparationChunkGate.setsAsideForLowPowerMode($0.policy, thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) })
            if !foregroundDemandOnly, !queuedJobs.contains(where: { !$0.isCancelled }),
               PreparationChunkGate.allowsAutomaticWork(thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) {
                await enqueueAutomaticAudioPreparationJobs()
                queuedJobs = try store.loadAudioPreparationJobs()
            }
            let hasMoreMatchingJobs = { try !LibraryAudioPreparationTurns.eligible(store.loadAudioPreparationJobs(), for: caller).isEmpty }
            let previous = libraryAudioPreparingItemId // nil job: nothing to do, or the foreground loop waits for the background task (#534)
            guard var job = libraryAudioTurns.select(queuedJobs, activeItemId: activePlaybackItemId, for: caller) else { libraryAudioTurns.stopped(caller); return false }
            if let previous, previous != job.itemId,
               libraryItems.first(where: { $0.id == previous })?.startupAudioState == .preparing { updateLibraryStartupAudioState(itemId: previous, state: .waiting) }
            if libraryItems.first(where: { $0.id == job.itemId })?.startupAudioState == .waiting { updateLibraryStartupAudioState(itemId: job.itemId, state: .preparing) }
            guard var manifest = try store.loadPreparedAudioManifest(id: job.manifestId),
                  let item = try? store.loadItem(id: job.itemId), item.deletedAt == nil, // a job saved back mid-render for an item since trashed (#883)
                  let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store) else {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["backgroundAudioPreparation"] = "discarded_missing_source_job"
                return try hasMoreMatchingJobs()
            }
            attemptedJob = job
            recordDeveloperDiagnostic("preparation.selected", ["item": DeveloperDiagnosticRecording.token(job.itemId), "policy": String(describing: job.policy), "nextChunk": String(job.nextChunkIndex)])
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                return !foregroundDemandOnly
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            guard manifest.signature == signature else {
                manifest.state = .needsRepreparation
                manifest.updatedAt = Date()
                try store.savePreparedAudioManifest(manifest)
                try store.deleteAudioPreparationJob(id: job.id)
                return try hasMoreMatchingJobs()
            }
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            let eligiblePlan = Self.preparationHorizon(
                plan: plan,
                maximumChunkCount: job.maximumChunkCount
            )
            let ledger = requireOfflineLedger(store: store, rootDirectory: support)
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            let atRender = preparationSeams.deviceConditions() // read again here: heat can rise during the setup above (Codex audit on 27fd1bd)
            let gate = try PreparationChunkGate.decide(policy: job.policy, thermal: atRender.thermal, isLowPowerModeEnabled: atRender.isLowPowerModeEnabled,
                                                       itemAlreadyListened: item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(store.loadSessions(itemId: item.id)))
            let gated = try await coordinator.applyGate(gate, manifestId: manifest.id) // applied to the saved manifest: chunks committed meanwhile stay
            manifest = gated.manifest ?? manifest
            if gated.changed { try refreshLibraryRows(store: store) }
            if gate == .dropListenedItem {
                // Removing speculative work must never invalidate committed audio.
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["automaticAudioPreparation:\(item.id)"] = "cancelled_existing_progress"
                return try hasMoreMatchingJobs()
            }
            guard gate == .render else { diagnostics["backgroundAudioPreparation"] = gate.rawValue; return false }
            manifest = try await coordinator.droppingMissingChunks(manifestId: manifest.id) ?? manifest // a lost chunk is rendered again, not assembled (#645)
            let completedIndexes = PreparedAudioCoordinator.completedIndexes(manifest, plan: plan, sourceText: sourceText, retryingStandInsFor: job)
            guard let next = eligiblePlan.first(where: { !completedIndexes.contains($0.index) }) else {
                // All chunks are intact but nothing is assembled (#278): assemble now, because it
                // otherwise happens only right after the last chunk is committed.
                if manifest.isCompleteButUnassembled, manifest.plannedChunkCount == plan.count, completedIndexes.count == plan.count {
                    try await finishBackgroundPreparedAudio(
                        item: item, sourceText: sourceText, voice: voice, signature: signature,
                        manifest: manifest, plan: plan, store: store, ledger: ledger,
                        coordinator: coordinator, support: support
                    )
                }
                try store.deleteAudioPreparationJob(id: job.id)
                return try hasMoreMatchingJobs()
            }
            let reservation = try await ledger.reserve(
                ownerId: "prepared-chunk-\(manifest.id)-\(next.index)",
                byteCount: 64 * 1_024 * 1_024,
                pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: manifest) // never evicts this article's own chunks (#645)
            )
            // Paced per render, not through the shared lifecycle flag (#377).
            let pacedRenderer: any SupertonicRendering = try preparationSeams.renderer?() ?? BackgroundPreparationRenderer(base: makeSupertonicRenderer())
            if try await preparationHeldAtRenderStart(policy: job.policy, manifestId: manifest.id, reservationId: reservation.id, ledger: ledger, coordinator: coordinator, store: store) != nil { return false }
            var renderStarted = Date(), renderMs = 0
            do {
                try Task.checkCancellation()
                renderStarted = Date()
                recordDeveloperDiagnostic("preparation.render.begin", ["item": DeveloperDiagnosticRecording.token(item.id), "chunk": String(next.index), "thermal": atRender.thermal.rawValue])
                // The render is discarded once committed (copied), or on any failure.
                try await supertonicOutputGuard(wrapping: pacedRenderer, systemVoice: speechVoiceIdentifier).render(
                    text: next.text, voice: voice, language: "en", speed: 1, synthesisSteps: 8
                ) { rendered in
                    renderMs = Int(Date().timeIntervalSince(renderStarted) * 1_000) // the render alone, before the copy and saves (Codex audit on e5088b9)
                    try Task.checkCancellation()
                    guard !suppressedAutomaticAudioPreparationItemIds.contains(item.id) else {
                        throw CancellationError()
                    }
                    try await coordinator.commit(
                        itemId: item.id,
                        signature: signature,
                        plan: next,
                        sourceText: sourceText,
                        audioURL: rendered.audioURL,
                        durationMs: Int((rendered.duration * 1_000).rounded()), engine: rendered.engine
                    )
                }
            } catch {
                try? await ledger.release(reservationId: reservation.id)
                throw error
            }
            guard let updated = try store.loadPreparedAudioManifest(id: manifest.id),
                  let committed = updated.chunks.first(where: { $0.index == next.index }) else {
                try? await ledger.release(reservationId: reservation.id)
                return !foregroundDemandOnly
            }
            try await ledger.commit(reservationId: reservation.id, asset: PreparedAudioCoordinator.ledgerAsset(for: committed, itemId: item.id))
            job = (try store.loadAudioPreparationJobs()).first(where: { $0.id == job.id }) ?? job
            recordDeveloperDiagnostic("preparation.committed", ["item": DeveloperDiagnosticRecording.token(item.id), "chunks": String(updated.chunks.count),
                                                                "renderMs": String(renderMs), "thermal": SupertonicResourcePolicy.currentConditions().thermal.rawValue])
            job.nextChunkIndex = updated.chunks.count
            job.lastFailureCode = PreparedAudioCoordinator.hasStandIns(updated) ? PreparedAudioCoordinator.standInRetried : nil
            if PreparedAudioCoordinator.matchingChunks(in: updated, plan: plan, sourceText: sourceText).count == plan.count {
                try store.saveAudioPreparationJob(job)
                try await finishBackgroundPreparedAudio(
                    item: item,
                    sourceText: sourceText,
                    voice: voice,
                    signature: signature,
                    manifest: updated,
                    plan: plan,
                    store: store,
                    ledger: ledger,
                    coordinator: coordinator,
                    support: support
                )
            } else if let maximumChunkCount = job.maximumChunkCount {
                let horizon = plan.prefix(min(maximumChunkCount, plan.count))
                if PreparedAudioCoordinator.isPrepared(Array(horizon), in: updated, sourceText: sourceText) {
                    if automaticAudioPreparationPolicy == .whileCharging {
                        job.policy = .whileCharging
                        job.maximumChunkCount = nil
                        try store.saveAudioPreparationJob(job)
                    } else {
                        try store.deleteAudioPreparationJob(id: job.id)
                    }
                    diagnostics["startupAudioPreparation:\(item.id)"] = "ready_\(horizon.count)_of_\(plan.count)"
                } else {
                    try store.saveAudioPreparationJob(job)
                }
            } else {
                try store.saveAudioPreparationJob(job)
            }
            applyPreparedChunkProgress(item: item, manifest: updated,
                                       remainingJobs: try store.loadAudioPreparationJobs())
            let hasMore = try hasMoreMatchingJobs()
            diagnostics["backgroundAudioPreparation"] = hasMore ? "chunk_committed" : "complete"
            return hasMore
        } catch is CancellationError {
            if var job = attemptedJob,
               !suppressedAutomaticAudioPreparationItemIds.contains(job.itemId),
               let store {
                job.lastFailureCode = "background_time_expired"
                try? store.saveAudioPreparationJob(job)
                try? refreshAudioPreparationPresentation(store: store)
            }
            diagnostics["backgroundAudioPreparation"] = "expired"
            return !foregroundDemandOnly
        } catch {
            if var job = attemptedJob, let store {
                job.lastFailureCode = String(describing: type(of: error))
                try? store.saveAudioPreparationJob(job)
                if job.maximumChunkCount != nil {
                    failedStartupAudioPreparationItemIds.insert(job.itemId)
                }
                try? refreshLibraryRows(store: store)
            }
            diagnostics["backgroundAudioPreparation"] = "paused:\(error.localizedDescription)"
            if attemptedJob?.policy == .explicit {
                reportWarning("Audio preparation paused: \(error.localizedDescription)")
            }
            return false
        }
    }

    nonisolated static func audioPreparationJobPrecedes(
        _ lhs: AudioPreparationJob,
        _ rhs: AudioPreparationJob
    ) -> Bool {
        audioPreparationJobPrecedes(lhs, rhs, activeItemId: nil)
    }

    nonisolated static func audioPreparationJobPrecedes(
        _ lhs: AudioPreparationJob,
        _ rhs: AudioPreparationJob,
        activeItemId: String?
    ) -> Bool {
        LibraryAudioPreparationQueue.precedes(lhs, rhs, activeItemId: activeItemId)
    }

    private func finishBackgroundPreparedAudio(
        item: Item,
        sourceText: String,
        voice: SupertonicVoiceID,
        signature: TTSRenderSignature,
        manifest: PreparedAudioManifest,
        plan: [PreparedChunkPlan],
        store: SQLiteSessionStore,
        ledger: OfflineStorageLedger,
        coordinator: PreparedAudioCoordinator,
        support: URL
    ) async throws {
        // A stand-in (iOS voice) chunk waits for a play to retry Supertonic; don't bake it in (#363).
        guard !PreparedAudioCoordinator.hasStandIns(manifest) else { return }
        // Narration replaces Item.text with its own, so it keeps Item.text and maps into it (#336).
        guard let speech = PreparedSpeechHooks.texts.resolve(item: item, documents: store), speech.text == sourceText else { return }
        let chunks = try PreparedAudioCoordinator.assemblyChunks(
            plan: plan, manifest: manifest, sourceText: sourceText,
            preparedRoot: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        )
        let assemblyReservation = try await ledger.reserve(
            ownerId: "prepared-artifact-\(manifest.id)",
            byteCount: max(1, manifest.chunks.reduce(0) { $0 + $1.byteCount }),
            pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: manifest) // its inputs stay until assembled (#645)
        )
        do {
            let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                itemId: item.id,
                sourceText: speech.itemText,
                projection: speech.assemblyProjection(),
                voice: voice,
                chunks: chunks,
                outputDirectory: support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            )
            guard attachPreparedTextAudio(prepared, itemId: item.id, replaceActivePlayback: false),
                  let rawURL = prepared.media.url,
                  let url = URL(string: rawURL) else {
                throw SessionKitError.persistenceFailed("prepared_audio_attach_failed")
            }
            try await coordinator.complete(itemId: item.id, signature: signature, prepared: prepared)
            try refreshLibraryRows(store: store)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
            try await ledger.commit(
                reservationId: assemblyReservation.id,
                asset: OwnedOfflineAsset(
                    id: "prepared-artifact-\(manifest.id)",
                    itemId: item.id,
                    category: .preparedAudio,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0),
                    isReproducible: true
                )
            )
            for asset in try store.loadOwnedOfflineAssets() where asset.itemId == item.id && asset.category == .preparedChunk {
                try store.updateOwnedOfflineAsset(id: asset.id) { $0.isRedundant = true }
            }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }

    private nonisolated static let preparationPlanCache = PreparedChunkPlanCache()

    private nonisolated static func preparedChunkPlan(for sourceText: String) -> [PreparedChunkPlan] {
        preparationPlanCache.value(for: sourceText) { PreparedChunkPlan.articlePlan(sourceText) }
    }

    nonisolated static func preparationHorizon(
        plan: [PreparedChunkPlan],
        maximumChunkCount: Int?
    ) -> [PreparedChunkPlan] {
        Array(plan.prefix(min(maximumChunkCount ?? plan.count, plan.count)))
    }

    private func configureOfflineServices(store: SQLiteSessionStore) throws {
        let support = try applicationSupportDirectory()
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support)
        offlineStorageLedger = ledger
        localSourceImporter = LocalSourceImporter(
            repository: store,
            ledger: ledger,
            applicationSupportDirectory: support
        )
        followedSourceCoordinator = FollowedSourceCoordinator(repository: store, artworkFile: support.appending(path: FollowingArtworkCache.fileName))
        guidedOnboardingCoordinator = GuidedOnboardingCoordinator(
            directory: support.appending(path: "GuidedOnboarding", directoryHint: .isDirectory),
            ledger: ledger
        )
        Task {
            try? store.saveOfflineStorageBudget(OfflineStorageBudget(
                limitBytes: Int64(self.offlineStorageLimitGB) * OfflineStorageBudget.bytesPerGigabyte
            ))
            try? await ledger.adoptExistingAssets()
            let residualOverage = try? await ledger.enforceBudget()
            let reconciled = await ledger.lastReconciliation?.summary ?? "failed"
            let ledgerBytes = try? await ledger.inventoryBytes()
            let filesystemBytes = await ledger.directFilesystemBytes()
            await MainActor.run { [weak self] in
                self?.diagnostics["offlineLedgerReconciled"] = reconciled
                self?.diagnostics["offlineLedgerBytes"] = "\(ledgerBytes ?? 0)"
                self?.diagnostics["offlineFilesystemBytes"] = "\(filesystemBytes)"
                self?.diagnostics["offlineResidualOverageBytes"] = "\(residualOverage ?? 0)"
                self?.tryRefreshOfflineStorageUsage()
            }
            await self.performFollowedSourceRefresh(force: false)
            await self.refreshGuidedOnboardingContent()
        }
    }

    private func refreshGuidedOnboardingContent() async {
        guard !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
              let coordinator = guidedOnboardingCoordinator,
              let store else { return }
        do {
            let payload = try await coordinator.refresh()
            let priorChecksum = UserDefaults.standard.string(forKey: "guidedOnboardingAudioChecksum")
            var item = (try? store.loadItem(id: Self.guidedOnboardingItemId)) ?? Self.makeBundledGuidedOnboardingItem()
            item.title = payload.manifest.title
            item.sourceTitle = "Spoken Margins"
            item.media = ItemMedia(
                sourceType: .nativeMediaFile,
                url: payload.audioURL.absoluteString,
                nativeMediaId: "guided-onboarding-audio"
            )
            try store.saveItem(item)
            try store.saveAudioAsset(AudioAsset(
                id: "guided-onboarding-audio",
                itemId: item.id,
                audioSourceType: .nativeMediaFile,
                availability: .localPhone,
                url: payload.audioURL.absoluteString,
                title: payload.manifest.title
            ))
            try store.saveTranscriptTimeline(SourceTranscriptTimeline(
                id: "timeline-guided-onboarding",
                itemId: item.id,
                createdAt: Date(),
                timeline: TranscriptTimeline(
                    segments: [],
                    chapters: [
                        MediaTimelineChapter(
                            id: "guided-onboarding-core-loop",
                            title: "The Core Loop",
                            startMs: 0,
                            transcriptSegmentId: "guided-onboarding-core-loop"
                        )
                    ]
                )
            ))
            UserDefaults.standard.set(payload.manifest.audioChecksumSHA256, forKey: "guidedOnboardingAudioChecksum")
            if payload.audioChanged, priorChecksum != nil, snapshot.itemId == item.id {
                _ = try? engine?.stopPlayback()
                snapshot = SessionSnapshot()
                diagnostics["guidedOnboardingProgress"] = "reset_for_audio_change"
            }
            try refreshLibraryRows(store: store)
            diagnostics["guidedOnboardingRemote"] = "ready:v\(payload.manifest.contentVersion)"
        } catch {
            diagnostics["guidedOnboardingRemote"] = "fallback:\(String(describing: type(of: error)))"
        }
    }

    func followSource() {
        let value = followedSourceURL
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let candidates = try await coordinator.discover(urlString: value)
                self.diagnostics["followedSourceNetworkHosts"] = await coordinator.contactedHosts.sorted().joined(separator: ",")
                guard candidates.count == 1, let candidate = candidates.first, !candidate.needsConfirmation else {
                    self.followedSourceCandidates = candidates
                    self.reportConfirmation("Choose which feed to follow.")
                    return
                }
                _ = try await coordinator.follow(candidate: candidate)
                self.followedSourceCandidates = []
                self.followedSourceURL = ""
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    /// #244: a failed Follow said only "FollowedSourceError". Record the case, host and steps.
    private func recordFollowFailure(_ error: Error) async {
        var line = FollowedSourceCoordinator.diagnosticCode(for: error)
        if let coordinator = followedSourceCoordinator { line = await coordinator.failureDiagnostic(for: error) }
        diagnostics["followSourceFailure"] = FollowedSourceMatching.stampedDiagnostic(line)
    }

    /// B1 drawer and OPML import (#463): follows a public https feed link. Throws so the caller
    /// can show the failure on the row. Returns the followed source's id, which the drawer keeps:
    /// the feed can settle on another URL. An import refreshes once at the end, not per feed.
    func followCatalogFeed(_ feedURL: String, refreshAfter: Bool = true) async throws -> String {
        let store = try requireStore()
        let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
        followedSourceCoordinator = coordinator
        let sourceId = try await coordinator.followFeed(urlString: feedURL).source.id
        diagnostics["followSourceFailure"] = nil
        if refreshAfter { await performFollowedSourceRefresh(force: false) }
        return sourceId
    }

    /// Read from the store: `feedSubscriptions` lags a follow until its refresh lands (#463).
    func storedFeedSubscriptions() -> [FeedSubscription] { (try? store?.loadFeedSubscriptions()) ?? feedSubscriptions }

    func followSourceCandidate(_ candidate: SourceCandidateEvidence) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                _ = try await coordinator.follow(candidate: candidate)
                self.followedSourceCandidates = []
                self.followedSourceURL = ""
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    func cancelFollowSourceCandidates() {
        followedSourceCandidates = []
    }

    /// Follow shows only once discovery found a feed for the selected item (#280).
    var canManuallyFollowSelectedSource: Bool {
        guard sourceFollowSuggestionCandidates.isEmpty, selectedFollowOffer != nil else { return false }
        let row = libraryItems.first(where: { $0.id == selectedItem.id })
        return !FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: row?.sourceURL,
            sourceTitle: row?.sourceTitle,
            sourceReference: row?.sourceReference,
            subscriptions: feedSubscriptions
        )
    }

    /// Names what will be followed, and is settled when the button first appears (#243, #280).
    var manualFollowButtonTitle: String {
        guard let offer = selectedFollowOffer else { return "" }
        return isFollowingSelectedSource ? offer.followingTitle : offer.title
    }

    var manualFollowButtonSymbol: String {
        selectedFollowOffer?.symbol ?? ManualFollowPolicy.buttonSymbol(mediaType: "podcast")
    }

    /// Built from the same de-duplicated, unfollowed feeds the suggestion card lists, so the
    /// button and the card name the feed the same way.
    private var selectedFollowOffer: FollowOffer? {
        guard let found = followOffers[selectedItem.id] else { return nil }
        return ManualFollowPolicy.offer(
            itemId: found.itemId, mediaType: found.mediaType,
            candidates: FollowedSourceMatching.uniqueUnfollowedCandidates(found.candidates, subscriptions: feedSubscriptions)
        )
    }

    /// Starts feed discovery when an item opens. Follow appears when a feed is found, and never
    /// for a file, a PDF, a Listening Edition or a site with no feed (#280).
    func discoverFollowOfferIfEligible(itemId: String, store: SQLiteSessionStore) {
        guard followOffers[itemId] == nil,
              let item = try? store.loadItem(id: itemId),
              let url = ManualFollowPolicy.discoveryURL(for: item),
              !FollowedSourceMatching.isItemAlreadyFollowed(item, subscriptions: feedSubscriptions) else { return }
        Task { [weak self] in
            guard let self else { return }
            let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
            self.followedSourceCoordinator = coordinator
            var candidates: [SourceCandidateEvidence]?, failure = "none:empty"
            do { candidates = try await self.sharedFollowDiscovery(item: item, preferredURL: url, coordinator: coordinator) } catch { failure = "none:" + FollowedSourceCoordinator.diagnosticCode(for: error) }
            self.diagnostics["followOffer"] = FollowedSourceMatching.discoveryDiagnostic(
                item: item, candidates: candidates, failure: failure, subscriptions: (try? store.loadFeedSubscriptions()) ?? self.feedSubscriptions
            )
        }
    }

    /// One discovery per item and link, shared by the Follow button, the suggestion card and the
    /// tap, so all three show the same feeds and the same name. "No feed" is kept for the session;
    /// other failures (offline, timeouts) are retried on the next open.
    private func sharedFollowDiscovery(
        item: Item,
        preferredURL: URL,
        coordinator: FollowedSourceCoordinator
    ) async throws -> [SourceCandidateEvidence] {
        let key = item.id + "\u{1f}" + preferredURL.absoluteString
        if let task = followDiscoveries[key] { return try await task.value }
        let task = Task { try await self.discoverFollowCandidates(item: item, preferredURL: preferredURL, coordinator: coordinator) }
        followDiscoveries[key] = task
        do {
            let candidates = try await task.value
            // Whichever path ran discovery, the Follow button can use what it found.
            if followOffers[item.id] == nil {
                followOffers[item.id] = ManualFollowPolicy.offer(itemId: item.id, mediaType: item.mediaType, candidates: candidates)
            }
            return candidates
        } catch FollowedSourceError.noFeedCandidates {
            throw FollowedSourceError.noFeedCandidates
        } catch {
            followDiscoveries[key] = nil
            throw error
        }
    }

    func followSelectedSource() {
        guard !isFollowingSelectedSource, let store else { return }
        let itemId = selectedItem.id
        isFollowingSelectedSource = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isFollowingSelectedSource = false }
            do {
                let item = try store.loadItem(id: itemId)
                guard let preferredURL = ManualFollowPolicy.discoveryURL(for: item) else { throw FollowedSourceError.invalidURL }
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let candidates = try await self.sharedFollowDiscovery(
                    item: item,
                    preferredURL: preferredURL,
                    coordinator: coordinator
                )
                guard let candidate = candidates.first else { throw FollowedSourceError.noFeedCandidates }
                guard candidates.count == 1, !candidate.needsConfirmation else {
                    self.followedSourceCandidates = candidates
                    self.reportConfirmation("Choose the source feed to follow.")
                    return
                }
                let subscriptionsBySourceID = Dictionary(
                    uniqueKeysWithValues: try store.loadFeedSubscriptions().map { ($0.source.id, $0) }
                )
                let subscription = if let existing = subscriptionsBySourceID[candidate.source.id] {
                    existing
                } else {
                    try await coordinator.follow(candidate: candidate)
                }
                var updated = item
                updated.sourceURL = subscription.source.canonicalURL
                updated.sourceTitle = updated.sourceTitle ?? subscription.source.title
                if updated != item {
                    try store.saveItem(updated)
                    try self.refreshLibraryRows(store: store)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    func offerFollowSuggestionIfEligible(itemId: String, store: SQLiteSessionStore) {
        guard !sourceSuggestionChecks.contains(itemId),
              sourceFollowSuggestionCandidates.isEmpty,
              // Files, PDFs and Listening Editions get no suggestion card either (#280).
              let item = try? store.loadItem(id: itemId), let url = ManualFollowPolicy.discoveryURL(for: item) else { return }
        // Opening Item loads its sessions synchronously; Home's display cache
        // may still be awaiting refresh or may have been superseded by navigation.
        let persistedProgress = selectedItem.id == itemId
            ? Self.preferredContinuationSession(in: selectedItem.sessions)?.completionPercent
            : libraryItems.first(where: { $0.id == itemId })?.continuationProgressPercent
        let progress = SourceFollowSuggestionPolicy.engagementProgress(
            itemId: itemId, persistedProgress: persistedProgress, snapshot: snapshot
        )
        guard SourceFollowSuggestionPolicy.isEngaged(
            progress: progress, itemHasMargin: selectedItem.id == itemId && !selectedItem.interjections.isEmpty
        ) else { return }
        sourceSuggestionChecks.insert(itemId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceSuggestionChecks.remove(itemId) }
            do {
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                guard !FollowedSourceMatching.isItemAlreadyFollowed(item, subscriptions: try store.loadFeedSubscriptions()) else { return }
                let candidates = try await self.sharedFollowDiscovery(
                    item: item,
                    preferredURL: url,
                    coordinator: coordinator
                )
                guard self.selectedItem.id == itemId,
                      self.screen != .playback || self.snapshot.itemId == itemId,
                      let current = try? store.loadItem(id: itemId),
                      SourceFollowSuggestionPolicy.hasSameOrigin(item, current) else {
                    self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("discarded_stale_origin")
                    return
                }
                // Following may finish while network discovery is suspended.
                let subscriptions = try store.loadFeedSubscriptions()
                self.feedSubscriptions = subscriptions
                let unfollowed = FollowedSourceMatching.uniqueUnfollowedCandidates(candidates, subscriptions: subscriptions)
                guard !FollowedSourceMatching.isItemAlreadyFollowed(current, subscriptions: subscriptions),
                      !unfollowed.isEmpty || candidates.isEmpty else {
                    self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("already_followed")
                    return
                }
                let now = Date()
                let eligible = try FollowedSourceMatching.suggestible(unfollowed, now: now) { try store.loadSourceSuggestionDecision(sourceId: $0) }
                guard !eligible.isEmpty else { return }
                for decision in SourceFollowSuggestionPolicy.promptedDecisions(for: eligible, now: now) {
                    try store.saveSourceSuggestionDecision(decision)
                }
                self.sourceFollowSuggestionItemId = itemId
                self.storedSourceFollowSuggestionCandidates = eligible
                self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("offered:\(eligible.count)")
            } catch { // #539: a background check, not a Follow tap, so no followSourceFailure line.
                self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.discoveryDiagnostic(
                    item: item, candidates: nil, failure: "unavailable:" + FollowedSourceCoordinator.diagnosticCode(for: error),
                    subscriptions: (try? store.loadFeedSubscriptions()) ?? self.feedSubscriptions
                )
            }
        }
    }

    var followCandidateDiscoveryHandler: ((Item, URL) async throws -> [SourceCandidateEvidence])?

    private func discoverFollowCandidates(
        item: Item,
        preferredURL: URL,
        coordinator: FollowedSourceCoordinator
    ) async throws -> [SourceCandidateEvidence] {
        if let followCandidateDiscoveryHandler { return try await followCandidateDiscoveryHandler(item, preferredURL) }
        do {
            return try await coordinator.discover(urlString: preferredURL.absoluteString, requiringItemMembership: item.sourceURL == nil)
        } catch {
            guard let originalReference = item.externalReference,
                  let originalURL = URL(string: originalReference),
                  originalURL.scheme?.lowercased() == "https" else { throw error }
            let resolver = PublicPodcastLinkResolver()
            let canonicalFeed = try await Task.detached {
                try resolver.canonicalFeedURL(for: originalURL)
            }.value
            guard let canonicalFeed else { throw error }
            return try await coordinator.discover(urlString: canonicalFeed.absoluteString)
        }
    }

    func acceptSourceFollowSuggestion(_ candidate: SourceCandidateEvidence) {
        guard sourceFollowSuggestionCandidates.contains(where: { $0.id == candidate.id }) else { return }
        let itemId = sourceFollowSuggestionItemId
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let subscription = try await coordinator.follow(candidate: candidate)
                if let itemId, var item = try? store.loadItem(id: itemId) {
                    item.sourceURL = subscription.source.canonicalURL
                    item.sourceTitle = item.sourceTitle ?? subscription.source.title
                    try store.saveItem(item)
                    try self.refreshLibraryRows(store: store)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                try store.saveSourceSuggestionDecision(SourceSuggestionDecision(sourceId: candidate.source.id, decision: .accepted, lastPromptAt: Date()))
                self.storedSourceFollowSuggestionCandidates = []
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                self.reportFailure(error, context: "Follow suggestion failed")
            }
        }
    }

    func deferSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.notNow)
    }

    func rejectSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.neverSuggest)
    }

    private func persistSourceFollowSuggestionDecision(_ answer: SourceFollowSuggestionPolicy.Answer) {
        guard let store else { return }
        let decisions = SourceFollowSuggestionPolicy.decisions(
            for: answer, candidates: sourceFollowSuggestionCandidates, now: Date()
        ) { try? store.loadSourceSuggestionDecision(sourceId: $0) }
        for decision in decisions {
            try? store.saveSourceSuggestionDecision(decision)
        }
        storedSourceFollowSuggestionCandidates = []
    }

    func refreshFollowedSources(force: Bool = true) {
        Task { [weak self] in await self?.performFollowedSourceRefresh(force: force) }
    }

    func performFollowedSourceRefresh(force: Bool) async {
        guard !isRefreshingFollowedSources else { return }
        isRefreshingFollowedSources = true
        defer { isRefreshingFollowedSources = false }
        do {
            let store = try requireStore()
            let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
            followedSourceCoordinator = coordinator
            for entry in await coordinator.refreshStale(force: force) { importFollowedSourceEntry(entry) } // "Add every new item" (#466)
            feedSubscriptions = try store.loadFeedSubscriptions()
            followedSourceEntries = try await coordinator.entries()
            diagnostics["followedSourceCount"] = "\(feedSubscriptions.count)"
            diagnostics["followedSourceEntryCount"] = "\(followedSourceEntries.count)"
        } catch {
            diagnostics["followedSourceRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func dismissFollowedSourceEntry(id: String) {
        guard let coordinator = followedSourceCoordinator else { return }
        listeningSignals.dismiss(entryId: id)
        Task { [weak self] in
            try? await coordinator.setEntryState(id: id, state: .dismissed)
            await self?.performFollowedSourceRefresh(force: false)
        }
    }

    func importFollowedSourceEntry(_ entry: FeedEntry, openWhenFinished: Bool = false) {
        guard importingFollowedSourceEntryIds.insert(entry.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.importingFollowedSourceEntryIds.remove(entry.id) }
            do {
                guard let url = URL(string: entry.canonicalURL), url.scheme?.lowercased() == "https" else {
                    throw ReadablePageExtractionError.invalidURL
                }
                let store = try self.requireStore()
                guard let subscription = try store.loadFeedSubscriptions().first(where: { $0.id == entry.subscriptionId }) else {
                    throw FollowedSourceError.noFeedCandidates
                }
                let entry = await self.followedSourceCoordinator?.publisherAudioEntry(for: entry) ?? entry
                let imported: Bool
                // Posts with the publisher's own audio (#545) and text-only posts (#641) import as articles.
                let route = try await self.followedSourceCoordinator?.importRoute(for: entry, subscriptionKind: subscription.source.kind)
                    ?? FollowedEntryImportRoute.route(for: entry, subscriptionKind: subscription.source.kind, audio: .stored(in: entry))
                if case .episode(let importURL) = route {
                    let importedItemId = try await self.importSourceLinkInBackground(SourceLinkHandoff(
                        id: "quick-add-\(entry.id)",
                        inputURL: importURL,
                        sourceSurface: "followed_source",
                        startSession: false
                    ), feedEntry: entry, subscription: subscription)
                    imported = importedItemId != nil
                    if openWhenFinished, let importedItemId { self.openItem(id: importedItemId) }
                } else {
                    let handoff = self.listeningSignals.followedArticle(try await FollowedArticleImport.handoff(for: entry, url: url, using: self.readablePageExtractor, record: { self.diagnostics.merge($0) { _, new in new } }), for: entry)
                    // With something already playing, importBrowserText only adds; Add and open still opens it (#567).
                    if openWhenFinished, !entry.hasPublisherAudio, !self.hasActiveSession {
                        imported = self.importBrowserTextItem(handoff).map { self.listeningSignals.followedArticleImported($0, for: entry) } != nil
                    } else {
                        let itemId = self.listeningSignals.followedArticleImported(try self.importBrowserTextInBackground(handoff), for: entry)
                        if let audio = try PublisherAudioDetector.publisherAudio(for: entry, itemId: itemId)?.keepingTextMap(of: store.loadPublisherAudio(itemId: itemId)) { try store.savePublisherAudio(audio); PublisherAudioTextMapper.start(audio, store: store, transcriber: self.sourceTranscriptionClient) { [weak self] in self?.diagnostics["publisherAudioTextMap"] = "\(itemId): \($0)" } }
                        if openWhenFinished { self.openItem(id: itemId) }
                        imported = true
                    }
                }
                guard imported else { return }
                try await self.followedSourceCoordinator?.setEntryState(id: entry.id, state: .imported)
                await self.performFollowedSourceRefresh(force: false)
                self.reportConfirmation("Imported \(entry.title) into the library.")
            } catch {
                self.reportFailure(error, context: "Source entry import failed")
            }
        }
    }

    func unfollowSource(id: String) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.unfollow(subscriptionId: id)
            await self?.performFollowedSourceRefresh(force: false)
        }
    }

    private func requireLocalSourceImporter() throws -> LocalSourceImporter {
        if let localSourceImporter { return localSourceImporter }
        let store = try requireStore()
        try configureOfflineServices(store: store)
        guard let localSourceImporter else {
            throw SessionKitError.persistenceFailed("local_source_importer_unavailable")
        }
        return localSourceImporter
    }

    func podcastLocalAssetDidBecomeReady(itemId: String, url: URL) {
        guard let engine, let store else { return }
        importedPodcastRecipientLocalURLs[itemId] = url
        let requestedReplacement = requestedPodcastTransportReplacements.remove(itemId) != nil
        run { _ in
            // Automatic completion keeps the current session's audio edition.
            // Explicit Download Again and a pending startup may adopt the new
            // file, including when a paused session's old local file was replaced.
            snapshot = try engine.updatePlaybackTransport(
                itemId: itemId,
                playbackURL: url.absoluteString,
                replaceActivePlayback: snapshot.status == .starting || requestedReplacement
            )
            refreshSelectedItem()
        }
        scheduleEmbeddedPublisherChapterImport(itemId: itemId, localURL: url)
        retrySourceWindowContexts(itemId: itemId)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: url)
        if deferredPodcastPlacementURLs[itemId] == nil, importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store),
           let item = try? store.loadItem(id: itemId) {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_for_imported_commentary"
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: url)
            return
        }
        guard pendingMapGenerationItemId == itemId,
              (try? store.loadItem(id: itemId)) != nil else {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "not_requested"
            return
        }
        pendingMapGenerationItemId = nil
        diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_private_episode_map"
        prepareEpisodeMap(itemId: itemId, policy: .explicit)
    }

    private func scheduleTransientRecipientAlignmentTranscript(for item: Item, localSourceURL: URL) {
        guard let sourceFile = try? PodcastPlacementFile(url: localSourceURL),
              importedTranscriptRetryDates[item.id].map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        importedTranscriptRetryDates[item.id] = Date()
        diagnostics["recipientAlignmentTranscript:\(item.id)"] = "transcribing_transiently"
        sharedMarginPlacementPasses.begin(.transcript, itemId: item.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sharedMarginPlacementPasses.end(.transcript, itemId: item.id) }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: localSourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                if self.importedPodcastResolutionURLs[item.id] == localSourceURL,
                   (try? PodcastPlacementFile(url: localSourceURL)) == sourceFile {
                    self.resolveImportedPodcastCommentary(
                        itemId: item.id, localURL: localSourceURL, recipientTranscriptOverride: timeline)
                }
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "consumed_and_deleted"
            } catch {
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "failed_and_deleted:\(error.localizedDescription)"
            }
        }
    }

    func resolveImportedPodcastCommentary(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) {
        guard let store,
              let file = try? PodcastPlacementFile(url: localURL),
              let item = try? store.loadItem(id: itemId),
              let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              !layers.isEmpty else { deferredPodcastPlacementURLs[itemId] = nil; return }
        guard !deferPlacementWhileSessionKeepsItsEdition(item: item, localURL: localURL) else { return }
        importedPodcastResolutionURLs[itemId] = localURL
        let localItem = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item))
        // Persisted transcripts have no byte-edition binding. Only this pass's
        // transient transcript is evidence for the supplied recipient file.
        let work = ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }
        guard !work.isEmpty else { podcastPlacementPassCoordinator.cancel(itemId: itemId); sharedMarginPlacementPasses.end(.matching, itemId: itemId); return }
        if recipientTranscriptOverride == nil, importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
        }
        let applicationSupportDirectory = try? applicationSupportDirectory()
        let submission = podcastPlacementPassCoordinator.schedule(.init(itemId: itemId, file: file,
            layers: work.map { .init(layer: $0.0, records: $0.1) }, transcript: recipientTranscriptOverride)) { [weak self] context in
            let recipientTranscript = context.request.transcript
            do {
                try Task.checkCancellation()
                let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                let isCurrent = try await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, self.podcastPlacementPassCoordinator.isCurrent(context) else { return false }
                    try store.invalidateImportedPodcastPlacements(itemId: itemId, editionSHA256: recipientDigest)
                    if self.selectedItem.id == itemId { self.refreshSelectedItem() }; self.refreshMarginRows()
                    return true
                }
                guard isCurrent else { return }
                var resolvedWork: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection], SharedListeningMapPlacement.Outcome?)] = []
                for (var layer, records) in work {
                    try Task.checkCancellation()
                    let queries = records.map { record in
                        let evidence = (record.podcastAnchorEvidence ?? []).compactMap { asset -> PodcastAcousticEvidenceQuery? in
                            guard let assetURL = Self.resolvedApplicationSupportAssetURL(
                                for: asset.localPath,
                                applicationSupportDirectory: applicationSupportDirectory
                            ), let data = try? Data(contentsOf: assetURL) else { return nil }
                            return PodcastAcousticEvidenceQuery(
                                id: asset.id,
                                signatureData: data,
                                anchorOffsetMs: asset.anchorOffsetMs
                            )
                        }
                        return PodcastPortableAnchorQuery(
                            packageScopedId: record.packageScopedId,
                            senderMediaTimeMs: record.anchorEvidence.mediaTimeMs,
                            evidence: evidence,
                            evidenceWasDeclared: !record.anchorEvidence.machineEvidenceAssetIds.isEmpty
                        )
                    }
                    let resolutions = (try? await PodcastAcousticAnchorResolver.resolve(
                        queries: queries,
                        recipientAudioURL: localURL,
                        senderExactEditionSHA256: layer.itemIdentity.exactEditionSHA256,
                        senderDurationMs: layer.itemIdentity.durationMs,
                        strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(
                            layer.itemIdentity,
                            localItem
                        )
                    )) ?? [:]
                    try Task.checkCancellation()
                    let fusedResolutions = ImportedPodcastPlacement.fuse(
                        queries: queries, records: records, acoustic: resolutions,
                        recipientTranscript: recipientTranscript)
                    let updated = ImportedPodcastPlacement.apply(
                        fusedResolutions, to: records, layer: &layer,
                        recipientDigest: recipientDigest, hasTranscript: recipientTranscript != nil)
                    var mapOutcome: SharedListeningMapPlacement.Outcome?
                    if layer.listeningMapProposals?.first != nil, layer.editionFingerprintSpines?.first == nil {
                        mapOutcome = .notPlaced(.init(sceneId: nil, sceneLabel: nil, reason: .noEvidence))
                    } else if let spine = layer.editionFingerprintSpines?.first, let proposal = layer.listeningMapProposals?.first {
                        let evidencePaths = layer.episodeMapEvidencePaths ?? [:]
                        mapOutcome = try await SharedListeningMapResolver.resolve(
                            proposal: proposal, spine: spine,
                            signatureData: { id in evidencePaths[id].flatMap {
                                Self.resolvedApplicationSupportAssetURL(for: $0, applicationSupportDirectory: applicationSupportDirectory)
                            }.flatMap { try? Data(contentsOf: $0) } },
                            recipientAudioURL: localURL, recipientEditionSHA256: recipientDigest,
                            itemId: itemId, projectionId: SharedListeningMapPlacement.projectionId(layerId: layer.id),
                            strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(layer.itemIdentity, localItem)
                        )
                    }
                    resolvedWork.append((layer, updated, mapOutcome))
                }
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.podcastPlacementPassCoordinator.isCurrent(context) else { return }
                    defer { self.sharedMarginPlacementPasses.end(.matching, itemId: itemId) }
                    guard let store = self.store else { return }
                    do {
                        let livingWork = try resolvedWork.filter { try store.isLiveImportedCommentaryLayer(id: $0.0.id) } // #915
                        let outcomes = livingWork.sorted { $0.0.importedAt < $1.0.importedAt }.compactMap(\.2)
                        let current = try store.loadResolvedListeningMapProjection(itemId: itemId)
                        let activation = SharedListeningMapPlacement.activation(
                            outcomes, listenerHasMap: try Self.listenerHasListeningMap(itemId: itemId, store: store),
                            activeProjectionId: current?.id)
                        for (var layer, records, outcome) in livingWork {
                            layer.sharedMapRefusalReason = activation.refusal == nil ? nil : outcome?.refusal?.listenerReason
                            try store.savePlacementResult(of: layer, records: records)
                        }
                        let sharedProposals = Dictionary(livingWork.compactMap { work in
                            work.0.listeningMapProposals?.first.map { (SharedListeningMapPlacement.projectionId(layerId: work.0.id), $0) }
                        }, uniquingKeysWith: { first, _ in first })
                        if activation.refusal != nil, let stale = current, sharedProposals[stale.id] != nil {
                            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                                id: stale.id, itemId: itemId, proposalId: stale.proposalId,
                                recipientEditionSHA256: stale.recipientEditionSHA256, points: [], intervals: []))
                        }
                        if let projection = activation.projection {
                            try store.saveResolvedListeningMapProjection(projection)
                            if let proposal = sharedProposals[projection.id] {
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    for scene in proposal.scenes where
                                        scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                                        _ = try? await self.prepareSummaryBridgeAsset(
                                            itemId: itemId,
                                            proposalId: projection.id,
                                            scene: scene,
                                            store: store
                                        )
                                    }
                                    self.updateSkimAvailability()
                                }
                            }
                        }
                        if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                        let resolvedCount = livingWork.filter { $0.0.sourceResolutionStatus == .resolved }.count
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "complete:\(resolvedCount)/\(livingWork.count) \(SharedMarginPlacementSummary(livingWork.map { ($0.0, $0.1) }).diagnosticValue)"
                        if recipientTranscript == nil, self.importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
                            self.scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
                        }
                    } catch {
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "persistence_failed:\(error.localizedDescription)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self?.podcastPlacementPassCoordinator.isCurrent(context) == true else { return }
                    self?.sharedMarginPlacementPasses.end(.matching, itemId: itemId)
                    self?.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "failed:\(error.localizedDescription)"
                }
            }
        }
        if !submission.joined {
            diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "scheduled:\(work.count)"
            // Only a request that starts a pass records "placing"; a joined one could set it after its pass ended it.
            sharedMarginPlacementPasses.begin(.matching, itemId: itemId, previous: Dictionary(work.flatMap(\.1).map { ($0.id, $0.resolution) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    private func importedPodcastCommentaryNeedsTranscript(
        itemId: String,
        store: SQLiteSessionStore
    ) -> Bool {
        guard let layers = try? store.loadImportedCommentaryLayers(itemId: itemId) else { return false }
        return ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }.contains { $0.1.contains(where: ImportedPodcastPlacement.recordNeedsTranscript) }
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

    private func resolvedOwnedAudiobookURL(for item: Item) -> URL? {
        // iOS can relocate the data container during an update. The ledger path
        // is relative to today's Application Support directory; item URLs are not.
        if let assets = try? store?.loadOwnedOfflineAssets(),
           let asset = assets.first(where: { $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid }),
           let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) {
            return url
        }
        guard let savedURL = item.media?.url.flatMap(URL.init(string:)), savedURL.isFileURL else { return nil }
        return resolvedApplicationSupportAssetURL(for: savedURL.path)
    }

    private func prepareSourceMediaPlayback(itemId: String) throws {
        if let item = try store?.loadItem(id: itemId), item.mediaType == "audiobook" {
            guard let url = resolvedOwnedAudiobookURL(for: item) else {
                throw SessionKitError.invalidCommandForState("The imported audio file is unavailable. Restore the source audio to continue listening.")
            }
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: url.absoluteString, replaceActivePlayback: false)
            return
        }
        guard let coordinator = podcastDownloadCoordinator else { return }
        coordinator.configureActiveItem(itemId)
        if let record = podcastDownloadRecords[itemId], record.state == .evicted,
           coordinator.networkTransport == .wifi,
           let remoteURL = URL(string: record.remoteURL) {
            coordinator.register(itemId: itemId, remoteURL: remoteURL)
        }
        guard let localURL = coordinator.validatedLocalURL(for: itemId) else {
            // Clear a cached local override when its file has disappeared.
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: nil, replaceActivePlayback: false)
            return
        }
        _ = try? engine?.updatePlaybackTransport(itemId: itemId, playbackURL: localURL.absoluteString, replaceActivePlayback: false)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
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
}

private enum ProviderCallError: Error, CustomStringConvertible {
    case missingAPIKey
    case dataSharingConsentRequired
    case remoteProviderDisabled

    var description: String {
        switch self {
        case .missingAPIKey:
            return "provider_api_key_missing"
        case .dataSharingConsentRequired:
            return "ai_data_sharing_consent_required"
        case .remoteProviderDisabled:
            return "remote_provider_disabled"
        }
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
