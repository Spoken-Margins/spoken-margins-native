import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
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
    case timeline
    case settings
    case offlineStorage
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

private struct ResolvedSkimPlaybackPlan {
    let direction: SkimDirection
    let itemId: String
    let originMediaTimeMs: Int
    let summarySceneId: String
    let destinationSceneId: String?
    let destinationMediaTimeMs: Int
    let summaryAssetId: String
    let summaryAudioURL: URL
}

private struct SkimResourceContext {
    let itemId: String
    let projection: ResolvedListeningMapProjection?
    let proposals: [PortableListeningMapProposalArtifact]
    let assets: [OwnedOfflineAsset]
}

enum SummaryBridgeRatePolicy {
    // Keep pronunciation independent of listening speed. Version generated assets
    // so summaries synthesized with the former accelerated policy are not reused.
    static let synthesisSpeed: Float = 1
    static let systemSynthesisRate: Float = 0.5
    static let cacheVersion = "natural-rate-v2"
    static func transportRate(_ listeningRate: Double) -> Float { Float(listeningRate) }
}

enum NativeTextStartupAudioState: String, Hashable {
    case notRequired = "not_required"
    case preparing
    case ready
    case paused
    case failed
}

struct LibraryItemRow: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let canDelete: Bool
    var hasContinuationSession: Bool
    var continuationProgressPercent: Int?
    let isCompleted: Bool
    let mediaType: String
    let hasNativeAudio: Bool
    let sourceTitle: String?
    let sourceURL: String?
    let author: String?
    let sourceReference: String?
    let sourceReferenceType: String?
    var offlineState: LibraryOfflineStateFilter
    var startupAudioState: NativeTextStartupAudioState
    var startupAudioCompletedChunkCount: Int
    var startupAudioTargetChunkCount: Int
    let addedAt: Date?
    let lastListenedAt: Date?
    let storageRecencyRank: Int

    var mediaSymbol: String {
        if hasNativeAudio { return "headphones" }
        return switch mediaType.lowercased() {
        case "podcast", "audio", "audiobook", "m4a", "m4b", "mp3":
            "headphones"
        case "pdf":
            "doc.richtext"
        case "epub":
            "book.closed"
        default:
            "doc.text"
        }
    }

    init(
        id: String,
        title: String,
        status: String,
        canDelete: Bool,
        hasContinuationSession: Bool = false,
        continuationProgressPercent: Int? = nil,
        isCompleted: Bool = false,
        mediaType: String = "text",
        hasNativeAudio: Bool = false,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        author: String? = nil,
        sourceReference: String? = nil,
        sourceReferenceType: String? = nil,
        offlineState: LibraryOfflineStateFilter = .onlineOnly,
        startupAudioState: NativeTextStartupAudioState = .notRequired,
        startupAudioCompletedChunkCount: Int = 0,
        startupAudioTargetChunkCount: Int = 0,
        addedAt: Date? = nil,
        lastListenedAt: Date? = nil,
        storageRecencyRank: Int = .max
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.canDelete = canDelete
        self.hasContinuationSession = hasContinuationSession
        self.continuationProgressPercent = continuationProgressPercent
        self.isCompleted = isCompleted
        self.hasNativeAudio = hasNativeAudio
        self.mediaType = mediaType
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.author = author
        self.sourceReference = sourceReference
        self.sourceReferenceType = sourceReferenceType
        self.offlineState = offlineState
        self.startupAudioState = startupAudioState
        self.startupAudioCompletedChunkCount = max(0, startupAudioCompletedChunkCount)
        self.startupAudioTargetChunkCount = max(0, startupAudioTargetChunkCount)
        self.addedAt = addedAt
        self.lastListenedAt = lastListenedAt
        self.storageRecencyRank = storageRecencyRank
    }
}

struct AudioPreparationQueueRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let policy: PreparationJobPolicy
    let state: PreparedAudioState
    let completedChunkCount: Int
    let plannedChunkCount: Int
    let requestedAt: Date
    let updatedAt: Date
    let failureCode: String?
    let isActivePlaybackItem: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    var progress: Double {
        guard plannedChunkCount > 0 else { return 0 }
        return min(1, Double(completedChunkCount) / Double(plannedChunkCount))
    }
}

struct RecentlyPreparedAudioRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let completedAt: Date
    let durationMs: Int
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
    var navigation: [CanonicalNavigationNode] = []
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var listeningMapScenes: [MediaTimelineChapter] = []
    var mediaDurationMs: Int?
    var isNativeAudio = false
    var documentStructure: PDFDocumentStructure?
    var sessions: [Session] = []
    var sessionRows: [SessionPresentation] = []
    var interjections: [Interjection] = []
    var importedCommentaryLayers: [ImportedCommentaryLayer] = []
    var importedCommentaryInterjections: [String: [ImportedCommentaryInterjection]] = [:]
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
    let modifiedAt: Date
    let modifiedAtDescription: String

    var dismissalKey: String {
        "\(id)|\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

enum QuickAddCandidate: Identifiable, Sendable {
    case localFile(QuickAccessFile)
    case followedSource(FeedEntry)

    var id: String {
        switch self {
        case .localFile(let file): "local-file:\(file.id)"
        case .followedSource(let entry): "followed-source:\(entry.id)"
        }
    }

    fileprivate var sortDate: Date {
        switch self {
        case .localFile(let file): file.modifiedAt
        case .followedSource(let entry): entry.publishedAt ?? .distantPast
        }
    }
}

private struct ObsidianImportRequest: Sendable {
    let url: URL
    let itemId: String
}

private struct PreparedObsidianImport: Sendable {
    let item: Item
    let listeningMap: ListeningMap?
    var structuredDocument: StructuredDocument? = nil
}

private struct ImportedSourceText: Sendable {
    let text: String
    let documentStructure: PDFDocumentStructure?
    /// A PDF's extraction v2 (C1 M3) and the title v1 would have given it.
    var structuredDocument: StructuredDocument? = nil
    var title: String? = nil
}

private struct ObsidianImportBatch: Sendable {
    let prepared: [PreparedObsidianImport]
    let failures: [String]
}

private enum SourceFileImportError: LocalizedError {
    case pdfHasNoExtractableText
    case pdfImportUnavailable
    case remotePDFInvalidResponse
    case remotePDFTooLarge

    var errorDescription: String? {
        switch self {
        case .pdfHasNoExtractableText:
            return "This PDF has no extractable text. Scanned PDFs need OCR before they can be imported."
        case .pdfImportUnavailable:
            return "PDF text extraction is unavailable in this build."
        case .remotePDFInvalidResponse:
            return "The shared link did not return a readable PDF."
        case .remotePDFTooLarge:
            return "This PDF is larger than the 50 MB import limit."
        }
    }
}

struct QuickAccessFileCandidate: Sendable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAt: Date
}

struct QuickAccessFolderScan: Sendable {
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
typealias AlignedInterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> AlignedInterjectionTranscript
typealias ShareMarginSilenceAnalysisHandler = @Sendable (
    _ sourceURL: URL,
    _ alignedTranscript: AlignedInterjectionTranscript
) throws -> [InterjectionCleanupDecision]
typealias ShareMarginAudioCleanupHandler = @Sendable (
    _ sourceURL: URL,
    _ destinationURL: URL,
    _ decisions: [InterjectionCleanupDecision]
) async throws -> Int

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
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:]
}

struct LibraryReadSnapshot: Sendable {
    let items: [Item]
    let sessions: [Session]
    let manifests: [PreparedAudioManifest]
    let jobs: [AudioPreparationJob]
    let downloads: [PodcastDownloadRecord]

    static func read(store: SQLiteSessionStore) throws -> Self {
        try Self(items: store.listItems(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifests(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads())
    }
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
    nonisolated static let supportedPlaybackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
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

    static func makeApplicationModel() -> Gate1AppModel {
        if ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_RECORDING"] == "1" {
            return Gate1AppModel(recordingClient: NoopRecordingClient())
        }
        return Gate1AppModel()
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
        playbackEventRecording.record("playback.state", [
            "item": DeveloperDiagnosticRecording.token(snapshot.itemId),
            "target": DeveloperDiagnosticRecording.token(snapshot.targetId),
            "status": snapshot.status.rawValue,
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1),
            "durationMs": String(snapshot.currentPlaybackDurationMs ?? -1),
            "failure": DeveloperDiagnosticRecording.token(snapshot.lastFailure),
            "failureDetail": PlaybackFailureDetail.privacySafe(snapshot.lastFailure)
        ])
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
    @Published private(set) var batchExportFolderName = UserDefaults.standard.string(forKey: "batchExportFolderName") ?? "No folder selected"
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
        }
    }
    @Published private(set) var marginRows: [MarginRow] = []
    @Published private(set) var offlineStorageSnapshot = OfflineStorageSnapshot()
    @Published private(set) var recordingPresentationContext: RecordingPresentationContext?
    @Published private(set) var isRequestingRecordingPermission = false
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
    @Published private(set) var importedCommentaryIsPaused = false
    private let importedMarginRemoteControls = ImportedMarginRemoteControls()
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
        if playingImportedCommentary != nil { return !importedCommentaryIsPaused }
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
        guard sourceFollowSuggestionItemId == selectedItem.id,
              screen != .playback || sourceFollowSuggestionItemId == snapshot.itemId else { return [] }
        guard !Self.isSourceAlreadyFollowed(
            sourceURL: libraryItems.first(where: { $0.id == selectedItem.id })?.sourceURL,
            sourceTitle: libraryItems.first(where: { $0.id == selectedItem.id })?.sourceTitle,
            subscriptions: feedSubscriptions
        ) else { return [] }
        return Self.uniqueUnfollowedCandidates(storedSourceFollowSuggestionCandidates, subscriptions: feedSubscriptions)
    }
    @Published private(set) var followedSourceEntries: [FeedEntry] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published private(set) var feedSubscriptions: [FeedSubscription] = [] { didSet { cachedQuickAddCandidates = nil } }
    @Published private(set) var isRefreshingFollowedSources = false
    @Published private(set) var importingFollowedSourceEntryIds: Set<String> = []
    @Published private(set) var isFollowingSelectedSource = false
    @Published var isResolvingSourceLink = false
    @Published var sourceLinkCandidateReview: SourceLinkCandidateReviewState?
    @Published private(set) var sourceLinkImportState = "idle"
    @Published private(set) var sourceLinkImportMessage: String?
    @Published private(set) var selectedListeningEdition: ListeningEdition?
    @Published var automaticMarginOutputEnabled = UserDefaults.standard.bool(forKey: "automaticMarginOutputEnabled")
    @Published var marginOutputStatus = "Choose a folder and send a test note before enabling automatic delivery."
    @Published private(set) var isImportingReadLater = false
    private var automaticMarginOutputTask: Task<Void, Never>?
    private var automaticMarginWriter: AutomaticMarginWriter?
    private var isDeliveringMargins = false
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
    private var sessionAudioPlaybackClient: AudioPlaybackClient?
    private var supertonicRenderer: SupertonicNarrationRenderer?
    private var preparedAudioCoordinator: PreparedAudioCoordinator?
    private var currentSupertonicRenderSignature: TTSRenderSignature?
    private var renderedSpeechDiskCache: RenderedSpeechDiskCache?
    private let sourceLinkResolver: LinkResolutionClient?
    private let sourceLinkHandoffStore: SourceLinkHandoffStore?
    private let browserTextHandoffStore: Gate5BrowserTextHandoffStore?
    private let audioPlaybackClientOverride: AudioPlaybackClient?
    private var mediaPlaybackClient: AVPlayerStreamPlaybackClient?
    private var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    private var requestedPodcastTransportReplacements: Set<String> = []
    private var offlineStorageLedger: OfflineStorageLedger?
    private var localSourceImporter: LocalSourceImporter?
    private var followedSourceCoordinator: FollowedSourceCoordinator?
    /// A fresh install: the Library was empty before the welcome sample was added (B1 drawer).
    private(set) var libraryWasEmptyAtLaunch = false
    private let readablePageExtractor = AppOwnedReadablePageExtractor()
    private var sourceSuggestionChecks: Set<String> = []
    private var guidedOnboardingCoordinator: GuidedOnboardingCoordinator?
    private let recordingClientOverride: RecordingClient?
    private let microphonePermissionRequest: (() async -> Bool)?
    private let forcePreparedTextGate: Bool
    private let sourceTranscriptionClient: SourceTranscriptionClient
    private let interjectionTranscriptionHandler: InterjectionTranscriptionHandler
    private let alignedInterjectionTranscriptionHandler: AlignedInterjectionTranscriptionHandler?
    private let preparedTextAudioPrewarmHandler: PreparedTextAudioPrewarmHandler?
    private let shareMarginSilenceAnalysisHandler: ShareMarginSilenceAnalysisHandler
    private let shareMarginAudioCleanupHandler: ShareMarginAudioCleanupHandler
    private let trashUndoDismissDelay: Duration
    #if SPOKEN_MARGINS_WATCH
    private var gate3WatchDispatcher: CompactControlDispatcher?
    #endif
    private var activeItemId = "item-pill"
    private var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-5.6"
    private var playbackProgressTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var onDeviceSpeechGenerationDelayTask: Task<Void, Never>?
    private var trashUndoDismissTask: Task<Void, Never>?
    #if canImport(UIKit) && os(iOS)
    private var textPlaybackStartupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    #if canImport(AVFoundation)
    private var interjectionAudioPlayer: AVPlayer?
    private var interjectionAudioCompletionTask: Task<Void, Never>?
    private var skimBridgePlayer: AVPlayer?
    private var skimBridgeTask: Task<Void, Never>?
    private var preparingLocalAudioMapItems = Set<String>()
    private var commentaryCuePlayer: AVAudioPlayer?
    #endif
    private var announcedImportedInterjectionIDs: Set<String> = []
    private var sourceShouldResumeAfterImportedCommentary = false
    private var sourcePausedForImportedCommentaryPrompt = false
    private var importedCommentaryAutoPlayTask: Task<Void, Never>?
    private var bulkSharePreparationTask: Task<Void, Never>?
    private var bulkSharePreparationGeneration = 0
    private var shouldForceFirstSharedSourceMissForUITesting =
        CommandLine.arguments.contains("--ui-testing")
        && ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_FORCE_FIRST_SHARED_SOURCE_MISS"] == "1"
    private var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    private var foregroundAudioPreparationTask: Task<Void, Never>?
    private var foregroundAudioPreparationGeneration = 0
    private var episodeMapPreparationTask: Task<Void, Never>?
    private var episodeMapPreparationItemId: String?
    private var isUpdatingSkimAvailability = false
    private var backgroundPreparationPrefersEpisodeMap = true
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
    private var pendingFullSourceTranscriptionItemIds: Set<String> = []
    private var importedPodcastResolutionGenerations: [String: Int] = [:]
    private var importedPodcastResolutionURLs: [String: URL] = [:]
    private var importedTranscriptRetryDates: [String: Date] = [:]
    private var transcriptAssistedResolutionItems: Set<String> = []
    private var importedPodcastRecipientLocalURLs: [String: URL] = [:]
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
    private static let startupAudioChunkCount = 2
    static let textAudioPreparationCutoffPercent = 99
    private static let lastPreparedAudioNoticeDateKey = "lastPreparedAudioNoticeDateV1"
    private let sourceWindowContextBeforeMs = SourceAnchorContextResolver.windowBeforeMs
    private let sourceWindowContextAfterMs = SourceAnchorContextResolver.windowAfterMs
    private let quickAccessFolderBookmarkKey = "quickAccessFolderBookmark"
    private let batchExportFolderBookmarkKey = "batchExportFolderBookmark"
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

    private enum PendingPlaybackAfterTerms {
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
            && selectedItem.id == Self.guidedOnboardingItemId
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

    static let supportedMediaSkipSeconds = [10, 15, 30, 45, 60]
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
                await MainActor.run {
                    guard let self else { return }
                    guard self.snapshot.status.isPlaybackActive else {
                        self.stopPlaybackProgressTicker()
                        return
                    }
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
                        if previousEngagementProgress < 25,
                           updated.currentPlaybackProgressPercent >= 25,
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
            }
        }
    }

    private func stopPlaybackProgressTicker() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
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

    func handleAppBecameInactiveOrBackground() {
        automaticMarginOutputTask?.cancel()
        automaticMarginOutputTask = nil
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
            libraryWasEmptyAtLaunch = rows.isEmpty
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
               !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
               UserDefaults.standard.integer(forKey: Self.guidedOnboardingSeedVersionKey) < 1,
               !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                rows = try loadLibraryRows(store: store)
                diagnostics["guidedOnboardingItem"] = "bundled_fallback_seeded"
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
        completionUndo = nil
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

    private static func makeBundledGuidedOnboardingItem() -> Item {
        Item(
            id: guidedOnboardingItemId,
            title: "Guided Tour: Add and Prepare Sources",
            mediaType: "guided_tour",
            text: """
            Welcome to Spoken Margins. Add text, PDF, a readable webpage, or a podcast from Add Source. You can also import a DRM-free EPUB or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Native text and EPUB chapters can be prepared for offline listening. Preparation progress, storage use, retry, and cancellation stay visible; changing playback speed does not regenerate prepared audio. Followed sources appear in New from Sources and never import until you choose an entry. Use the sleep timer for a timed pause or the end of the current chapter.
            """,
            externalReference: "bundled://guided-onboarding.v1",
            status: "ready",
            externalReferenceType: "guided_onboarding",
            sourceTitle: "Spoken Margins",
            createdAt: Date()
        )
    }

    private static func makeBundledGuidedOnboardingMap() -> ListeningMap {
        let textLength = makeBundledGuidedOnboardingItem().text?.count ?? 0
        return ListeningMap(
            id: "map-guided-onboarding",
            itemId: guidedOnboardingItemId,
            overview: "Practice listening, interjecting, reviewing the timeline, and exporting a session.",
            chapters: [
                Chapter(
                    id: "guided-onboarding-core-loop",
                    title: "The Core Loop",
                    startChar: 0,
                    endChar: textLength,
                    percent: 0
                )
            ]
        )
    }

    func handleAppBecameActive() {
        openReadyListeningEdition()
        startAutomaticMarginOutput()
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
        Task { [weak self] in
            do {
                let bytes = try await ledger.clearReproducibleAssets(in: [.preparedAudio, .preparedChunk, .podcast, .guidedTour])
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
            let activeItems = Dictionary(uniqueKeysWithValues: try store.listItems()
                .filter { $0.deletedAt == nil }.map { ($0.id, $0.title) })
            let rows = try store.loadSessions().flatMap { session -> [MarginRow] in
                guard let itemTitle = activeItems[session.itemId] else { return [] }
                return try store.loadInterjections(sessionId: session.id)
                    .filter { $0.status == "active" }
                    .map {
                        MarginRow(
                            interjection: $0,
                            itemTitle: itemTitle,
                            sessionDate: session.updatedAt ?? session.createdAt
                        )
                    }
            }
            sharedMarginRows = try store.loadImportedCommentaryLayers()
                .filter { $0.deletedAt == nil && ($0.itemId == nil || activeItems[$0.itemId ?? ""] != nil) }
                .flatMap { layer in
                    try store.loadImportedCommentaryInterjections(layerId: layer.id).map {
                        SharedMarginRow(interjection: $0, layer: layer, itemTitle: activeItems[layer.itemId ?? ""] ?? layer.itemIdentity.title)
                    }
                }
                .sorted { $0.interjection.createdAt > $1.interjection.createdAt }
            marginRows = rows.sorted { lhs, rhs in
                let leftSessionDate = lhs.sessionDate ?? .distantPast
                let rightSessionDate = rhs.sessionDate ?? .distantPast
                if leftSessionDate != rightSessionDate { return leftSessionDate > rightSessionDate }
                if lhs.interjection.createdAt != rhs.interjection.createdAt {
                    return lhs.interjection.createdAt > rhs.interjection.createdAt
                }
                return lhs.id < rhs.id
            }
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
        // The saved bounded anchor belongs to this Margin's source or generated target.
        let parts = [row.interjection.anchor.anchorBefore, row.interjection.anchor.anchorAfter]
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " … ").prefix(600))
    }

    func openMarginInTimeline(_ row: MarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margin_timeline") else { return }
        if let activeSessionID = snapshot.sessionId,
           activeSessionID != row.interjection.sessionId {
            reportWarning("This Margin belongs to another session. Now Playing was left unchanged.")
            diagnostics["marginTimelineNavigation"] = "blocked_active_session_replacement"
            return
        }
        do {
            let store = try requireStore()
            if snapshot.sessionId == nil {
                guard let session = try store.loadSession(id: row.interjection.sessionId) else {
                    throw SessionKitError.persistenceFailed("margin_session_missing")
                }
                openSession(session)
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
        guard Self.isInlineSpokenMargin(interjection), let anchorMs = interjection.anchor.mediaTimeMs else { return }
        let sessions: [Session] = (try? store.loadSessions(itemId: interjection.itemId)) ?? []
        let spoken: [Interjection] = sessions
            .flatMap { session -> [Interjection] in (try? store.loadInterjections(sessionId: session.id)) ?? [] }
            .filter(Self.isInlineSpokenMargin)
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
        announcedImportedInterjectionIDs.insert(row.interjection.id)
        let targetID = "shared::\(row.layer.id)::\(row.interjection.id)"
        startMarginMoment(
            itemId: itemID,
            target: MarginMomentAnchor(marginId: targetID, mediaTimeMs: position.mediaTimeMs),
            otherMargins: [],
            voiceURLs: [targetID: voiceURL],
            title: "\(row.collectionLabel)'s Margin",
            isApproximate: position.isApproximate
        )
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
                seek: { [weak self] in self?.seekMedia(toMediaTimeMs: $0) }
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
        diagnostics["marginMoment"] = "started:lead_in_ms=\(target.mediaTimeMs - sequence.startMediaTimeMs);others=\(sequence.unplayed.count - 1);approximate=\(isApproximate)"
    }

    private nonisolated static func isInlineSpokenMargin(_ margin: Interjection) -> Bool {
        guard margin.status == "active", margin.captureKind != .written, margin.targetType == .item else { return false }
        return margin.anchor.mediaTimeMs != nil && margin.audioPath != nil
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
        let progressBefore = backgroundPreparationProgressToken(store: store)
        let episodeJobs = ((try? store.loadEpisodeMapPreparationJobs()) ?? [])
            .filter {
                !$0.isCancelled
                    && $0.stage != .completed
                    && ($0.policy == .explicit || automaticEpisodeMapPreparationPolicy == .whileCharging)
                    && podcastDownloadCoordinator?.validatedLocalURL(for: $0.itemId) != nil
            }
            .sorted {
                if $0.policy != $1.policy { return $0.policy == .explicit }
                return $0.requestedAt < $1.requestedAt
            }
        let hasAudioWork = ((try? store.loadAudioPreparationJobs()) ?? []).contains { !$0.isCancelled }
        let shouldRunEpisode = !episodeJobs.isEmpty
            && (!hasAudioWork || backgroundPreparationPrefersEpisodeMap)
        if shouldRunEpisode,
           episodeMapPreparationTask == nil,
           ProcessInfo.processInfo.thermalState != .serious,
           ProcessInfo.processInfo.thermalState != .critical,
           !ProcessInfo.processInfo.isLowPowerModeEnabled,
           let job = episodeJobs.first {
            prepareEpisodeMap(itemId: job.itemId, policy: job.policy)
            if let task = episodeMapPreparationTask {
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            backgroundPreparationPrefersEpisodeMap = false
            let hasEpisodeWork = ((try? store.loadEpisodeMapPreparationJobs()) ?? []).contains {
                !$0.isCancelled && $0.stage != .completed
            }
            return backgroundPreparationResult(
                hasRemainingWork: hasEpisodeWork || hasAudioWork,
                progressBefore: progressBefore,
                store: store
            )
        }
        let audioHasMore = await performBackgroundAudioPreparationPass()
        if hasAudioWork { backgroundPreparationPrefersEpisodeMap = true }
        if audioHasMore {
            return backgroundPreparationResult(
                hasRemainingWork: true,
                progressBefore: progressBefore,
                store: store
            )
        }
        if !episodeJobs.isEmpty {
            backgroundPreparationPrefersEpisodeMap = true
            return backgroundPreparationResult(
                hasRemainingWork: true,
                progressBefore: progressBefore,
                store: store
            )
        }
        return .finished
    }

    private func backgroundPreparationResult(
        hasRemainingWork: Bool,
        progressBefore: [String],
        store: SQLiteSessionStore
    ) -> BackgroundPreparationWorkResult {
        guard hasRemainingWork else { return .finished }
        return backgroundPreparationProgressToken(store: store) == progressBefore
            ? .retryLater
            : .continueNow
    }

    private func backgroundPreparationProgressToken(store: SQLiteSessionStore) -> [String] {
        let audio = ((try? store.loadAudioPreparationJobs()) ?? [])
            .filter { !$0.isCancelled }
            .map { "audio:\($0.id):\($0.nextChunkIndex)" }
        let episode = ((try? store.loadEpisodeMapPreparationJobs()) ?? [])
            .filter { !$0.isCancelled && $0.stage != .completed }
            .map { "episode:\($0.id):\($0.stage.rawValue):\($0.nextUnitIndex)" }
        return (audio + episode).sorted()
    }

    func handleApplicationWillTerminate() {
        stopImportedCommentaryPlayback(resumeSource: false)
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        syncPlaybackProgressForLifecycle()
        endTextPlaybackStartupBackgroundTask()
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
                if try client.stopOnDeviceRenderingAndUseSystemSpeech(returnsAutomatically: true) {
                    speechFallbackReason = .memoryWarning
                    let message = SpeechFallbackReason.memoryWarning.listenerExplanation
                    statusMessage = message
                    feedbackEvent = UserFeedbackEvent(kind: .warning, message: message)
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
            completionUndo = nil
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
            startItem(id: Self.guidedOnboardingItemId)
        } catch {
            reportFailure(error, context: "Guided tour setup failed")
        }
    }

    private func makeAppOverviewSample() throws -> (Item, ListeningMap) {
        let itemId = Self.welcomeSampleItemId
        let optionalAIOverview = remoteProviderExperienceEnabled
            ? "Summarize Notes synthesizes the Margins in this session. Discuss answers a question using relevant source and session context. Both are optional and require your OpenAI API key, network access, and separate permission to send content."
            : "Summarize Notes synthesizes the Margins in this session with Apple’s on-device model when available. Remote discussion and third-party API keys are disabled; you can copy your notes to another chatbot and paste its response back into Spoken Margins."
        let markdown = """
        # Welcome to Spoken Margins

        Spoken Margins is a structured listening workspace. It restores the headings, progress, margin notes, and easy navigation that ordinary audio loses, so reading can become an active listening session.

        ## Start with the Listening Map

        Tap Start Listening on this source. The overview plays first, and the Timeline shows the chapters below. Tap any chapter to jump directly to it while keeping your place in the source.

        ## Move forward and backward

        On Now Playing, use the backward and forward buttons around Play to move by paragraph. The progress slider can move farther through the source. Open More to change the speech rate.

        ## Interject while you listen

        This is your practice cue. Tap Add a Margin, say one thing you want to remember about this tour, then save. Spoken Margins anchors your thought near the passage you were hearing and resumes without losing your place. Prefer typing? Tap the writing button beside Record. Open Margins to find, star, and review your note, or choose Play this moment to hear its source again.

        ## Load your own sources

        Return to Library and tap Add. Choose Paste Text or Link or Podcast, then Add to Library. You can also choose a document, PDF, DRM-free EPUB, or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Adding a source keeps your current listening session in place; choose the new item when you are ready to listen. In Safari, enable Spoken Margins Text under Manage Extensions to capture selected text or a readable article, or run the Add Article to Spoken Margins Shortcut from Safari’s Share menu. You can also share a PDF, Markdown file, or text file directly to Spoken Margins.

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
        map.overview = "Take a guided tour of the Listening Map, playback navigation, spoken Margins, and the three ways to add your own sources."
        return (item, map)
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
                reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
            }
        } catch {
            reportFailure(error, context: "Import failed")
        }
    }

    nonisolated static func pastedSourceText(plainText: String, html: String?) -> String {
        guard let html, let regex = try? NSRegularExpression(pattern: #"(?is)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#) else { return plainText }
        var headings: [String: Int] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let levelRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let level = Int(html[levelRange]) else { continue }
            var title = String(html[titleRange]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
                title = title.replacingOccurrences(of: entity, with: value)
            }
            headings[title.trimmingCharacters(in: .whitespacesAndNewlines)] = level
        }
        return plainText.components(separatedBy: .newlines).map { line in
            guard let level = headings[line.trimmingCharacters(in: .whitespaces)] else { return line }
            return String(repeating: "#", count: level) + " " + line
        }.joined(separator: "\n")
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
                    self.reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
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
                    self.reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
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

    var hasQuickAccessFolder: Bool {
        UserDefaults.standard.data(forKey: quickAccessFolderBookmarkKey) != nil
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
        let importedURLs = Set(libraryItems.compactMap { normalizedQuickAddURL($0.sourceReference) })
        let importedEpisodeKeys = Set(libraryItems.map {
            quickAddEpisodeKey(title: $0.title, sourceTitle: $0.sourceTitle)
        })
        let sourceTitles = Dictionary(uniqueKeysWithValues: subscriptions.map {
            ($0.id, $0.source.title ?? $0.source.host)
        })
        let eligibleFiles = folderFiles.filter { !dismissedFileKeys.contains($0.dismissalKey) }
        let eligibleEntries = followedEntries.filter { entry in
            if let normalizedURL = normalizedQuickAddURL(entry.canonicalURL), importedURLs.contains(normalizedURL) {
                return false
            }
            let episodeKey = quickAddEpisodeKey(
                title: entry.title,
                sourceTitle: sourceTitles[entry.subscriptionId]
            )
            return !importedEpisodeKeys.contains(episodeKey)
        }
        return (eligibleFiles.map(QuickAddCandidate.localFile)
            + eligibleEntries.map(QuickAddCandidate.followedSource))
            .sorted {
                if $0.sortDate != $1.sortDate {
                    return $0.sortDate > $1.sortDate
                }
                return $0.id < $1.id
            }
    }

    private nonisolated static func normalizedQuickAddURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }

    private nonisolated static func quickAddEpisodeKey(title: String, sourceTitle: String?) -> String {
        [sourceTitle ?? "", title]
            .map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "|")
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
                if let document = imported.structuredDocument {
                    let title = imported.title ?? request.url.deletingPathExtension().lastPathComponent
                    let map = StructuredDocumentImport.listeningMap(for: document, title: title, itemId: request.itemId)
                    let item = Item(
                        id: request.itemId,
                        title: title,
                        mediaType: "pdf",
                        text: document.text,
                        externalReference: request.url.lastPathComponent,
                        status: map == nil ? "needs_listening_map" : "ready",
                        externalReferenceType: "file",
                        createdAt: Date(),
                        documentStructure: imported.documentStructure
                    )
                    prepared.append(PreparedObsidianImport(item: item, listeningMap: map, structuredDocument: document))
                    continue
                }
                let parsed = try ObsidianMarkdownParser.parse(fileName: request.url.lastPathComponent, contents: imported.text)
                let mapPolicy: DeterministicListeningMapPolicy = request.url.pathExtension.lowercased() == "pdf"
                    ? .canonicalHeadings
                    : .adaptiveListeningSections
                let deterministicMap = parsed.deterministicListeningMap(
                    itemId: request.itemId,
                    policy: mapPolicy
                )
                let item = Item(
                    id: request.itemId,
                    title: parsed.title,
                    mediaType: request.url.pathExtension.lowercased() == "pdf" ? "pdf" : "text",
                    text: parsed.text,
                    externalReference: parsed.source ?? request.url.lastPathComponent,
                    status: deterministicMap == nil ? "needs_listening_map" : "ready",
                    externalReferenceType: "file",
                    createdAt: Date(),
                    documentStructure: imported.documentStructure
                )
                prepared.append(PreparedObsidianImport(item: item, listeningMap: deterministicMap))
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
    func importSourceLinkFromForm() -> Bool {
        beginSourceLinkImportFromForm(startSession: !hasActiveSession)
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
            let result = try await PublicPodcastLinkResolver().resolveAsync(request)
            if result.foundNoAudio, let imported = await importLinkAsReadableArticle(url, startSession: shouldStartSession) {
                return imported
            }
            return importResolvedSourceLink(request: request, result: result, startSession: shouldStartSession)
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    /// The Link field promises web articles too (#144). When a page has no audio, read it with the same
    /// app-owned extractor that followed article feeds use. Returns nil when that fails, so the caller shows the
    /// original "no audio" result.
    private func importLinkAsReadableArticle(_ url: URL, startSession: Bool) async -> Bool? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        do {
            var handoff = try await readablePageExtractor.extract(url: url)
            handoff.requestedContinuation.startSession = startSession
            diagnostics["lastSourceLinkArticleFallback"] = readablePageExtractor.lastExtractor ?? "extracted"
            return importBrowserText(handoff)
        } catch {
            diagnostics["lastSourceLinkArticleFallback"] = "failed:\(error.localizedDescription)"
            return nil
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
            if !startSession {
                guard let item = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
                    reportFailure(sourceLinkFailureMessage(
                        status: result.status.rawValue,
                        reason: result.failureReason,
                        provider: result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
                    ))
                    return false
                }
                reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
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

    static func isRemotePDFHandoff(_ handoff: SourceLinkHandoff) -> Bool {
        handoff.sourceSurface == "share_sheet_pdf"
            || (URL(string: handoff.inputURL)?.isFileURL == false
                && URL(string: handoff.inputURL)?.pathExtension.lowercased() == "pdf")
    }

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

    private func importRemotePDFInBackground(url: URL) async throws {
        #if canImport(PDFKit)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let pdfHeader = Data("%PDF-".utf8)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.prefix(1_024).range(of: pdfHeader) != nil else {
            throw SourceFileImportError.remotePDFInvalidResponse
        }
        guard data.count <= 50 * 1_024 * 1_024 else {
            throw SourceFileImportError.remotePDFTooLarge
        }
        let extracted = try await Task.detached(priority: .userInitiated) {
            try NativePDFDocumentExtractor.extractStructured(from: data)
        }.value
        let decodedName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent
        let fileTitle = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(
                url: url.absoluteString,
                title: extracted.title ?? (fileTitle.isEmpty ? "Shared PDF" : fileTitle)
            ),
            text: extracted.document.text,
            contentFormat: .plainText,
            documentStructure: extracted.documentStructure
        )
        try importBrowserTextInBackground(handoff, structuredDocument: extracted.document)
        diagnostics["lastRemotePDFImport"] = url.absoluteString
        markOnboardingSteps([.addedOwnSource, .addedFromSafari])
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    private func importBrowserTextInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws {
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
                files: Array(supported.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)),
                errorDescription: nil
            )
        } catch {
            return QuickAccessFolderScan(files: [], errorDescription: String(describing: error))
        }
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
        do {
            if hasActiveSession {
                try importBrowserTextInBackground(handoff)
                reportConfirmation("Added \(handoff.source.title) to Library without changing Now Playing.")
                return true
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
            return true
        } catch {
            reportFailure(error, context: "Browser text import failed")
            return false
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
        guard !requireTermsDecisionBeforePlayback(.startCurrentItem) else { return }
        if !hasActiveSession {
            resetMixWithOtherAudioForNewSession()
        }
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
        beginTextPlaybackStartupBackgroundTaskIfNeeded(itemId: activeItemId)
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
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(!importedCommentaryIsPaused)
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
        if case .inactive = sleepTimerState { return false }
        return true
    }

    var sleepTimerDescription: String {
        switch sleepTimerState {
        case .inactive: return "Sleep Timer"
        case .armed(let mode, _, _):
            if mode == .endOfChapter { return "End of Chapter" }
            guard let seconds = sleepTimerRemainingSeconds else { return "Sleep Timer" }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .expiryDeferred: return "Pauses after recording"
        }
    }

    var canUseEndOfChapterSleepTimer: Bool {
        endOfChapterTarget() != nil
    }

    func armSleepTimer(_ mode: SleepTimerMode) {
        let deadline: Date?
        let chapterId: String?
        switch mode {
        case .minutes15: deadline = Date().addingTimeInterval(15 * 60); chapterId = nil
        case .minutes30: deadline = Date().addingTimeInterval(30 * 60); chapterId = nil
        case .minutes45: deadline = Date().addingTimeInterval(45 * 60); chapterId = nil
        case .minutes60: deadline = Date().addingTimeInterval(60 * 60); chapterId = nil
        case .endOfChapter:
            guard let target = endOfChapterTarget() else { return }
            deadline = nil
            chapterId = target.chapterId
        }
        sleepTimerState = .armed(mode: mode, deadline: deadline, chapterId: chapterId)
        startSleepTimerTicker()
        reconcileSleepTimer(now: Date())
    }

    func extendSleepTimerBy15Minutes() {
        let now = Date()
        let deadline: Date
        switch sleepTimerState {
        case .armed(_, let current?, _): deadline = max(current, now).addingTimeInterval(15 * 60)
        case .expiryDeferred: deadline = now.addingTimeInterval(15 * 60)
        case .inactive, .armed(_, nil, _): deadline = now.addingTimeInterval(15 * 60)
        }
        sleepTimerState = .armed(mode: .minutes15, deadline: deadline, chapterId: nil)
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
        switch sleepTimerState {
        case .inactive:
            sleepTimerRemainingSeconds = nil
        case .expiryDeferred(let mode):
            sleepTimerRemainingSeconds = 0
            if !snapshot.isRecording { expireSleepTimer(mode: mode) }
        case .armed(let mode, let deadline, let chapterId):
            if let deadline {
                let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
                sleepTimerRemainingSeconds = remaining
                if remaining == 0 { requestSleepTimerExpiry(mode: mode) }
            } else if mode == .endOfChapter,
                      let target = endOfChapterTarget(chapterId: chapterId),
                      (snapshot.currentMediaTimeMs ?? 0) >= target.endMs {
                requestSleepTimerExpiry(mode: mode)
            }
        }
    }

    private func requestSleepTimerExpiry(mode: SleepTimerMode) {
        if snapshot.isRecording {
            sleepTimerState = .expiryDeferred(mode: mode)
        } else {
            expireSleepTimer(mode: mode)
        }
    }

    private func expireSleepTimer(mode: SleepTimerMode) {
        if snapshot.status.isPlaybackActive { pause() }
        cancelSleepTimer()
        reportConfirmation(mode == .endOfChapter ? "Paused at the end of the chapter." : "Sleep timer paused playback.")
    }

    private func endOfChapterTarget(chapterId: String? = nil) -> (chapterId: String, endMs: Int)? {
        let chapters = selectedItem.mediaChapters.sorted { $0.startMs < $1.startMs }
        guard chapters.count > 1 else { return nil }
        let currentMs = snapshot.currentMediaTimeMs ?? 0
        let index: Int
        if let chapterId, let exact = chapters.firstIndex(where: { $0.id == chapterId }) { index = exact }
        else { index = chapters.lastIndex(where: { $0.startMs <= currentMs }) ?? 0 }
        guard chapters.indices.contains(index + 1) else { return nil }
        return (chapters[index].id, chapters[index + 1].startMs)
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
            guard try client.stopOnDeviceRenderingAndUseSystemSpeech() else {
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
                    let ledger: OfflineStorageLedger
                    if let existingLedger = self.offlineStorageLedger {
                        ledger = existingLedger
                    } else {
                        ledger = OfflineStorageLedger(
                            repository: store,
                            rootDirectory: try self.applicationSupportDirectory()
                        )
                        self.offlineStorageLedger = ledger
                    }
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
                    try FileManager.default.createDirectory(
                        at: transcriptURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let ledger: OfflineStorageLedger
                    if let existingLedger = self.offlineStorageLedger {
                        ledger = existingLedger
                    } else {
                        ledger = OfflineStorageLedger(repository: store, rootDirectory: supportDirectory)
                        self.offlineStorageLedger = ledger
                    }
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
                    var label: LocalListeningMapLabel?
                    if self.localFoundationModelClient.availability().isAvailable, !text.isEmpty {
                        for _ in 0..<2 where label == nil {
                            if let candidate = try? await self.localFoundationModelClient.labelListeningMapChapter(
                                text: text,
                                chapterNumber: draft.order + 1
                            ) {
                                label = try? LocalListeningMapOutputValidator.validate(label: candidate, sourceText: text)
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
                        summaryText: label?.description,
                        summaryAssetId: nil,
                        summaryProvenance: label == nil ? nil : .modelGenerated,
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
                    var updated = asset
                    updated.protections.remove(.activeEpisodeMapPreparation)
                    try store.saveOwnedOfflineAsset(updated)
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
                if item.id == self.activeItemId { self.reportFailure(error, context: "Episode map preparation failed") }
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
        let ledger: OfflineStorageLedger
        if let existingLedger = offlineStorageLedger {
            ledger = existingLedger
        } else {
            ledger = OfflineStorageLedger(
                repository: store,
                rootDirectory: try applicationSupportDirectory()
            )
            offlineStorageLedger = ledger
        }
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
                let renderer = SystemTextAudioPreparationClient(
                    outputDirectory: directory,
                    voiceIdentifier: speechVoiceIdentifier,
                    speechRate: SummaryBridgeRatePolicy.systemSynthesisRate,
                    allowsSynchronousRendering: true
                )
                guard let prepared = try renderer.prepareTextAudio(
                    itemId: assetID,
                    title: scene.title ?? "Scene summary",
                    text: summary
                ), let value = prepared.media.url, let url = URL(string: value) else {
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
    #endif

    private func updateSkimAvailability(refreshResources: Bool = true) {
        if refreshResources { skimResourceContext = nil }
        guard !isUpdatingSkimAvailability else { return }
        let effectiveTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? snapshot.currentMediaTimeMs
        let forward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) }
        let backward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .backward, at: $0) }
        let forwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        if skimForwardDestinationMs != forwardTime { skimForwardDestinationMs = forwardTime }
        if skimBackwardDestinationMs != backwardTime { skimBackwardDestinationMs = backwardTime }
        let canForward = forwardTime != nil
        let canBackward = backwardTime != nil
        guard snapshot.canSkimForward != canForward || snapshot.canSkimBackward != canBackward else { return }
        isUpdatingSkimAvailability = true
        snapshot.canSkimForward = canForward
        snapshot.canSkimBackward = canBackward
        isUpdatingSkimAvailability = false
    }

    private func resolvedSkimPlaybackPlan(
        direction: SkimDirection,
        at recipientMediaTimeMs: Int
    ) -> ResolvedSkimPlaybackPlan? {
        guard isMediaPlaybackSnapshot, !snapshot.isRecording, let store else { return nil }
        if skimResourceContext?.itemId != activeItemId {
            #if DEBUG
            skimResourceLoadCount += 1
            #endif
            let committed = (try? store.loadPortableListeningMapProposals(itemId: activeItemId)) ?? []
            let imported = ((try? store.loadImportedCommentaryLayers(itemId: activeItemId)) ?? [])
                .flatMap { $0.listeningMapProposals ?? [] }
            skimResourceContext = SkimResourceContext(
                itemId: activeItemId,
                projection: try? store.loadResolvedListeningMapProjection(itemId: activeItemId),
                proposals: committed + imported,
                assets: (try? store.loadOwnedOfflineAssets()) ?? []
            )
        }
        guard let resources = skimResourceContext, let projection = resources.projection else { return nil }
        let proposals = resources.proposals
        guard let proposal = proposals.first(where: { $0.id == projection.proposalId }) ?? proposals.first else {
            return nil
        }
        let scenes = proposal.scenes.sorted { $0.order < $1.order }
        guard !scenes.isEmpty else { return nil }
        let exactIdentityProjection = projection.algorithmVersion == "episode-projection.exact-edition.v1"
            || (!projection.points.isEmpty && projection.points.allSatisfy {
                ($0.confidence == .exactEdition || $0.confidence == .verified)
                    && $0.recipientMediaTimeMs == $0.sourceMediaTimeMs
            })
        func projectedTime(_ sourceTimeMs: Int?) -> Int? {
            guard let sourceTimeMs else { return nil }
            return projection.projectedRecipientTime(for: sourceTimeMs)
                ?? (exactIdentityProjection ? sourceTimeMs : nil)
        }
        let sceneStarts = scenes.map { projectedTime($0.startAnchor.mediaTimeMs) }
        guard let currentIndex = scenes.indices.last(where: {
            guard let start = sceneStarts[$0] else { return false }
            return start <= recipientMediaTimeMs
        }) else { return nil }

        let summaryIndex: Int
        let destinationSceneId: String?
        let destinationMediaTimeMs: Int
        switch direction {
        case .forward:
            summaryIndex = currentIndex
            if scenes.indices.contains(currentIndex + 1) {
                guard let destination = sceneStarts[currentIndex + 1] else { return nil }
                destinationSceneId = scenes[currentIndex + 1].id
                destinationMediaTimeMs = destination
            } else {
                guard let duration = snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs else { return nil }
                destinationSceneId = nil
                destinationMediaTimeMs = duration
            }
        case .backward:
            guard currentIndex > 0, let destination = sceneStarts[currentIndex] else { return nil }
            summaryIndex = currentIndex - 1
            destinationSceneId = scenes[currentIndex].id
            destinationMediaTimeMs = destination
        }

        let summaryScene = scenes[summaryIndex]
        guard summaryScene.eligibility == .eligible,
              summaryScene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let assetID = summaryBridgeAssetID(
            itemId: activeItemId,
            proposalId: proposal.id,
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
            destinationSceneId: destinationSceneId,
            destinationMediaTimeMs: destinationMediaTimeMs,
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

    private func startSkimBridge(_ plan: ResolvedSkimPlaybackPlan) {
        #if canImport(AVFoundation)
        guard let engine else { return }
        let wasPlaying = snapshot.status.isPlaybackActive
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

    private func completeSkimBridge() {
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
        guard let store,
              var asset = (try? store.loadOwnedOfflineAssets())?.first(where: { $0.id == assetID }) else { return }
        if protected {
            asset.protections.insert(.activeSummaryBridge)
        } else {
            asset.protections.remove(.activeSummaryBridge)
        }
        try? store.saveOwnedOfflineAsset(asset)
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
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        for relative in [
            "SourceAudioTranscriptionChunksV3/\(itemId)",
            "SourceAudioTranscriptionWindows/\(itemId)"
        ] {
            let url = caches.appending(path: relative, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
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

    var canJumpToNextChapter: Bool {
        !recordingNavigationIsLocked && snapshot.skimBridgeState == nil && playingImportedCommentary == nil
            && (nextPlaybackChapter != nil || nextPlaybackMediaChapter != nil)
    }

    func jumpToNextChapter() {
        guard canJumpToNextChapter else { return }
        if let chapter = nextPlaybackChapter { jumpToChapter(chapter) }
        else if let chapter = nextPlaybackMediaChapter {
            if selectedItem.mediaChapters.isEmpty { jumpToListeningMapScene(chapter) }
            else { jumpToMediaChapter(chapter) }
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
            snapshot = try engine.endSession()
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
        let normalizedQuery = libraryQuery.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = libraryItems.filter { row in
            let metadataMatch: Bool
            if normalizedQuery.isEmpty {
                metadataMatch = true
            } else {
                metadataMatch = [row.title, row.sourceTitle, row.author]
                    .compactMap { $0 }
                    .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
                    .contains { $0.localizedStandardContains(normalizedQuery) }
            }
            let contentMatch = libraryQuery.contentType == .all || libraryContentType(for: row) == libraryQuery.contentType
            let listeningMatch: Bool
            switch libraryQuery.listeningState {
            case .all: listeningMatch = true
            case .unfinished: listeningMatch = !row.isCompleted
            case .unplayed: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) == 0
            case .inProgress: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) > 0
            case .completed: listeningMatch = row.isCompleted
            }
            let offlineMatch = libraryQuery.offlineState == .all || row.offlineState == libraryQuery.offlineState
            return metadataMatch && contentMatch && listeningMatch && offlineMatch
        }
        return filtered.sorted { lhs, rhs in
            let ordered: ComparisonResult
            switch libraryQuery.sort {
            case .recentlyAdded:
                if lhs.addedAt != nil, rhs.addedAt != nil {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                } else if lhs.storageRecencyRank != rhs.storageRecencyRank {
                    ordered = lhs.storageRecencyRank < rhs.storageRecencyRank ? .orderedAscending : .orderedDescending
                } else {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                }
            case .recentlyListened:
                ordered = compareDates(lhs.lastListenedAt, rhs.lastListenedAt)
            case .title:
                ordered = lhs.title.localizedStandardCompare(rhs.title)
            case .progress:
                let left = lhs.continuationProgressPercent ?? 0
                let right = rhs.continuationProgressPercent ?? 0
                ordered = left == right ? .orderedSame : (left > right ? .orderedAscending : .orderedDescending)
            }
            return ordered == .orderedSame ? lhs.id < rhs.id : ordered == .orderedAscending
        }
    }

    static func loadLibraryListeningFilter(defaults: UserDefaults) -> LibraryListeningStateFilter {
        let key = "libraryListeningStateFilter"
        let saved = LibraryListeningStateFilter(rawValue: defaults.string(forKey: key) ?? "")
        if !defaults.bool(forKey: "libraryUnfinishedDefaultApplied") {
            let selection = saved == nil || saved == .all ? LibraryListeningStateFilter.unfinished : saved!
            defaults.set(selection.rawValue, forKey: key)
            defaults.set(true, forKey: "libraryUnfinishedDefaultApplied")
            return selection
        }
        return saved ?? .unfinished
    }

    var libraryIsCaughtUp: Bool {
        !libraryItems.isEmpty && libraryItems.allSatisfy(\.isCompleted)
            && libraryQuery.listeningState == .unfinished
            && libraryQuery.contentType == .all && libraryQuery.offlineState == .all
            && libraryQuery.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var libraryHidesCompleted: Bool {
        [.unfinished, .unplayed, .inProgress].contains(libraryQuery.listeningState)
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
        var selections: [String] = []
        if libraryQuery.contentType != .all {
            selections.append(Self.displayName(libraryQuery.contentType.rawValue))
        }
        if libraryQuery.listeningState != .all {
            selections.append(Self.displayName(libraryQuery.listeningState.rawValue))
        }
        if libraryQuery.offlineState != .all {
            selections.append(Self.displayName(libraryQuery.offlineState.rawValue))
        }
        return selections.isEmpty ? "All items" : selections.joined(separator: " · ")
    }

    var librarySortDescription: String {
        Self.displayName(libraryQuery.sort.rawValue)
    }

    private nonisolated static func displayName(_ rawValue: String) -> String {
        switch rawValue {
        case "pdf": return "PDF"
        case "epub": return "EPUB"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func libraryContentType(for row: LibraryItemRow) -> LibraryContentTypeFilter {
        if row.sourceReference?.lowercased().contains(".pdf") == true { return .pdf }
        switch row.mediaType.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "article", TargetType.browserOwnedMedia.rawValue: return .article
        case "podcast", TargetType.transcriptBackedMedia.rawValue: return .podcast
        case "audiobook": return .audiobook
        default:
            return row.sourceReferenceType == "url" ? .article : .text
        }
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left > right ? .orderedAscending : .orderedDescending
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
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        defer { recordDeveloperDiagnostic("item.open.end", ["durationMs": String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStart) * 1000))]) }
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            prepareImportedLocalAudioBridges(itemId: id)
            scheduleTextAudioPrewarmIfNeeded(itemId: id)
            listeningMapJSON = ""
            screen = .item
            offerFollowSuggestionIfEligible(itemId: id, store: store)
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    func startItem(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_item") else { return }
        prepareImportedLocalAudioBridges(itemId: id)
        if libraryItems.first(where: { $0.id == id })?.startupAudioState == .preparing {
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
        resetMixWithOtherAudioForNewSession()
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        cancelSleepTimer()
        announcedImportedInterjectionIDs.removeAll()
        pendingImportedCommentary = nil
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
        guard !rejectNavigationOrSessionMutationWhileRecording("open_session") else { return }
        resetMixWithOtherAudioForNewSession()
        announcedImportedInterjectionIDs.removeAll()
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
        resetMixWithOtherAudioForNewSession()
        cancelSleepTimer()
        announcedImportedInterjectionIDs.removeAll()
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
            var item = try store.loadItem(id: id)
            // Completion is an item-level fact, not fabricated listening history.
            guard item.sourceCompletedAt == nil else { return }
            let markedAt = Date()
            item.sourceCompletedAt = markedAt
            try store.saveItem(item)
            try refreshLibraryRows(store: store)
            if selectedItem.id == id {
                selectedItem = try loadItemDetail(id: id, store: store)
            }
            completionUndo = (id, item.title, try store.loadItem(id: id).sourceCompletedAt ?? markedAt)
            let completion = completionUndo
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.completionUndo?.itemID == completion?.itemID,
                      self.completionUndo?.markedAt == completion?.markedAt else { return }
                self.completionUndo = nil
            }
        } catch {
            reportFailure(error, context: "Mark complete failed")
        }
    }

    func undoMarkedCompletion() {
        guard let undo = completionUndo,
              !rejectNavigationOrSessionMutationWhileRecording("undo_mark_item_completed") else { return }
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: undo.itemID)
            // Do not overwrite a later completion or rewrite natural session completion.
            guard item.sourceCompletedAt == undo.markedAt else {
                completionUndo = nil
                return
            }
            item.sourceCompletedAt = nil
            try store.saveItem(item)
            try refreshLibraryRows(store: store)
            if selectedItem.id == item.id { selectedItem = try loadItemDetail(id: item.id, store: store) }
            completionUndo = nil
            reportConfirmation("Undid Mark Complete for \(item.title).")
        } catch { reportFailure(error, context: "Undo completion failed") }
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
            reportFailure(error, context: "Offline preparation failed")
        }
    }

    func deleteItem(id: String) {
        moveItemToTrash(id: id)
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
            removeDurableGeneratedAudio(for: item)
            removeEpisodeMapArtifacts(itemId: id)
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
            let items = try ids.map { try store.loadItem(id: $0) }
            for item in items {
                guard item.deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            ids.forEach { podcastDownloadCoordinator?.removeItem($0) }
            items.forEach(removeDurableGeneratedAudio)
            ids.forEach(removeEpisodeMapArtifacts)
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
        guard !rejectNavigationOrSessionMutationWhileRecording("set_media_playback_rate") else { return }
        let clamped = max(0.5, min(2.0, (rate * 4).rounded() / 4))
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

    func seekMedia(toMediaTimeMs mediaTimeMs: Int) {
        recordDeveloperDiagnostic("seek.media.request", ["timeMs": String(mediaTimeMs)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
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
        supportedPlaybackRates.first(where: { $0 > current + 0.001 }) ?? supportedPlaybackRates[0]
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

    func seekText(toCharOffset charOffset: Int) {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        recordDeveloperDiagnostic("seek.text.request", ["offset": String(charOffset)])
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
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

    func stopStalledPodcastStart(itemID: String) {
        guard snapshot.itemId == itemID, snapshot.status == .starting,
              selectedPodcastDownloadState != nil else { return }
        pause()
        reportFailure("Podcast playback did not start. Use Download Again in More to replace the saved audio, then press Play.")
    }

    func redownloadSelectedPodcast() {
        guard let coordinator = podcastDownloadCoordinator else { return }
        requestedPodcastTransportReplacements.insert(selectedItem.id)
        if coordinator.recordsByItemId[selectedItem.id] == nil {
            prioritizeOfflinePreparation(id: selectedItem.id)
        } else { coordinator.redownload(itemId: selectedItem.id) }
        reportConfirmation("Downloading a fresh copy of the podcast.")
    }

    func retrySelectedPodcastDownload() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download retry is unavailable.")
            return
        }
        podcastDownloadCoordinator?.retry(itemId: selectedItem.id)
        reportSuccess("Retrying podcast download.")
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
        guard !isFinishingInterjection, !isMarginCaptureCoolingDown else { return }
        guard playingImportedCommentary == nil else {
            reportWarning("Return to Source before recording a Margin.")
            return
        }
        guard marginMomentConductor?.isPlayingVoice != true else {
            reportWarning("Skip or finish the Margin that's playing before recording a new one.")
            return
        }
        guard snapshot.skimBridgeState == nil else {
            reportWarning("Margins are unavailable while a scene summary is playing. Pause or cancel Skim first.")
            return
        }
        guard !recordingNavigationIsLocked else { return }
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
                reportSuccess("Recording Margin.")
            }
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
        }
    }

    /// #217: waits as long as the system prompt is up; a slow Allow is still a yes.
    private func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        if let microphonePermissionRequest { return await microphonePermissionRequest() }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await SystemRecordingClient.requestRecordPermission() },
            currentStatus: { Self.microphonePermissionStatus() },
            timeout: .seconds(timeoutSeconds)
        )
        diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied"
        return granted
    }

    private nonisolated static func microphonePermissionStatus() -> PermissionPromptStatus {
        #if canImport(AVFoundation) && os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #else
        return .granted
        #endif
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
        guard snapshot.isRecording else { return }
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            recordSavedInterjectionForOnboarding()
            if let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            reportConfirmation("Margin saved. Transcription is continuing in the background.")
        }
        if !snapshot.isRecording {
            recordingPresentationContext = nil
            refreshMarginRows()
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
        if isRequestingRecordingPermission && !snapshot.isRecording {
            pendingVoiceCaptureRequestID = nil
            isRequestingRecordingPermission = false
            recordingPresentationContext = nil
            return
        }
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
        isRequestingRecordingPermission = false
        pendingVoiceCaptureRequestID = nil
        recordingPresentationContext = nil
        beginWrittenMargin()
    }

    func saveWrittenMargin(text: String) {
        guard let draft = writtenMarginDraft, let engine else { return }
        do {
            snapshot = try engine.saveWrittenInterjection(captureId: draft.capture.id, text: text)
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
        resetMixWithOtherAudioForNewSession()
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
                reportFailure("A Margin summary already exists for this session.")
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
            reportFailure("A Margin summary already exists for this session.")
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
            UserDefaults.standard.set(UUID().uuidString, forKey: "marginOutputDestinationID")
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
            reportConfirmation("Recording stopped.")
            return
        }
        guard let audioPath = interjection.audioPath,
              let url = resolvedInterjectionAudioURL(for: audioPath),
              FileManager.default.fileExists(atPath: url.path) else {
            reportFailure("The saved Margin recording is unavailable.")
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
                        self?.reportFailure("The saved recording could not be played.")
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
            reportConfirmation("Playing recording.")
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

    private func listenToImportedCommentary(_ prompt: ImportedCommentaryPrompt) {
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
            interjectionAudioCompletionTask = Task { @MainActor [weak self, weak item] in
                while !Task.isCancelled, let item {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    let duration = item.duration.seconds
                    let current = item.currentTime().seconds
                    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.05 {
                        self?.stopImportedCommentaryPlayback(resumeSource: true)
                        return
                    }
                    self?.publishImportedCommentaryNowPlaying()
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

    private func setImportedCommentaryPaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard playingImportedCommentary != nil, let player = interjectionAudioPlayer else { return }
        if paused {
            player.pause()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        } else {
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                player.playImmediately(atRate: Float(playingInterjectionAudioRate))
            } catch {
                reportFailure(error, context: "Shared Margin resume failed")
                return
            }
        }
        importedCommentaryIsPaused = paused
        publishImportedCommentaryNowPlaying()
        #endif
    }

    private func publishImportedCommentaryNowPlaying() {
        #if canImport(AVFoundation)
        guard !mixesWithOtherAudio, let prompt = playingImportedCommentary, let player = interjectionAudioPlayer else { return }
        importedMarginRemoteControls.publish(
            sender: prompt.senderLabel, elapsed: player.currentTime().seconds,
            duration: player.currentItem?.duration.seconds ?? .nan,
            rate: importedCommentaryIsPaused ? 0 : Double(player.rate)
        )
        #endif
    }

    private func stopImportedCommentaryPlayback(resumeSource: Bool) {
        let shouldResume = resumeSource && sourceShouldResumeAfterImportedCommentary
        stopInterjectionAudioPlayback()
        playingImportedCommentary = nil
        sourceShouldResumeAfterImportedCommentary = false
        if shouldResume, snapshot.status == .paused { resumePlayback() }
    }

    private func reconcileImportedCommentary(previous: SessionSnapshot, current: SessionSnapshot) {
        guard pendingImportedCommentary == nil,
              playingImportedCommentary == nil,
              current.itemId == selectedItem.id else { return }
        let prompts = importedCommentaryPrompts(includeAnnounced: false)
        let crossed = prompts.filter { prompt in
            if let anchor = prompt.interjection.resolution.localMediaTimeMs,
               previous.currentMediaTimeMs != nil, current.currentMediaTimeMs != nil {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentMediaTimeMs, after: current.currentMediaTimeMs
                )
            }
            if let anchor = prompt.interjection.resolution.localStartChar {
                return PlaybackAnchorCrossing.isCrossed(
                    anchor: anchor, before: previous.currentTextStart, after: current.currentTextStart
                )
            }
            return false
        }.sorted {
            Self.importedCommentaryPosition($0.interjection)
                < Self.importedCommentaryPosition($1.interjection)
        }
        guard let prompt = crossed.first else { return }
        crossed.forEach { announcedImportedInterjectionIDs.insert($0.id) }
        guard prompt.layer.revealMode != .fresh else { return }
        presentImportedCommentaryPrompt(prompt, sourceWasPlaying: current.status.isPlaybackActive)
    }

    private func importedCommentaryPrompts(includeAnnounced: Bool) -> [ImportedCommentaryPrompt] {
        selectedItem.importedCommentaryLayers
            .filter { layer in
                Self.isImportedCommentaryLayerPlaybackEligible(
                    layer,
                    records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
                )
            }
            .flatMap { layer in
                let records = (selectedItem.importedCommentaryInterjections[layer.id] ?? [])
                    .filter { Self.isPlayableImportedCommentaryResolution($0.resolution) }
                    .sorted { lhs, rhs in
                        Self.importedCommentaryPosition(lhs) < Self.importedCommentaryPosition(rhs)
                    }
                return records.enumerated().compactMap { pair -> ImportedCommentaryPrompt? in
                    let (offset, record) = pair
                    guard includeAnnounced || !announcedImportedInterjectionIDs.contains(record.id) else {
                        return nil
                    }
                    return ImportedCommentaryPrompt(
                        layer: layer,
                        interjection: record,
                        index: offset + 1,
                        count: records.count
                    )
                }
            }
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
        announcedImportedInterjectionIDs.insert(prompt.id)
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

    private nonisolated static func importedCommentaryPosition(
        _ interjection: ImportedCommentaryInterjection
    ) -> Int {
        interjection.resolution.localMediaTimeMs
            ?? interjection.resolution.localStartChar
            ?? .max
    }

    nonisolated static func isPlayableImportedCommentaryResolution(
        _ resolution: ImportedAnchorResolution
    ) -> Bool {
        guard !resolution.isAmbiguous else { return false }
        if resolution.localMediaTimeMs != nil {
            return isInlinePodcastResolution(resolution)
        }
        guard resolution.localStartChar != nil else { return false }
        switch resolution.evidenceClass {
        case .articleTextVerified, .exactEdition, .recipientConfirmed:
            return true
        case .transcriptVerified, .acousticVerified, .fused, .mapInterpolated,
             .timestampFallback, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    nonisolated static func marginPlaybackRate(itemPlaybackRate: Double) -> Double {
        guard itemPlaybackRate.isFinite else { return 1 }
        return max(0.25, min(3, itemPlaybackRate))
    }

    private func playImportedCommentaryCue() {
        #if canImport(AVFoundation)
        do {
            commentaryCuePlayer = try AVAudioPlayer(data: Self.doubleChimeWAVData())
            commentaryCuePlayer?.volume = 0.65
            commentaryCuePlayer?.play()
        } catch {
            diagnostics["importedCommentaryCue"] = "failed:\(error.localizedDescription)"
        }
        #endif
    }

    #if canImport(AVFoundation)
    private static func doubleChimeWAVData() -> Data {
        let sampleRate = 44_100
        let segments: [(frequency: Double, seconds: Double)] = [(880, 0.08), (0, 0.08), (1_175, 0.11)]
        var samples: [Int16] = []
        for segment in segments {
            let count = Int(Double(sampleRate) * segment.seconds)
            for index in 0..<count {
                guard segment.frequency > 0 else { samples.append(0); continue }
                let progress = Double(index) / Double(max(1, count - 1))
                let envelope = sin(.pi * progress)
                let value = sin(2 * .pi * segment.frequency * Double(index) / Double(sampleRate)) * envelope * 0.30
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        let payloadBytes = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF"); appendLE(UInt32(36 + payloadBytes)); appendASCII("WAVEfmt ")
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)); appendLE(UInt16(2)); appendLE(UInt16(16)); appendASCII("data")
        appendLE(UInt32(payloadBytes)); samples.forEach { appendLE($0) }
        return data
    }
    #endif

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

    func copyDiagnosticsExport() {
        var safe = diagnostics
            .filter { !Self.diagnosticKeyMayContainUserContent($0.key) }
            .mapValues(Self.redactedDiagnosticValue)
        if let store {
            let stored = PodcastAnchorCaptureDiagnostics.exportEntries(
                sessions: (try? store.loadSessions()) ?? [],
                interjections: { try store.loadInterjections(sessionId: $0) }
            )
            safe.merge(stored.mapValues(Self.redactedDiagnosticValue)) { _, stored in stored }
        }
        safe["developerBuild"] = developerDiagnosticBuild
        safe["developerRecording"] = developerRecording.exportJSON()
        safe["playbackEvents"] = playbackEventRecording.exportJSON()
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
               importedLayerHasValidItemAssociation(existing, store: store) {
                if let itemId = existing.itemId {
                    openItem(id: itemId)
                    if let item = try? store.loadItem(id: itemId), item.mediaType == "audiobook" {
                        Task { @MainActor [weak self] in
                            defer { try? FileManager.default.removeItem(at: root) }
                            guard let self else { return }
                            do {
                                try await self.verifyLocalAudioForImport(item, contents: contents)
                                try await self.activateImportedLocalAudioMaps(item: item, contents: contents)
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
                    itemId = nil
                }
                let item = try itemId.map { try store.loadItem(id: $0) }
                let localItem = item.map(self.localSharedItemIdentity(for:))
                if let item, item.mediaType == "audiobook" {
                    try await self.verifyLocalAudioForImport(item, contents: review.contents)
                }
                let itemText = item?.text
                let disposition: ImportedCommentaryImportDisposition
                if let digest = review.contents.manifest.contentDigest,
                   let existing = try store.loadImportedCommentaryLayer(packageDigest: digest) {
                    try self.repairImportedLayerAssociation(
                        existing,
                        contents: review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        store: store
                    )
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
                    if let item, item.mediaType == "audiobook" {
                        try await self.activateImportedLocalAudioMaps(item: item, contents: review.contents)
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

    private func verifyLocalAudioForImport(_ item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        guard let url = resolvedOwnedAudiobookURL(for: item) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local source audio is unavailable")
        }
        let actualDigest = try await Task.detached(priority: .utility) {
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        }.value
        let recipient = localSharedItemIdentity(for: item)
        guard actualDigest == recipient.exactEditionSHA256,
              ExactLocalAudioImport.matches(contents.manifest.item, recipient) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("The audio bytes do not match this listening package")
        }
        for proposal in contents.listeningMapProposals {
            _ = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: item.id
            )
        }
    }

    private func activateImportedLocalAudioMaps(item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        let store = try requireStore()
        let recipient = localSharedItemIdentity(for: item)
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
        let ledger = offlineStorageLedger ?? OfflineStorageLedger(repository: store, rootDirectory: support)
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
              normalizedSharingURL(canonicalURL) != nil else {
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
            guard let packageResult = packagePodcastLinkResolution(item: item, request: request) else {
                throw error
            }
            diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_resolution_failure"
            result = packageResult
        }
        if result.status == .needsReview {
            // Enclosures match by the file behind their tracking redirects. Duration only breaks ties: shows with
            // dynamic ads report different lengths for the same episode.
            let exactEnclosureMatches = result.candidates.filter {
                PodcastEnclosureIdentity.sameFile($0.audioURL, item.enclosureURL)
            }
            let titleMatches = result.candidates.filter {
                $0.audioURL != nil
                    && $0.title.compare(item.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let titleDurationMatches = titleMatches.filter { durationIsCompatible($0.durationMs, item.durationMs) }
            let selected = exactEnclosureMatches.count == 1 ? exactEnclosureMatches.first
                : titleMatches.count == 1 ? titleMatches.first
                : titleDurationMatches.count == 1 ? titleDurationMatches.first
                : nil
            if let selected {
                result.status = .playable
                result.selectedCandidate = selected
            } else if !result.candidates.contains(where: { $0.audioURL != nil }),
                      let packageResult = packagePodcastLinkResolution(item: item, request: request) {
                // The lookup found the page but no audio at all, so there is nothing to confuse the packet's own
                // enclosure with. Placement still needs recipient evidence.
                diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_lookup_without_audio"
                result = packageResult
            } else {
                throw SessionKitError.persistenceFailed("shared_podcast_item_is_ambiguous")
            }
        }
        guard result.status == .playable,
              let importedItem = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_not_created")
        }
        return importedItem.id
    }

    private func packagePodcastLinkResolution(
        item: SharedItemIdentity,
        request: LinkResolutionRequest
    ) -> LinkResolutionResult? {
        guard item.itemType == .podcast,
              let canonicalURL = item.canonicalURL,
              normalizedSharingURL(canonicalURL) != nil,
              let enclosureURL = item.enclosureURL,
              normalizedSharingURL(enclosureURL) != nil,
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sourceLink = SourceLink(
            url: canonicalURL, provider: "shared_package", title: item.title,
            role: "package_reference"
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: sourceLink,
            title: item.title,
            showTitle: item.showTitle,
            durationMs: item.durationMs,
            publishedAt: item.publishedAt,
            audioURL: enclosureURL,
            confidence: 1
        )
        return LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: sourceLink,
            selectedCandidate: candidate,
            candidates: [candidate]
        )
    }

    private func importedLayerHasValidItemAssociation(
        _ layer: ImportedCommentaryLayer,
        store: SQLiteSessionStore
    ) -> Bool {
        guard layer.sourceResolutionStatus != .wrongSource,
              let itemId = layer.itemId,
              let item = try? store.loadItem(id: itemId) else { return false }
        guard item.deletedAt == nil else { return false }
        return ImportedItemResolver.canRepresentSameWork(
            layer.itemIdentity,
            localSharedItemIdentity(for: item)
        )
    }

    private func repairImportedLayerAssociation(
        _ existing: ImportedCommentaryLayer,
        contents: VerifiedSpokenMarginsPackage,
        itemId: String?,
        localItem: SharedItemIdentity?,
        itemText: String?,
        store: SQLiteSessionStore
    ) throws {
        guard let itemId,
              let localItem,
              let commentary = contents.commentaryLayers.first else {
            throw SessionKitError.persistenceFailed("shared_package_repair_item_is_unavailable")
        }
        let resolution = ImportedItemResolver.resolve(
            item: contents.manifest.item,
            interjections: commentary.interjections,
            against: localItem,
            itemText: itemText
        )
        guard resolution.status != .wrongSource else {
            throw SessionKitError.persistenceFailed("shared_package_repair_source_did_not_match")
        }
        var layer = existing
        layer.itemId = itemId
        layer.sourceResolutionStatus = resolution.status
        try store.saveImportedCommentaryLayer(layer)
        for var interjection in try store.loadImportedCommentaryInterjections(layerId: layer.id) {
            interjection.resolution = resolution.anchorsByPackageScopedId[interjection.packageScopedId]
                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
            try store.saveImportedCommentaryInterjection(interjection)
        }
        diagnostics["lastSpokenMarginsPackageRepair"] = "reassociated:\(layer.id):\(itemId)"
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
        let matches = try store.listItems().filter { item in
            ImportedItemResolver.canRepresentSameWork(itemIdentity, localSharedItemIdentity(for: item))
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    func localSharedItemIdentity(for item: Item) -> SharedItemIdentity {
        let isPodcast = item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile
        let external = item.externalReference.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        let enclosure = item.media?.url.flatMap { normalizedSharingURL($0) == nil ? nil : $0 }
        let localAudioDigest = item.mediaType == "audiobook"
            ? (try? store?.loadOwnedOfflineAssets())?.first(where: {
                $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid
            })?.checksumSHA256 : nil
        return SharedItemIdentity(
            itemType: sharedItemType(for: item),
            canonicalURL: external ?? enclosure,
            originalURL: external,
            title: item.title,
            enclosureURL: enclosure,
            durationMs: item.media?.durationMs,
            normalizedContentSHA256: isPodcast ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? ""),
            exactEditionSHA256: localAudioDigest ?? (isPodcast ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? ""))
        )
    }

    private func normalizedSharingURL(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https" else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        while components.path.hasSuffix("/") && components.path.count > 1 { components.path.removeLast() }
        return components.string
    }

    private func durationIsCompatible(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= max(2_000, Int((Double(rhs) * 0.005).rounded()))
    }

    func handleIncomingURL(_ url: URL) {
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
        session.status == "in_progress" && session.phase != .abandoned
    }

    static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        sessions.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return left == right ? lhs.id < rhs.id : left > right
        }.first { session in
            isResumableSession(session)
                || (session.status == "finished" && session.completionPercent >= 100)
        }
    }

    var selectedItemPreferredContinuationSession: Session? {
        Self.preferredContinuationSession(in: selectedItem.sessions)
    }

    var selectedItemStartupAudioState: NativeTextStartupAudioState {
        libraryItems.first(where: { $0.id == selectedItem.id })?.startupAudioState ?? .notRequired
    }

    var selectedItemStartupAudioProgressDescription: String {
        guard let row = libraryItems.first(where: { $0.id == selectedItem.id }),
              row.startupAudioTargetChunkCount > 0 else {
            return "Preparing opening audio"
        }
        return "Preparing opening audio · \(row.startupAudioCompletedChunkCount) of \(row.startupAudioTargetChunkCount) chunks"
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
            return String(format: "Supertonic %.2fx", speechPlaybackRateMultiplier)
        }
        return String(format: "System %.2fx", speechPlaybackRateMultiplier)
    }

    var speechPlaybackRateMultiplier: Double {
        max(0.5, min(2.0, ((speechRate / 0.5) * 4).rounded() / 4))
    }

    var mediaPlaybackRateDescription: String {
        String(format: "%.2fx", mediaPlaybackRate)
    }

    var compactPlaybackRateDescription: String {
        if isMediaPlaybackSnapshot {
            return String(format: "%.2f×", mediaPlaybackRate)
        }
        return String(format: "%.2f×", speechPlaybackRateMultiplier)
    }

    var playbackHeaderTitle: String {
        let itemTitle = selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedTitle = (snapshot.chapterTitle ?? snapshot.title ?? itemTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotTitle = reportedTitle.isEmpty || reportedTitle.caseInsensitiveCompare(itemTitle) == .orderedSame
            ? (inferredPlaybackChapterTitle ?? itemTitle)
            : reportedTitle
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

    private var inferredPlaybackChapterTitle: String? {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return currentChapter?.title
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            let mediaTimeMs = snapshot.currentMediaTimeMs ?? 0
            let authoredChapters = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
            if let title = authoredChapters.last(where: { $0.startMs <= mediaTimeMs })?.title {
                return title
            }
            return selectedItem.listeningMapScenes
                .sorted { $0.startMs < $1.startMs }
                .last(where: { $0.startMs <= mediaTimeMs })?
                .title
        default:
            return nil
        }
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

    func isCurrentTimelineMediaChapter(_ chapter: MediaTimelineChapter) -> Bool {
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue else {
            return false
        }
        if let currentChapterId = engine?.currentSession?.position.chapterId,
           selectedItem.mediaChapters.contains(where: { $0.id == currentChapterId }) {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    func isCurrentTimelineListeningMapScene(_ scene: MediaTimelineChapter) -> Bool {
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let currentTimeMs = snapshot.currentMediaTimeMs else {
            return false
        }
        let scenes = selectedItem.listeningMapScenes.sorted { $0.startMs < $1.startMs }
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return false }
        let endMs = scenes.indices.contains(index + 1) ? scenes[index + 1].startMs : Int.max
        return currentTimeMs >= scene.startMs && currentTimeMs < endMs
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
            let authoredTitles = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
            if !authoredTitles.isEmpty { return authoredTitles }
            return selectedItem.listeningMapScenes
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
        Self.supportsOnDeviceSpeechGenerationStatus(targetType: snapshot.targetType)
            && ttsVoiceSelection.supertonicVoice != nil
            && onDeviceSpeechGenerationStatus != RenderedSpeechGenerationState.inactive.rawValue
    }

    static func supportsOnDeviceSpeechGenerationStatus(targetType: String?) -> Bool {
        switch targetType {
        case TargetType.itemTextTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue:
            return true
        default:
            return false
        }
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
                self.reportFailure(error, context: "Prepared audio retry failed")
            }
        }
    }

    var onDeviceSpeechGenerationStatusDescription: String {
        switch onDeviceSpeechGenerationStatus {
        case RenderedSpeechGenerationState.rendering.rawValue:
            let progress = onDeviceSpeechGenerationProgress
            guard progress.totalChunks > 0 else {
                return "Preparing the full Supertonic audio on this iPhone"
            }
            if isOnDeviceSpeechGenerationDelayed {
                return "Still rendering chunk \(min(progress.completedChunks + 1, progress.totalChunks)) of \(progress.totalChunks) · \(progress.percent)% complete"
            }
            return "Generating full audio · \(progress.percent)% (\(progress.completedChunks) of \(progress.totalChunks) chunks)"
        case RenderedSpeechGenerationState.ready.rawValue:
            return "Prepared audio is ready for playback"
        case RenderedSpeechGenerationState.stopped.rawValue:
            return speechFallbackReason?.listenerExplanation ?? "Generation stopped · using the iOS system voice"
        default:
            return "On-device voice generation is inactive"
        }
    }

    private func updateOnDeviceSpeechGenerationState(_ state: RenderedSpeechGenerationState) {
        if onDeviceSpeechGenerationStatus != state.rawValue { onDeviceSpeechGenerationStatus = state.rawValue }
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        diagnostics["onDeviceSpeechGeneration"] = state.rawValue
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
        humanReadableStatus(sourceTranscriptStatus)
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
        // Multiple short chapters can share one rounded percentage. Prefer
        // the exact source position so the label cannot jump ahead of audio.
        if snapshot.targetType == TargetType.itemTextTTS.rawValue,
           let offset = snapshot.currentTextStart {
            return selectedItem.chapters.last { $0.startChar <= offset } ?? selectedItem.chapters.first
        }
        if let session = engine?.currentSession, session.itemId == selectedItem.id,
           let chapter = selectedItem.chapters.first(where: { $0.id == session.position.chapterId }) {
            return chapter
        }
        if let title = snapshot.chapterTitle,
           let chapter = selectedItem.chapters.first(where: { $0.title == title }) {
            return chapter
        }
        return selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
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
            snapshot: snapshot,
            sharedMarginPrompt: sharedMarginPrompt,
            upcomingSharedMargins: liveActivitySharedMarginNavigationEntries()
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
            let positionPercent: Int?
            if let mediaTimeMs = prompt.interjection.resolution.localMediaTimeMs,
               let mediaDurationMs,
               mediaDurationMs > 0 {
                positionPercent = Int((Double(mediaTimeMs) / Double(mediaDurationMs) * 100).rounded())
            } else if let charOffset = prompt.interjection.resolution.localStartChar,
                      textLength > 0 {
                positionPercent = Int((Double(charOffset) / Double(textLength) * 100).rounded())
            } else {
                positionPercent = nil
            }
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
            reportFailure("Recording a Margin from Watch is disabled until Watch-owned or background-safe recording is available.")
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
                    reportFailure("Microphone access is required to record Margins from Watch.")
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
        recordDeveloperDiagnostic("transport.request", [
            "command": command.rawValue, "origin": origin,
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1),
            "requestedMediaTimeMs": String(mediaTimeMs ?? -1)
        ])
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
            ? playbackRate.map { max(0.5, min(2.0, ($0 * 4).rounded() / 4)) }
            : playbackRate
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
            if command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
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
                guard let text = item.text, !text.isEmpty else { return }
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
        if automaticMarginOutputEnabled { startAutomaticMarginOutput() }
        else { automaticMarginOutputTask?.cancel(); automaticMarginOutputTask = nil; marginOutputStatus = "Automatic delivery is off. Exported files remain in your folder." }
    }

    func startAutomaticMarginOutput() {
        guard automaticMarginOutputEnabled, automaticMarginOutputTask == nil else { return }
        automaticMarginOutputTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.deliverAutomaticMargins()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    func testMarginOutput() {
        Task {
            do {
                guard let folder = resolvedBatchExportFolderURL() else { throw EditionError.invalid("Choose an output folder first.") }
                let writer = try marginWriter()
                _ = try await writer.deliver([.init(id: "sample-margin", markdown: "# Spoken Margins test\n\nYour thoughts will arrive here as Markdown, with source context and anchors.\n")], to: folder, destinationID: marginOutputDestinationID)
                marginOutputStatus = "Test note saved. Open Margin-\(ListeningEdition.digest("sample-margin")).md in your notes app."
            } catch { marginOutputStatus = error.localizedDescription }
        }
    }

    private var marginOutputDestinationID: String {
        UserDefaults.standard.string(forKey: "marginOutputDestinationID") ?? "initial"
    }
    private func marginWriter() throws -> AutomaticMarginWriter {
        if let automaticMarginWriter { return automaticMarginWriter }
        let writer = AutomaticMarginWriter(journalURL: try applicationSupportDirectory().appendingPathComponent("SpokenMargins/MarginOutputJournal.json"))
        automaticMarginWriter = writer
        return writer
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

    func deliverAutomaticMargins() async {
        guard automaticMarginOutputEnabled, !isDeliveringMargins, !snapshot.isRecording, let store else { return }
        isDeliveringMargins = true
        defer { isDeliveringMargins = false }
        do {
            guard let folder = resolvedBatchExportFolderURL() else { throw EditionError.invalid("Choose or reselect an output folder. Your Margins remain safely in the Library.") }
            // Built on a background task (#161); the main actor only waits.
            let gathered = try await AutomaticMarginNoteGatherer.gather(store: store)
            let notes = gathered.notes
            recordAutomaticMarginGather(ms: gathered.elapsedMs, sessions: gathered.sessionCount, notes: notes.count)
            let count = try await marginWriter().deliver(notes, to: folder, destinationID: marginOutputDestinationID)
            marginOutputStatus = "\(count) Margins saved to \(folder.lastPathComponent). Last checked \(Date().formatted(date: .omitted, time: .shortened))."
        } catch { marginOutputStatus = "Delivery needs attention: \(error.localizedDescription)" }
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

    private func applicationSupportDirectory() throws -> URL {
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
            let shouldSkipPreparation = Self.shouldSkipTextAudioPreparation(
                try store.loadSessions(itemId: itemId)
            )
            guard !shouldSkipPreparation else {
                diagnostics["textAudioPrewarm:\(itemId)"] = "skipped_existing_progress"
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
                  !Self.itemIsCompleted(try store.loadSessions(itemId: itemId)),
                  shouldPrewarmTextAudio(for: item),
                  item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            pendingStartupAudioPreparationItemIds.insert(itemId)
            failedStartupAudioPreparationItemIds.remove(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .preparing)
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
                  !Self.itemIsCompleted(try store.loadSessions(itemId: itemId)),
                  let sourceText = item.text,
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
                diagnostics["startupAudioPreparation:\(itemId)"] = "preparing_0_of_\(targetChunkCount)"
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

    private nonisolated static func preparedTextAudioCoversCompleteText(_ prepared: PreparedTextAudio) -> Bool {
        guard let endChar = prepared.timeline.segments.compactMap(\.endChar).max() else {
            return false
        }
        return endChar >= prepared.normalizedText.count
    }

    /// A PDF imported with extraction v2 (C1 M3) is spoken through SessionEngine's
    /// I14 projection. Prepared (pre-rendered) text audio is rendered from Item.text,
    /// which would read its references and tables aloud, so it isn't prepared for
    /// these items yet; they play with live speech.
    private func usesStructuredSpeech(_ item: Item) -> Bool {
        item.mediaType == "pdf" && (try? store?.loadStructuredDocument(itemId: item.id)) != nil
    }

    private func shouldPrewarmTextAudio(for item: Item) -> Bool {
        guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        guard !usesStructuredSpeech(item) else { return false }
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

    static func shouldSkipTextAudioPreparation(_ sessions: [Session]) -> Bool {
        itemIsCompleted(sessions) || sessions.contains { session in
            session.completedAt != nil
                || session.status == "finished"
                || session.phase == .finished
                || session.completionPercent >= textAudioPreparationCutoffPercent
        }
    }

    nonisolated static func itemIsCompleted(_ sessions: [Session]) -> Bool {
        sessions.contains { session in
            session.completedAt != nil
                || session.status == "finished"
                || session.phase == .finished
                || session.completionPercent > 98
        }
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

    private func removeDurableGeneratedAudio(for item: Item) {
        guard item.media?.sourceType == .generatedTTSPrerendered,
              let identifier = item.media?.nativeMediaId ?? item.media?.url,
              let url = URL(string: identifier),
              url.isFileURL,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let generatedDirectory = supportDirectory
            .appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            .standardizedFileURL
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent() == generatedDirectory else { return }
        try? FileManager.default.removeItem(at: file)
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
            reportFailure(error, context: "Prepare text playback failed")
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
                onGenerationStateChange: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationState(state)
                    }
                },
                onGenerationProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationProgress(progress)
                    }
                },
                onPreparationPlan: { itemId, sourceText, plan in
                    // A turn is not a Library item. A source with an audible
                    // overview also has different chunk boundaries from its
                    // source-only offline representation; disk cache still
                    // serves both, keyed by exact spoken text.
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), item.text == sourceText else { return }
                    _ = try? await coordinator.begin(itemId: itemId, sourceText: sourceText, signature: signature, plan: plan, schedulesJob: false)
                },
                onPreparedChunk: { itemId, sourceText, plan, audioURL, durationMs in
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), item.text == sourceText else { return }
                    try? await coordinator.commit(itemId: itemId, signature: signature, plan: plan, sourceText: sourceText, audioURL: audioURL, durationMs: durationMs)
                },
                preparedChunkLookup: { itemId, sourceText, plan in
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), item.text == sourceText else { return nil }
                    return try? await coordinator.committedChunk(itemId: itemId, signature: signature, plan: plan)
                },
                onPreparedAudio: { [weak self] itemId, prepared in
                    Task { @MainActor [weak self] in
                        guard let signature = try? await signatureTask.value, let self else { return }
                        guard let store = self.store,
                              let item = try? store.loadItem(id: itemId),
                              let canonical = Self.canonicalSupertonicPreparedAudio(
                                prepared,
                                itemText: item.text
                              ) else {
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
                        let conditions = SupertonicResourcePolicy.currentConditions(
                            isOnExternalPower: SupertonicResourcePolicy.isOnExternalPower()
                        )
                        let fallbackReason = SpeechFallbackReason(
                            supertonicCode: reason,
                            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
                        )
                        self.speechFallbackReason = fallbackReason
                        self.diagnostics["supertonicFallback"] = reason
                        self.diagnostics["supertonicFallbackReason"] = fallbackReason.rawValue
                        self.diagnostics["supertonicFallbackConditions"] = conditions.logDescription
                        self.diagnostics["supertonicFallbackOffset"] = "\(offset)"
                        let message = fallbackReason.listenerExplanation
                        self.statusMessage = message
                        self.feedbackEvent = UserFeedbackEvent(kind: .warning, message: message)
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
                onResumeDecision: { [weak self] fields in
                    Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic("supertonic.resume", fields) }
                }
            )
        }
        diagnostics["sessionTTS"] = "System speech"
        return SystemSpeechPlaybackClient(
            voiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
            speechRate: Float(speechRate)
        )
    }

    static func canonicalSupertonicPreparedAudio(
        _ prepared: PreparedTextAudio,
        itemText: String?
    ) -> PreparedTextAudio? {
        guard let itemText, !itemText.isEmpty,
              prepared.normalizedText.hasSuffix(itemText) else {
            return nil
        }
        let prefixLength = prepared.normalizedText.count - itemText.count
        guard prefixLength > 0 else { return prepared }
        let itemCharacters = Array(itemText)
        let segments = prepared.timeline.segments.map { segment -> MediaTimelineSegment in
            let originalStart = segment.startChar ?? 0
            let originalEnd = segment.endChar ?? originalStart
            let start = max(0, min(itemCharacters.count, originalStart - prefixLength))
            let end = max(start, min(itemCharacters.count, originalEnd - prefixLength))
            let canonicalText = end > start
                ? String(itemCharacters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                : segment.text
            return MediaTimelineSegment(
                id: segment.id,
                startMs: segment.startMs,
                endMs: segment.endMs,
                startChar: start,
                endChar: end,
                text: canonicalText
            )
        }
        let segmentByID = segments.reduce(into: [String: MediaTimelineSegment]()) {
            $0[$1.id] = $1
        }
        let chapters = prepared.timeline.chapters.compactMap { chapter -> MediaTimelineChapter? in
            guard let segment = segmentByID[chapter.transcriptSegmentId],
                  (segment.endChar ?? 0) > 0 else { return nil }
            let titleWords = segment.text.split(separator: " ").prefix(7).joined(separator: " ")
            return MediaTimelineChapter(
                id: chapter.id,
                title: titleWords.isEmpty ? chapter.title : titleWords,
                description: chapter.description,
                startMs: chapter.startMs,
                transcriptSegmentId: chapter.transcriptSegmentId
            )
        }
        return PreparedTextAudio(
            normalizedText: itemText,
            media: prepared.media,
            timeline: TranscriptTimeline(
                segments: segments,
                chapters: chapters,
                durationMs: prepared.timeline.durationMs
            ),
            createdAt: prepared.createdAt
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
                self?.recordDeveloperDiagnostic("media.stall", fields)
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
                diagnostics["speechPlaybackInterruption"] = "resume_skipped"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                diagnostics["speechPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "resume_failed:\(error.localizedDescription)"
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
            let isCompleted = item.sourceCompletedAt != nil || Self.itemIsCompleted(sessions)
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
                guard latestManifest?.state == .preparing, preparationJob == nil else {
                    return latestManifest?.state
                }
                return .notPrepared
            }()
            let offlineState = Self.libraryOfflineState(
                preparedState: effectivePreparedState,
                mediaSourceType: item.media?.sourceType,
                podcastDownloadState: podcastDownloadsByItemId[item.id]?.state
            )
            return LibraryItemRow(
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
        }
    }

    private func libraryStartupAudioPresentation(
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
           isPreparedTextMediaAvailable(item.media),
           !isStarterPreparedTextMedia(item.media) {
            return (.ready, Self.startupAudioChunkCount, Self.startupAudioChunkCount)
        }
        guard shouldPrewarmTextAudio(for: item) else { return (.notRequired, 0, 0) }
        guard let manifest else {
            return failedStartupAudioPreparationItemIds.contains(item.id)
                ? (.failed, 0, Self.startupAudioChunkCount)
                : (.preparing, 0, Self.startupAudioChunkCount)
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
        if !SupertonicResourcePolicy.allowsRendering()
            || manifest.state == .pausedForThermal {
            return (.paused, completed, target)
        }
        return (.preparing, completed, target)
    }

    nonisolated static func libraryOfflineState(
        preparedState: PreparedAudioState?,
        mediaSourceType: AudioSourceType?,
        podcastDownloadState: PodcastDownloadState?
    ) -> LibraryOfflineStateFilter {
        if let podcastDownloadState {
            switch podcastDownloadState {
            case .availableOffline: return .readyOffline
            case .downloading, .waitingForWiFi: return .preparing
            case .failed, .evicted: return .needsRepreparation
            case .streamingOnly: return .onlineOnly
            }
        }
        if let preparedState {
            switch preparedState {
            case .preparing, .pausedForThermal: return .preparing
            case .readyOffline: return .readyOffline
            case .needsRepreparation, .failed, .stopped: return .needsRepreparation
            case .notPrepared: return .onlineOnly
            }
        }
        return mediaSourceType == .nativeMediaFile ? .readyOffline : .onlineOnly
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
            row.offlineState = Self.libraryOfflineState(
                preparedState: manifest.state == .preparing && job == nil ? .notPrepared : manifest.state,
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

    private func refreshLibraryRows(store: SQLiteSessionStore) throws {
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
        let completedItemIds = Set(itemsById.values.filter { $0.sourceCompletedAt != nil }.map(\.id)).union(Set(
            Dictionary(grouping: try store.loadSessions(), by: \.itemId)
                .filter { Self.itemIsCompleted($0.value) }
                .keys
        ))
        let storedJobs = try store.loadAudioPreparationJobs()
        try store.deleteAudioPreparationJobs(
            ids: storedJobs.filter { $0.policy != .explicit && completedItemIds.contains($0.itemId) }.map(\.id)
        )
        let jobs = storedJobs
            .filter { !$0.isCancelled && ($0.policy == .explicit || !completedItemIds.contains($0.itemId)) }
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
            message = "Ready offline: \(newest.title) and \(newlyCompleted.count - 1) more. Review them in Offline Rendering."
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
            reportConfirmation("Removed \(itemsTitle(itemId: selected.itemId, store: store)) from offline rendering.")
        } catch {
            reportFailure(error, context: "Removing the item from offline rendering failed")
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
            reportConfirmation("Cleared \(jobs.count) offline rendering job\(jobs.count == 1 ? "" : "s"). Existing audio and Library items were kept.")
        } catch {
            reportFailure(error, context: "Clearing the offline rendering queue failed")
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
            reportFailure(error, context: "Unable to prioritize rendering")
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
            reportConfirmation("Updated the offline rendering order.")
        } catch {
            reportFailure(error, context: "Updating the rendering queue failed")
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
                if self.activeItemId == itemId {
                    self.sourceTranscriptStatus = "unavailable"
                    self.snapshot.sourceTranscriptStatus = "unavailable"
                }
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
                    try? FileManager.default.removeItem(at: caches.appending(path: "SourceAudioTranscriptionWindows/\(scratchID)"))
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
           let window = Self.sourceContextWindow(
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
        Task { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs, windowBeforeMs = sourceWindowContextBeforeMs, windowAfterMs = sourceWindowContextAfterMs] in
            guard let self else { return }
            do {
                let analysis = try await self.sourceTranscriptionClient.transcribeSourceAudioWindowWithEvidence(
                    url: transcriptionURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: windowBeforeMs,
                    windowAfterMs: windowAfterMs
                )
                var referenceEvidence: [CapturedPodcastAnchorEvidence] = []
                var referenceEvidenceFailure: String?
                if let localAudioURL = analysis.localAudioURL {
                    do {
                        let request = PostResumeAudioSampleRequest(
                            interjectionId: interjectionId,
                            sessionId: interjection.sessionId,
                            itemId: itemId,
                            anchorMediaTimeMs: anchorMediaTimeMs,
                            targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                        )
                        let outputDirectory = try self.podcastAnchorEvidenceDirectory(for: request)
                        let localAnchorMs = max(0, anchorMediaTimeMs - analysis.sourceStartMs)
                        let generated = try await PodcastAnchorEvidenceGenerator.generate(
                            sourceURL: localAudioURL,
                            anchorMediaTimeMs: localAnchorMs,
                            outputDirectory: outputDirectory,
                            idPrefix: self.podcastAnchorEvidenceID(request: request, suffix: "source-window")
                        )
                        referenceEvidence = generated.map { generated in
                            CapturedPodcastAnchorEvidence(
                                id: generated.id,
                                localPath: generated.fileURL.path,
                                durationMs: generated.durationMs,
                                anchorOffsetMs: generated.anchorOffsetMs,
                                provenance: analysis.provenance == .downloadedSourceReference
                                    ? .downloadedSourceReference
                                    : .sourceWindowReference,
                                windowRole: generated.id.hasSuffix("-pre")
                                    ? .sourceWindowBefore
                                    : .sourceWindowAfter
                            )
                        }
                    } catch {
                        referenceEvidenceFailure = error.localizedDescription
                    }
                    try? FileManager.default.removeItem(at: localAudioURL.deletingLastPathComponent())
                }
                await MainActor.run {
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, sessionId: interjection.sessionId, timeline: analysis.timeline)
                        if !referenceEvidence.isEmpty {
                            try self.persistPodcastAnchorEvidence(
                                request: PostResumeAudioSampleRequest(
                                    interjectionId: interjectionId,
                                    sessionId: interjection.sessionId,
                                    itemId: itemId,
                                    anchorMediaTimeMs: anchorMediaTimeMs,
                                    targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                                ),
                                evidence: referenceEvidence,
                                sourceExactEditionSHA256: nil
                            )
                        }
                        self.refreshSelectedItem()
                        self.refreshMarginRows()
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "complete:speech_window"
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = provenance
                        self.diagnostics[Self.marginDiagnosticKey("sourceWindowSignature", sessionId: interjection.sessionId, interjectionId: interjectionId)] = referenceEvidence.isEmpty
                            ? "unavailable:\(referenceEvidenceFailure ?? "temporary_audio_unavailable")"
                            : "complete:\(referenceEvidence.count)"
                        self.pendingSourceContextInterjectionIds.remove(Self.marginIdentity(interjection))
                        if reportsResult { self.reportConfirmation("Source context recovered.") }
                    }
                }
            } catch {
                await MainActor.run {
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowTranscription", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "failed:\(error.localizedDescription)"
                    self.diagnostics[Self.marginDiagnosticKey("sourceWindowContextProvenance", sessionId: interjection.sessionId, interjectionId: interjectionId)] = "unavailable"
                    self.pendingSourceContextInterjectionIds.remove(Self.marginIdentity(interjection))
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
                && interjection.anchorContextStatus != .ready
                && !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) {
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
                        reportFailure("Saved audio and current transcript kept. Retranscription failed.")
                    } else {
                        run { engine in
                            snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, sessionId: interjection.sessionId, error: failure)
                            refreshSelectedItem()
                        refreshMarginRows()
                            diagnostics[Self.marginDiagnosticKey("interjectionTranscription", interjection)] = "failed:\(failure)"
                            diagnostics["lastInterjectionTranscriptionFailure"] = "\(interjection.id):\(failure)"
                            reportFailure("Audio saved. Transcript failed.")
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
        try applicationSupportDirectory()
            .appending(path: "SpokenMargins/AnchorEvidence", directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(request.sessionId), directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(request.interjectionId), directoryHint: .isDirectory)
    }

    private func podcastAnchorEvidenceID(
        request: PostResumeAudioSampleRequest,
        suffix: String
    ) -> String {
        "anchor-\(safePodcastEvidenceComponent(request.sessionId))-\(safePodcastEvidenceComponent(request.interjectionId))-\(suffix)"
    }

    private func safePodcastEvidenceComponent(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return safe.isEmpty ? "unknown" : String(safe.prefix(96))
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
              var interjection = try store.loadInterjections(sessionId: request.sessionId)
                .first(where: { $0.id == request.interjectionId && $0.itemId == request.itemId }) else {
            throw SessionKitError.persistenceFailed("podcast_anchor_interjection_missing")
        }
        var merged = interjection.podcastAnchorEvidence ?? []
        for newEvidence in evidence {
            merged.removeAll {
                $0.id == newEvidence.id
                    || ($0.windowRole == newEvidence.windowRole && $0.provenance == newEvidence.provenance)
            }
            merged.append(newEvidence)
        }
        interjection.podcastAnchorEvidence = merged.sorted { $0.id < $1.id }
        interjection.sourceExactEditionSHA256 = sourceExactEditionSHA256
        interjection.podcastAnchorEvidenceCaptureStatus = .ready
        if interjection.anchorContextStatus == .pending {
            interjection.anchorContextStatus = .unavailable
        }
        try store.saveInterjection(interjection)
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
              var interjection = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else {
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "unavailable:\(reason)"
            return
        }
        interjection.podcastAnchorEvidenceCaptureStatus = .unavailable
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
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
              var interjection = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else { return }
        interjection.podcastAnchorEvidenceCaptureStatus = .pendingExactLocalCapture
        try? store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    /// Stores a failure without changing capture status, so a fallback that runs next can't hide it.
    private func recordPodcastAnchorEvidenceFailureReason(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) -> Interjection? {
        guard var interjection = storedInterjection(request: request) else { return nil }
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
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
            let transcript = interjection.cleanedTranscript
                ?? interjection.transcript
                ?? interjection.displayText
                ?? ""
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
                warning: SharedMarginTextRequirement.hasReviewedText(transcript)
                    ? shareAnchorWarning(for: interjection)
                    : SharedMarginTextRequirement.reviewWarning,
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
                sharingState.drafts[index].editHistoryIndex -= 1
                applyShareEditState(at: index, renderCleanedAudio: false)
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
        sharingState.drafts[index].isIncluded = included
    }

    func setShareDraftsIncluded(_ ids: [String], included: Bool) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        for index in sharingState.drafts.indices where targetIDs.contains(sharingState.drafts[index].id) {
            sharingState.drafts[index].isIncluded = included
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
                $0.automaticCleanupEnabled = false
                $0.restoredAutomaticDecisionIds.removeAll()
            }
        }
        sharingState.automaticallyCleanedDraftIDs.removeAll()
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = 0
        sharingState.bulkPreparationFailureCount = 0
    }

    func setShareDraftRepresentation(_ id: String, choice: ShareMarginRepresentationChoice) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        if choice == .cleaned, sharingState.drafts[index].cleanedAudioURL == nil { return }
        if choice == .original, originalAudioURL(forShareDraft: id) == nil { return }
        sharingState.drafts[index].representationChoice = choice
    }

    func setShareDraftAnchorBefore(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].anchorBefore = String(value.suffix(BoundedAnchorContext.maximumCharactersPerSide))
    }

    func setShareDraftAnchorAfter(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].anchorAfter = String(value.prefix(BoundedAnchorContext.maximumCharactersPerSide))
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
        recordShareEdit(for: draftID) { state in
            if accepted {
                state.restoredAutomaticDecisionIds.remove(decisionID)
            } else {
                state.restoredAutomaticDecisionIds.insert(decisionID)
            }
        }
    }

    func toggleShareDraftWord(draftID: String, segmentID: String) {
        guard let draft = sharingState.drafts.first(where: { $0.id == draftID }),
              let aligned = draft.interjection.alignedTranscript,
              let segment = aligned.segments.first(where: { $0.id == segmentID }) else { return }
        let overlappingAccepted = draft.cleanup?.decisions.filter {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? []
        recordShareEdit(for: draftID) { state in
            if state.manuallyDeletedSegmentIds.contains(segmentID) || !overlappingAccepted.isEmpty {
                state.manuallyDeletedSegmentIds.remove(segmentID)
                overlappingAccepted.forEach { state.restoredAutomaticDecisionIds.insert($0.id) }
            } else {
                state.manuallyDeletedSegmentIds.insert(segmentID)
            }
        }
    }

    func isShareDraftWordDeleted(draftID: String, segmentID: String) -> Bool {
        guard let draft = sharingState.drafts.first(where: { $0.id == draftID }),
              let segment = draft.interjection.alignedTranscript?.segments.first(where: { $0.id == segmentID }) else {
            return false
        }
        return draft.cleanup?.decisions.contains {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? false
    }

    func undoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].canUndoEdit else { return }
        sharingState.drafts[index].editHistoryIndex -= 1
        applyShareEditState(at: index)
    }

    func redoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].canRedoEdit else { return }
        sharingState.drafts[index].editHistoryIndex += 1
        applyShareEditState(at: index)
    }

    func restoreOriginalShareDraft(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        let interjection = sharingState.drafts[index].interjection
        sharingState.drafts[index].editHistory = [.original]
        sharingState.drafts[index].editHistoryIndex = 0
        sharingState.drafts[index].cleanup = nil
        sharingState.drafts[index].cleanedAudioURL = nil
        sharingState.drafts[index].cleanedAudioDurationMs = nil
        sharingState.drafts[index].isAnalyzingPauses = false
        sharingState.drafts[index].isPreparingCleanup = false
        sharingState.drafts[index].preparationMessage = nil
        sharingState.drafts[index].approvedTranscript = interjection.transcript ?? interjection.displayText ?? ""
        sharingState.drafts[index].representationChoice = originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
        sharingState.drafts[index].warning = SharedMarginTextRequirement.hasReviewedText(sharingState.drafts[index].approvedTranscript)
            ? shareAnchorWarning(for: interjection)
            : SharedMarginTextRequirement.reviewWarning
    }

    private func recordShareEdit(
        for id: String,
        renderCleanedAudio: Bool = true,
        mutate: (inout ShareMarginEditState) -> Void
    ) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].interjection.alignedTranscript != nil else { return }
        var state = sharingState.drafts[index].currentEditState
        mutate(&state)
        guard state != sharingState.drafts[index].currentEditState else { return }
        sharingState.drafts[index].editHistory = Array(
            sharingState.drafts[index].editHistory.prefix(sharingState.drafts[index].editHistoryIndex + 1)
        ) + [state]
        sharingState.drafts[index].editHistoryIndex += 1
        applyShareEditState(at: index, renderCleanedAudio: renderCleanedAudio)
    }

    private func applyShareEditState(at index: Int, renderCleanedAudio: Bool = true) {
        guard sharingState.drafts.indices.contains(index),
              let aligned = sharingState.drafts[index].interjection.alignedTranscript else { return }
        let state = sharingState.drafts[index].currentEditState
        let allAutomatic = DeterministicInterjectionCleanup.propose(aligned).decisions.map(\.id)
        var restored = state.restoredAutomaticDecisionIds
        if !state.automaticCleanupEnabled {
            restored.formUnion(allAutomatic)
            restored.formUnion(sharingState.drafts[index].acousticPauseDecisions.map(\.id))
        }
        let core = DeterministicInterjectionCleanup.propose(
            aligned,
            restoredDecisionIds: restored,
            manuallyDeletedSegmentIds: state.manuallyDeletedSegmentIds
        )
        let acoustic = sharingState.drafts[index].acousticPauseDecisions.map { decision in
            InterjectionCleanupDecision(
                id: decision.id,
                kind: decision.kind,
                startMs: decision.startMs,
                endMs: decision.endMs,
                originalText: decision.originalText,
                accepted: !restored.contains(decision.id)
            )
        }
        let visibleCoreDecisions = acoustic.isEmpty
            ? core.decisions
            : core.decisions.filter { $0.kind != .longPause }
        let hasEdits = visibleCoreDecisions.contains { $0.accepted } || acoustic.contains { $0.accepted }
        sharingState.drafts[index].cleanup = hasEdits
            ? InterjectionCleanupResult(
                policyVersion: core.policyVersion,
                cleanedTranscript: core.cleanedTranscript,
                decisions: (visibleCoreDecisions + acoustic).sorted { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
            )
            : nil
        sharingState.drafts[index].approvedTranscript = hasEdits
            ? core.cleanedTranscript
            : (sharingState.drafts[index].interjection.transcript ?? sharingState.drafts[index].interjection.displayText ?? "")
        if hasEdits, renderCleanedAudio {
            renderCleanup(forShareDraft: sharingState.drafts[index].id)
        } else {
            sharingState.drafts[index].isPreparingCleanup = false
            sharingState.drafts[index].cleanedAudioURL = nil
            sharingState.drafts[index].cleanedAudioDurationMs = nil
            sharingState.drafts[index].representationChoice = originalAudioURL(forShareDraft: sharingState.drafts[index].id) == nil ? .textOnly : .original
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
        guard selectedItem.isNativeAudio && (interjection.podcastAnchorEvidence ?? []).isEmpty else {
            return nil
        }
        switch interjection.podcastAnchorEvidenceCaptureStatus {
        case .pendingPostResumeSample:
            return "High-reliability evidence is capturing. Continue podcast playback for about 12 seconds before sharing this Margin."
        case .pendingExactLocalCapture:
            return "High-reliability evidence is being prepared from the podcast edition currently playing."
        case .ready:
            return nil
        case .unavailable, nil:
            return "High-reliability anchor evidence was unavailable at capture. Transcript context may still resolve this Margin; a timestamp alone will not be treated as verified."
        }
    }

    static func mapProposalsForMarginExport(_ proposals: [PortableListeningMapProposalArtifact]) -> [PortableListeningMapProposalArtifact] {
        // The app exports reviewed Margins and textual map proposals, not the
        // local/imported Skim audio. Do not reference unselected voice assets.
        proposals.map { proposal in
            PortableListeningMapProposalArtifact(
                id: proposal.id, schemaVersion: proposal.schemaVersion,
                languageCode: proposal.languageCode, createdAt: proposal.createdAt,
                generator: proposal.generator,
                scenes: proposal.scenes.map { scene in
                    PortableListeningMapScene(
                        id: scene.id, order: scene.order, title: scene.title,
                        summaryText: scene.summaryText, summaryAssetId: nil,
                        summaryProvenance: scene.summaryProvenance,
                        eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                        startAnchor: scene.startAnchor, endAnchor: scene.endAnchor
                    )
                }
            )
        }
    }

    func exportSharedInterjections(presentsReadySheet: Bool = true) {
        guard !sharingState.isBulkPreparing else {
            sharingState.errorMessage = "Finish or cancel bulk preparation before sharing."
            return
        }
        // A packet can't carry a Margin without words (#304), so say what was left out.
        let included = sharingState.drafts.filter(\.isIncluded)
        let drafts = included.filter { SharedMarginTextRequirement.hasReviewedText($0.approvedTranscript) }
        let omission = SharedMarginTextRequirement.omissionNotice(omitted: included.count - drafts.count, remaining: drafts.count)
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
            let itemTransport = reviewedItemTransport(for: item, identity: itemIdentity)
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
                let anchor = portableAnchor(
                    for: draft.interjection,
                    item: item,
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
                    representation: representation
                ))
            }

            let mapProposals = Self.mapProposalsForMarginExport(try store.loadPortableListeningMapProposals(itemId: item.id))
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
                mapProposals: mapProposals,
                fingerprintSpines: fingerprintSpines,
                phraseSketches: phraseSketches,
                machineEvidence: machineEvidence,
                senderDisplayLabel: sharingState.senderDisplayLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            let directory = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/SharedPackages", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(safeShareFilename(item.title))-\(packageID.suffix(8)).spokenmargins")
            _ = try SpokenMarginsPackageArchive.write(prepared, to: destination)
            UserDefaults.standard.set(sharingState.senderDisplayLabel, forKey: "sharingSenderDisplayLabel")
            sharedSpokenMarginsPackageURL = destination
            sharingState.isExporting = false
            if presentsReadySheet {
                isSharingInterjectionsPresented = false
                isSharedSpokenMarginsPackagePresented = true
            }
            diagnostics["lastSharedPackage"] = "margins=\(drafts.count);omitted=\(included.count - drafts.count);evidence=\(machineEvidence.count);map=\(mapProposals.isEmpty ? "preparing_or_unavailable" : "included")"
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
        let isPodcast = item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile
        let external = item.externalReference.flatMap { normalizedSharingURL($0) }
        let enclosure = item.media?.url.flatMap { URL(string: $0)?.scheme?.lowercased() == "https" ? $0 : nil }
        let draftDigests = drafts.compactMap { $0.interjection.sourceExactEditionSHA256 }
        let exactDigest = draftDigests.count == drafts.count && Set(draftDigests).count == 1
            ? draftDigests.first
            : nil
        let articleExact = isPodcast ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? "")
        let articleNormalized = isPodcast ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? "")
        return SharedItemIdentity(
            itemType: sharedItemType(for: item),
            canonicalURL: external ?? enclosure,
            originalURL: external,
            title: item.title,
            enclosureURL: enclosure,
            durationMs: item.media?.durationMs,
            normalizedContentSHA256: articleNormalized,
            exactEditionSHA256: exactDigest ?? localSharedItemIdentity(for: item).exactEditionSHA256 ?? articleExact
        )
    }

    private func reviewedItemTransport(
        for item: Item,
        identity: SharedItemIdentity
    ) -> ReviewedItemTransportSelection {
        if identity.canonicalURL != nil {
            return .reference
        }
        let text = item.text ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sharingState.isAppAuthoredItem || sharingState.confirmsPrivateSharingRights {
            return .embeddedText(
                text: text,
                originalMediaType: identity.itemType.rawValue,
                rightsBasis: sharingState.isAppAuthoredItem ? .appAuthored : .senderConfirmedPrivateRights
            )
        }
        return .recipientSupplied
    }

    /// Mirrors the link the packet builder keeps, so the share screen never promises a private feed link (#168).
    private func secureSharedItemURL(for item: Item) -> String? {
        ShareableLinkPolicy.shareableLink(
            item.externalReference.flatMap(normalizedSharingURL)
                ?? item.media?.url.flatMap(normalizedSharingURL)
        )
    }

    private func sharedItemType(for item: Item) -> SharedItemType {
        if item.mediaType == "audiobook" { return .other }
        if item.media?.sourceType == .remoteStream || item.media?.sourceType == .nativeMediaFile {
            return .podcast
        }
        let extensionName = URL(fileURLWithPath: item.externalReference ?? "").pathExtension.lowercased()
        if extensionName == "pdf" { return .pdf }
        if extensionName == "epub" { return .epub }
        return .text
    }

    private func portableAnchor(
        for interjection: Interjection,
        item: Item,
        machineEvidenceAssetIds: [String]
    ) -> PortableAnchorEvidence {
        let exactText: String?
        if !selectedItem.isNativeAudio,
           interjection.anchor.endChar > interjection.anchor.startChar,
           interjection.anchor.endChar <= (item.text ?? "").count {
            let text = item.text ?? ""
            let lower = text.index(text.startIndex, offsetBy: interjection.anchor.startChar)
            let upper = text.index(text.startIndex, offsetBy: interjection.anchor.endChar)
            exactText = String(text[lower..<upper])
        } else {
            exactText = nil
        }
        let chapter = selectedItem.mediaChapters.last {
            $0.startMs <= (interjection.anchor.mediaTimeMs ?? -1)
        }?.title
        return PortableAnchorEvidence(
            anchorType: interjection.anchor.anchorType,
            startChar: selectedItem.isNativeAudio ? nil : interjection.anchor.startChar,
            endChar: selectedItem.isNativeAudio ? nil : interjection.anchor.endChar,
            exactText: exactText,
            prefix: interjection.anchor.anchorBefore,
            suffix: interjection.anchor.anchorAfter,
            mediaTimeMs: interjection.anchor.mediaTimeMs,
            roughPercent: interjection.roughPercent,
            transcriptSegmentId: interjection.anchor.transcriptSegmentId,
            chapterTitle: chapter,
            machineEvidenceAssetIds: machineEvidenceAssetIds
        )
    }

    private func audioDurationMs(at url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return max(1, Int((Double(file.length) / file.processingFormat.sampleRate * 1_000).rounded()))
    }

    private func safeShareFilename(_ value: String) -> String {
        let normalized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((normalized.isEmpty ? "Spoken-Margins" : normalized).prefix(80))
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
        guard layer.deletedAt == nil,
              layer.isEnabled,
              layer.sourceResolutionStatus != .wrongSource else { return false }
        return records.contains { isPlayableImportedCommentaryResolution($0.resolution) }
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

    func deleteImportedCommentaryLayer(_ layerID: String) {
        updateImportedCommentaryLayer(layerID) {
            $0.deletedAt = Date()
            $0.isEnabled = false
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

    private func resolvedInterjectionAudioURL(for path: String) -> URL? {
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

    /// Stored Margin audio paths may be absolute paths from an earlier app container
    /// (container UUIDs change on reinstall, restore, and some updates). Rebase them onto
    /// the current Application Support directory instead of failing.
    nonisolated static func resolvedInterjectionAudioURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        if path.hasPrefix("interjections/"), let applicationSupportDirectory {
            let legacyURL = applicationSupportDirectory.appending(path: "SpokenMargins").appending(path: path)
            if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        }
        return resolvedApplicationSupportAssetURL(
            for: path, applicationSupportDirectory: applicationSupportDirectory
        )
    }

    private func resolvedApplicationSupportAssetURL(for path: String) -> URL? {
        Self.resolvedApplicationSupportAssetURL(
            for: path,
            applicationSupportDirectory: try? applicationSupportDirectory()
        )
    }

    nonisolated static func resolvedApplicationSupportAssetURL(
        for path: String,
        applicationSupportDirectory: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path)
        if directURL.isFileURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        guard let applicationSupportDirectory else { return nil }
        let supportMarker = "/Library/Application Support/"
        if let markerRange = path.range(of: supportMarker) {
            let relativePath = String(path[markerRange.upperBound...])
            let relocatedURL = applicationSupportDirectory.appending(path: relativePath)
            if fileManager.fileExists(atPath: relocatedURL.path) {
                return relocatedURL
            }
        }
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let relativeURL = applicationSupportDirectory.appending(path: relativePath)
        return fileManager.fileExists(atPath: relativeURL.path) ? relativeURL : nil
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
        if let urlError = error as? URLError {
            message = Self.userFacingMessage(for: urlError)
        } else if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "))
    }

    /// URLError's default description is a raw domain/code string, which is not useful to a listener.
    nonisolated static func userFacingMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "The request timed out. Please try again."
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "You appear to be offline. Check your connection and try again."
        case .badServerResponse, .fileDoesNotExist, .resourceUnavailable, .zeroByteResource:
            return "The server couldn’t provide anything at that address. Check the link and try again."
        case .badURL, .unsupportedURL, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "That address couldn’t be reached. Check the link and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "A secure connection to that site couldn’t be made."
        default:
            return "The network request failed. Please try again."
        }
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
            selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: activeItemId)
            offerFollowSuggestionIfEligible(itemId: activeItemId, store: store)
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
        let proposals = try store.loadPortableListeningMapProposals(itemId: id)
        let proposal = projection.flatMap { projection in
            proposals.first(where: { $0.id == projection.proposalId })
        } ?? proposals.first
        let exactIdentityProjection = projection?.algorithmVersion == "episode-projection.exact-edition.v1"
            || (projection?.points.isEmpty == false
                && projection?.points.allSatisfy {
                    ($0.confidence == .exactEdition || $0.confidence == .verified)
                        && $0.recipientMediaTimeMs == $0.sourceMediaTimeMs
                } == true)
        let listeningMapScenes = proposal?.scenes
            .sorted { $0.order < $1.order }
            .compactMap { scene -> MediaTimelineChapter? in
                guard let sourceStartMs = scene.startAnchor.mediaTimeMs,
                      let startMs = projection?.projectedRecipientTime(for: sourceStartMs)
                        ?? (exactIdentityProjection ? sourceStartMs : nil) else {
                    return nil
                }
                let title = scene.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \(scene.order + 1)"
                return MediaTimelineChapter(
                    id: scene.id,
                    title: displayTitle,
                    description: scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    startMs: startMs,
                    transcriptSegmentId: scene.startAnchor.transcriptSegmentId ?? scene.id
                )
            }.sorted { $0.startMs < $1.startMs } ?? []
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
        try configureOfflineServices(store: store)
        podcastDownloadCoordinator?.shutdown()
        let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) ?? .defaultValue
        let coordinator = try PodcastDownloadCoordinator(
            store: store,
            ledger: offlineStorageLedger ?? OfflineStorageLedger(
                repository: store,
                rootDirectory: try applicationSupportDirectory()
            ),
            applicationSupportDirectory: try applicationSupportDirectory(),
            cacheLimit: limit,
            monitorsNetwork: !Self.isRunningUnitTests,
            usesBackgroundSession: !Self.isRunningUnitTests
        )
        coordinator.onRecordChanged = { [weak self] record in
            guard let self else { return }
            podcastDownloadRecords[record.itemId] = record
            if let index = libraryItems.firstIndex(where: { $0.id == record.itemId }) {
                let state = Self.libraryOfflineState(
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
        guard let sourceText = item.text,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        guard !usesStructuredSpeech(item) else {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "skipped_structured_pdf"
            statusMessage = "This PDF plays with live speech; preparing its audio ahead isn't available yet."
            return
        }
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
            reportConfirmation("Prioritized \(item.title) for offline rendering.")
            startForegroundAudioPreparationIfNeeded()
        } catch {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
            reportFailure(error, context: "Offline rendering request failed")
        }
    }

    private func startForegroundAudioPreparationIfNeeded() {
        guard foregroundAudioPreparationTask == nil else { return }
        foregroundAudioPreparationGeneration += 1
        let generation = foregroundAudioPreparationGeneration
        foregroundAudioPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, await self.performBackgroundAudioPreparationPass(foregroundDemandOnly: true) {
                await Task.yield()
            }
            if self.foregroundAudioPreparationGeneration == generation {
                self.foregroundAudioPreparationTask = nil
                if Task.isCancelled, self.canPrepareLibraryAudio {
                    self.startForegroundAudioPreparationIfNeeded()
                }
                if let store = self.store {
                    try? self.refreshLibraryRows(store: store)
                }
            }
        }
    }

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
                      let text = item.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suppressedAutomaticAudioPreparationItemIds.contains(item.id),
                      !usesStructuredSpeech(item) else { continue }
                guard item.sourceCompletedAt == nil, !Self.shouldSkipTextAudioPreparation(sessionsByItemId[item.id] ?? []) else {
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
        !SupertonicResourcePolicy.memoryBackoff.isActive()
            && (!snapshot.status.isPlaybackActive || isMediaPlaybackSnapshot
                || snapshot.preparedTextAudioStatus == "ready"
                || (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.canYieldRendererToLibrary == true)
    }

    private func performBackgroundAudioPreparationPass(foregroundDemandOnly: Bool = false) async -> Bool {
        var attemptedJob: AudioPreparationJob?
        // Live speech owns the serial renderer while the listener has active
        // demand. A stale/background job must not queue ahead of its next chunk.
        guard canPrepareLibraryAudio else { return false }
        guard (foregroundDemandOnly || automaticAudioPreparationPolicy == .whileCharging),
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { return false }
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            var queuedJobs = try store.loadAudioPreparationJobs()
                .filter({ !$0.isCancelled })
            if foregroundDemandOnly {
                queuedJobs = queuedJobs.filter {
                    $0.policy == .explicit || ($0.policy == .demandWindow && $0.maximumChunkCount != nil)
                }
            }
            queuedJobs.sort {
                Self.audioPreparationJobPrecedes($0, $1, activeItemId: activePlaybackItemId)
            }
            if queuedJobs.isEmpty, !foregroundDemandOnly {
                await enqueueAutomaticAudioPreparationJobs()
                queuedJobs = try store.loadAudioPreparationJobs()
                    .filter { !$0.isCancelled }
                    .sorted {
                        Self.audioPreparationJobPrecedes($0, $1, activeItemId: activePlaybackItemId)
                    }
            }
            let hasMoreMatchingJobs = {
                let remaining = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
                return foregroundDemandOnly
                    ? remaining.contains(where: { $0.policy == .explicit || ($0.policy == .demandWindow && $0.maximumChunkCount != nil) })
                    : !remaining.isEmpty
            }
            guard var job = queuedJobs.first else { return false }
            guard var manifest = try store.loadPreparedAudioManifest(id: job.manifestId),
                  let item = try? store.loadItem(id: job.itemId),
                  let sourceText = item.text else {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["backgroundAudioPreparation"] = "discarded_missing_source_job"
                return try hasMoreMatchingJobs()
            }
            attemptedJob = job
            recordDeveloperDiagnostic("preparation.selected", ["item": DeveloperDiagnosticRecording.token(job.itemId), "policy": String(describing: job.policy), "nextChunk": String(job.nextChunkIndex)])
            let sourceSessions = try store.loadSessions(itemId: item.id)
            if job.policy != .explicit, item.sourceCompletedAt != nil || Self.shouldSkipTextAudioPreparation(sourceSessions) {
                // Removing speculative work must never invalidate committed audio.
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["automaticAudioPreparation:\(item.id)"] = "cancelled_existing_progress"
                return try hasMoreMatchingJobs()
            }
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
            let completedIndexes = Set(manifest.chunks.map(\.index))
            let ledger = offlineStorageLedger ?? OfflineStorageLedger(repository: store, rootDirectory: support)
            offlineStorageLedger = ledger
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            guard let next = eligiblePlan.first(where: { !completedIndexes.contains($0.index) }) else {
                // All chunks are intact but nothing is assembled (#278): assemble now, because it
                // otherwise happens only right after the last chunk is committed.
                if manifest.isCompleteButUnassembled, manifest.plannedChunkCount == plan.count {
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
                byteCount: 64 * 1_024 * 1_024
            )
            let renderer = try makeSupertonicRenderer()
            renderer.setBackgroundInferencePacingEnabled(true)
            defer { renderer.setBackgroundInferencePacingEnabled(false) }
            let rendered: SupertonicNarrationResult
            do {
                try Task.checkCancellation()
                recordDeveloperDiagnostic("preparation.render.begin", ["item": DeveloperDiagnosticRecording.token(item.id), "chunk": String(next.index)])
                rendered = try await supertonicOutputGuard(wrapping: renderer, systemVoice: speechVoiceIdentifier).render(
                    text: next.text,
                    voice: voice,
                    language: "en",
                    speed: 1,
                    synthesisSteps: 8
                )
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
                    durationMs: Int((rendered.duration * 1_000).rounded())
                )
            } catch {
                try? await ledger.release(reservationId: reservation.id)
                throw error
            }
            guard let updated = try store.loadPreparedAudioManifest(id: manifest.id),
                  let committed = updated.chunks.first(where: { $0.index == next.index }) else {
                try? await ledger.release(reservationId: reservation.id)
                return !foregroundDemandOnly
            }
            try await ledger.commit(
                reservationId: reservation.id,
                asset: OwnedOfflineAsset(
                    id: committed.id,
                    itemId: item.id,
                    category: .preparedChunk,
                    relativePath: "PreparedAudio/\(committed.relativePath)",
                    byteCount: committed.byteCount,
                    checksumSHA256: committed.checksumSHA256,
                    isReproducible: true
                )
            )
            job = (try store.loadAudioPreparationJobs()).first(where: { $0.id == job.id }) ?? job
            recordDeveloperDiagnostic("preparation.committed", ["item": DeveloperDiagnosticRecording.token(item.id), "chunks": String(updated.chunks.count)])
            job.nextChunkIndex = updated.chunks.count
            job.lastFailureCode = nil
            if updated.chunks.count == plan.count {
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
                let completed = Set(updated.chunks.map(\.index))
                let horizon = plan.prefix(min(maximumChunkCount, plan.count))
                if horizon.allSatisfy({ completed.contains($0.index) }) {
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
                reportWarning("Offline rendering paused: \(error.localizedDescription)")
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
        if lhs.userPriority != rhs.userPriority {
            return (lhs.userPriority ?? .max) < (rhs.userPriority ?? .max)
        }
        if let activeItemId, (lhs.itemId == activeItemId) != (rhs.itemId == activeItemId) {
            return lhs.itemId == activeItemId
        }
        let lhsIsOpeningBuffer = lhs.policy == .demandWindow && lhs.maximumChunkCount != nil
        let rhsIsOpeningBuffer = rhs.policy == .demandWindow && rhs.maximumChunkCount != nil
        if lhsIsOpeningBuffer != rhsIsOpeningBuffer {
            return lhsIsOpeningBuffer
        }
        if (lhs.policy == .explicit) != (rhs.policy == .explicit) {
            return lhs.policy == .explicit
        }
        if lhs.policy != rhs.policy {
            if lhs.policy == .demandWindow { return true }
            if rhs.policy == .demandWindow { return false }
        }
        if lhs.requestedAt != rhs.requestedAt {
            return lhs.requestedAt > rhs.requestedAt
        }
        return lhs.id < rhs.id
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
        let byIndex = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.index, $0) })
        let chunks = try plan.map { entry -> SupertonicPreparedChunk in
            guard let committed = byIndex[entry.index] else {
                throw SessionKitError.persistenceFailed("prepared_chunk_missing")
            }
            let slice = RenderedSpeechChunker.sourceSlice(
                from: SpeechTextNormalizer.normalize(sourceText),
                startOffset: entry.startOffset,
                maxCharacters: RenderedSpeechChunker.spokenCostBudget
            )
            return SupertonicPreparedChunk(
                startOffset: entry.startOffset,
                sourceLength: entry.sourceLength,
                text: entry.text,
                boundary: slice.boundary,
                audioURL: support.appending(path: "PreparedAudio/\(committed.relativePath)")
            )
        }
        let assemblyReservation = try await ledger.reserve(
            ownerId: "prepared-artifact-\(manifest.id)",
            byteCount: max(1, manifest.chunks.reduce(0) { $0 + $1.byteCount })
        )
        do {
            let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                itemId: item.id,
                sourceText: sourceText,
                projection: SpeechTextNormalizer.normalizeWithSourceOffsets(sourceText),
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
            for var asset in try store.loadOwnedOfflineAssets() where asset.itemId == item.id && asset.category == .preparedChunk {
                asset.isRedundant = true
                try store.saveOwnedOfflineAsset(asset)
            }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }

    private nonisolated static let preparationPlanCache = PreparedChunkPlanCache()

    private nonisolated static func preparedChunkPlan(for sourceText: String) -> [PreparedChunkPlan] {
        preparationPlanCache.value(for: sourceText) {
            let normalized = SpeechTextNormalizer.normalize(sourceText)
            return RenderedSpeechChunker.sourceSlices(from: normalized, maxCharacters: RenderedSpeechChunker.spokenCostBudget)
                .enumerated()
                .map { index, planned in
                    PreparedChunkPlan(index: index, startOffset: planned.startOffset,
                                      sourceLength: planned.slice.sourceLength, text: planned.slice.text)
                }
        }
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
        followedSourceCoordinator = FollowedSourceCoordinator(repository: store)
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
            await self.refreshFollowedSources(force: false)
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
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    /// #244: a failed Follow said only "FollowedSourceError". Record the case, host and steps.
    private func recordFollowFailure(_ error: Error) async {
        guard let coordinator = followedSourceCoordinator else {
            diagnostics["followSourceFailure"] = FollowedSourceCoordinator.diagnosticCode(for: error)
            return
        }
        diagnostics["followSourceFailure"] = await coordinator.failureDiagnostic(for: error)
    }

    /// B1 drawer: follows a catalog feed (always a public https feed) in one tap. Throws so the
    /// drawer can show the failure on the row.
    /// Returns the followed source's id, which the drawer keeps: the feed can settle on another URL.
    func followCatalogFeed(_ feedURL: String) async throws -> String {
        let store = try requireStore()
        let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
        followedSourceCoordinator = coordinator
        guard let candidate = try await coordinator.discover(urlString: feedURL).first else {
            throw FollowedSourceError.noFeedCandidates
        }
        let sourceId: String
        if let existing = try store.loadFeedSubscriptions().first(where: { $0.source.id == candidate.source.id }) {
            sourceId = existing.source.id
        } else {
            sourceId = try await coordinator.follow(candidate: candidate).source.id
        }
        await refreshFollowedSources(force: false)
        return sourceId
    }

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
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    func cancelFollowSourceCandidates() {
        followedSourceCandidates = []
    }

    var canManuallyFollowSelectedSource: Bool {
        guard sourceFollowSuggestionCandidates.isEmpty,
              let row = libraryItems.first(where: { $0.id == selectedItem.id }),
              ManualFollowPolicy.offersFollow(
                mediaType: row.mediaType, sourceURL: row.sourceURL, sourceReference: row.sourceReference
              ) else {
            return false
        }
        return !Self.isSourceAlreadyFollowed(
            sourceURL: row.sourceURL,
            sourceTitle: row.sourceTitle,
            subscriptions: feedSubscriptions
        )
    }

    /// The selected item's Follow button: an article follows its publication, not a podcast (#243).
    var manualFollowButtonTitle: String {
        ManualFollowPolicy.buttonTitle(mediaType: selectedItemMediaType, isFollowing: isFollowingSelectedSource)
    }

    var manualFollowButtonSymbol: String {
        ManualFollowPolicy.buttonSymbol(mediaType: selectedItemMediaType)
    }

    private var selectedItemMediaType: String {
        libraryItems.first(where: { $0.id == selectedItem.id })?.mediaType ?? "podcast"
    }

    nonisolated static func isSourceAlreadyFollowed(
        sourceURL: String?,
        sourceTitle: String?,
        subscriptions: [FeedSubscription]
    ) -> Bool {
        if let sourceURL = normalizedFollowSourceURL(sourceURL) {
            return subscriptions.contains {
                normalizedFollowSourceURL($0.source.canonicalURL) == sourceURL
            }
        }
        guard let sourceTitle = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceTitle.isEmpty else { return false }
        return subscriptions.contains {
            ($0.source.title ?? $0.source.host).caseInsensitiveCompare(sourceTitle) == .orderedSame
        }
    }

    nonisolated static func uniqueUnfollowedCandidates(
        _ candidates: [SourceCandidateEvidence], subscriptions: [FeedSubscription]
    ) -> [SourceCandidateEvidence] {
        var sourceIDs = Set<String>()
        var urls = Set<String>()
        return candidates.filter { candidate in
            let url = normalizedFollowSourceURL(candidate.source.canonicalURL) ?? candidate.source.canonicalURL
            guard !subscriptions.contains(where: {
                $0.source.id == candidate.source.id
                    || normalizedFollowSourceURL($0.source.canonicalURL) == url
            }) else { return false }
            let newID = sourceIDs.insert(candidate.source.id).inserted
            let newURL = urls.insert(url).inserted
            return newID && newURL
        }
    }

    private nonisolated static func normalizedFollowSourceURL(_ value: String?) -> String? {
        guard let value,
              var components = URLComponents(
                string: value.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !scheme.isEmpty,
              !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
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
                guard let reference = item.sourceURL ?? item.externalReference,
                      let preferredURL = URL(string: reference),
                      preferredURL.scheme?.lowercased() == "https" else {
                    throw FollowedSourceError.invalidURL
                }
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let candidates = try await self.discoverFollowCandidates(
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
                await self.refreshFollowedSources(force: true)
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
              let item = try? store.loadItem(id: itemId),
              let reference = item.sourceURL ?? item.externalReference,
              let url = URL(string: reference),
              url.scheme?.lowercased() == "https" else { return }
        // Opening Item loads its sessions synchronously; Home's display cache
        // may still be awaiting refresh or may have been superseded by navigation.
        let persistedProgress = selectedItem.id == itemId
            ? Self.preferredContinuationSession(in: selectedItem.sessions)?.completionPercent
            : libraryItems.first(where: { $0.id == itemId })?.continuationProgressPercent
        let progress = Self.sourceSuggestionEngagementProgress(
            itemId: itemId, persistedProgress: persistedProgress, snapshot: snapshot
        )
        guard progress >= 25 || (selectedItem.id == itemId && !selectedItem.interjections.isEmpty) else { return }
        sourceSuggestionChecks.insert(itemId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceSuggestionChecks.remove(itemId) }
            do {
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                guard !Self.isSourceAlreadyFollowed(
                    sourceURL: item.sourceURL, sourceTitle: item.sourceTitle,
                    subscriptions: try store.loadFeedSubscriptions()
                ) else { return }
                let candidates = try await self.discoverFollowCandidates(
                    item: item,
                    preferredURL: url,
                    coordinator: coordinator
                )
                guard self.selectedItem.id == itemId,
                      self.screen != .playback || self.snapshot.itemId == itemId,
                      let current = try? store.loadItem(id: itemId),
                      current.sourceURL == item.sourceURL,
                      current.externalReference == item.externalReference,
                      current.media?.url == item.media?.url else {
                    self.diagnostics["sourceFollowSuggestion"] = "discarded_stale_origin"
                    return
                }
                // Following may finish while network discovery is suspended.
                let subscriptions = try store.loadFeedSubscriptions()
                self.feedSubscriptions = subscriptions
                guard !Self.isSourceAlreadyFollowed(
                    sourceURL: current.sourceURL, sourceTitle: current.sourceTitle,
                    subscriptions: subscriptions
                ) else { return }
                let now = Date()
                let eligible = try Self.uniqueUnfollowedCandidates(candidates, subscriptions: subscriptions).filter { candidate in
                    guard let decision = try store.loadSourceSuggestionDecision(sourceId: candidate.source.id) else { return true }
                    if decision.decision == .accepted || decision.decision == .neverSuggest { return false }
                    if let suppressUntil = decision.suppressUntil, suppressUntil > now { return false }
                    if let lastPromptAt = decision.lastPromptAt,
                       now.timeIntervalSince(lastPromptAt) < 30 * 24 * 60 * 60 { return false }
                    return true
                }
                guard !eligible.isEmpty else { return }
                for candidate in eligible {
                    try store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                        id: "suggestion-\(candidate.source.id)",
                        sourceId: candidate.source.id,
                        decision: .prompted,
                        decidedAt: now,
                        lastPromptAt: now
                    ))
                }
                self.sourceFollowSuggestionItemId = itemId
                self.storedSourceFollowSuggestionCandidates = eligible
                self.diagnostics["sourceFollowSuggestion"] = "offered:\(eligible.count)"
            } catch {
                self.diagnostics["sourceFollowSuggestion"] = "unavailable:\(String(describing: type(of: error)))"
                await self.recordFollowFailure(error)
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

    nonisolated static func sourceSuggestionEngagementProgress(
        itemId: String,
        persistedProgress: Int?,
        snapshot: SessionSnapshot
    ) -> Int {
        let liveProgress = snapshot.itemId == itemId ? snapshot.currentPlaybackProgressPercent : 0
        return max(persistedProgress ?? 0, liveProgress)
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
                try store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                    id: "suggestion-\(candidate.source.id)",
                    sourceId: candidate.source.id,
                    decision: .accepted,
                    lastPromptAt: Date()
                ))
                self.storedSourceFollowSuggestionCandidates = []
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                self.reportFailure(error, context: "Follow suggestion failed")
            }
        }
    }

    func deferSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.notNow, suppressFor: 14 * 24 * 60 * 60)
    }

    func rejectSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.neverSuggest, suppressFor: nil)
    }

    private func persistSourceFollowSuggestionDecision(_ decision: SourceSuggestionDecisionKind, suppressFor interval: TimeInterval?) {
        guard let store else { return }
        let now = Date()
        for candidate in sourceFollowSuggestionCandidates {
            let prior = try? store.loadSourceSuggestionDecision(sourceId: candidate.source.id)
            try? store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                id: "suggestion-\(candidate.source.id)",
                sourceId: candidate.source.id,
                decision: decision,
                decidedAt: now,
                suppressUntil: interval.map { now.addingTimeInterval($0) },
                lastPromptAt: prior?.lastPromptAt ?? now
            ))
        }
        storedSourceFollowSuggestionCandidates = []
    }

    func refreshFollowedSources(force: Bool = true) {
        Task { [weak self] in await self?.refreshFollowedSources(force: force) }
    }

    private func refreshFollowedSources(force: Bool) async {
        guard !isRefreshingFollowedSources else { return }
        isRefreshingFollowedSources = true
        defer { isRefreshingFollowedSources = false }
        do {
            let store = try requireStore()
            let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
            followedSourceCoordinator = coordinator
            await coordinator.refreshStale(force: force)
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
        Task { [weak self] in
            try? await coordinator.setEntryState(id: id, state: .dismissed)
            await self?.refreshFollowedSources(force: false)
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
                let imported: Bool
                if subscription.source.kind == .podcastFeed {
                    let importURL = try await self.followedSourceCoordinator?.playableAudioURL(for: entry)
                        ?? entry.audioURL
                        ?? entry.canonicalURL
                    let importedItemId = try await self.importSourceLinkInBackground(SourceLinkHandoff(
                        id: "quick-add-\(entry.id)",
                        inputURL: importURL,
                        sourceSurface: "followed_source",
                        startSession: false
                    ), feedEntry: entry, subscription: subscription)
                    imported = importedItemId != nil
                    if openWhenFinished, let importedItemId { self.openItem(id: importedItemId) }

                } else {
                    let handoff = try await self.readablePageExtractor.extract(url: url)
                    self.diagnostics["followedArticleNetworkHosts"] = self.readablePageExtractor.contactedHosts.joined(separator: ",")
                    self.diagnostics["followedArticleExtractor"] = self.readablePageExtractor.lastExtractor ?? "unknown"
                    if openWhenFinished {
                        imported = self.importBrowserText(handoff)
                    } else {
                        try self.importBrowserTextInBackground(handoff)
                        imported = true
                    }
                }
                guard imported else { return }
                try await self.followedSourceCoordinator?.setEntryState(id: entry.id, state: .imported)
                await self.refreshFollowedSources(force: false)
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
            await self?.refreshFollowedSources(force: false)
        }
    }

    func toggleMuteSource(id: String) {
        guard let coordinator = followedSourceCoordinator,
              let subscription = feedSubscriptions.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            try? await coordinator.setMuted(subscriptionId: id, muted: subscription.state != .muted)
            await self?.refreshFollowedSources(force: false)
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
        if importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store),
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
        guard importedTranscriptRetryDates[item.id].map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        importedTranscriptRetryDates[item.id] = Date()
        diagnostics["recipientAlignmentTranscript:\(item.id)"] = "transcribing_transiently"
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: localSourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                if self.importedPodcastResolutionURLs[item.id] == localSourceURL {
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

    nonisolated static func invalidatePodcastEdition(itemId: String, digest: String, store: SQLiteSessionStore) throws {
        for var layer in try store.loadImportedCommentaryLayers(itemId: itemId)
        where layer.deletedAt == nil && layer.itemIdentity.itemType == .podcast
            && layer.resolvedRecipientEditionSHA256 != digest {
            layer.sourceResolutionStatus = .pending
            layer.resolvedRecipientEditionSHA256 = nil
            try store.saveImportedCommentaryLayer(layer)
            for var note in try store.loadImportedCommentaryInterjections(layerId: layer.id) {
                note.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
                try store.saveImportedCommentaryInterjection(note)
            }
        }
        if let projection = try store.loadResolvedListeningMapProjection(itemId: itemId),
           projection.recipientEditionSHA256 != digest {
            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: projection.id, itemId: itemId, proposalId: projection.proposalId,
                recipientEditionSHA256: digest, points: [], intervals: []))
        }
    }

    nonisolated static func podcastResolution(
        previous: ImportedAnchorResolution, proposed: ImportedAnchorResolution,
        previousEdition: String?, currentEdition: String?, hasTranscript: Bool
    ) -> ImportedAnchorResolution {
        let sameEdition = currentEdition != nil && currentEdition == previousEdition
        let verified = isInlinePodcastResolution(previous)
            && previous.evidenceClass != .timestampFallback && previous.evidenceClass != .mapInterpolated
        let weaker = proposed.evidenceClass == .unresolved || proposed.evidenceClass == .absentFromRecipientEdition
            || (!hasTranscript && proposed.evidenceClass == .ambiguous
                && (previous.evidenceClass == .transcriptVerified || previous.evidenceClass == .fused))
        return sameEdition && verified && weaker ? previous : proposed
    }

    private func resolveImportedPodcastCommentary(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) {
        guard let store,
              let item = try? store.loadItem(id: itemId),
              let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              !layers.isEmpty else { return }
        // Playback refreshes must not cancel a stronger transient-transcript pass.
        guard recipientTranscriptOverride != nil || !transcriptAssistedResolutionItems.contains(itemId)
            || importedPodcastResolutionURLs[itemId] != localURL else { return }
        if importedPodcastResolutionURLs[itemId] != localURL { transcriptAssistedResolutionItems.remove(itemId) }
        importedPodcastResolutionURLs[itemId] = localURL
        let localItem = localSharedItemIdentity(for: item)
        // Persisted transcripts have no byte-edition binding. Only this pass's
        // transient transcript is evidence for the supplied recipient file.
        let recipientTranscript = recipientTranscriptOverride
        let work = layers.compactMap { layer -> (ImportedCommentaryLayer, [ImportedCommentaryInterjection])? in
            guard layer.deletedAt == nil,
                  layer.itemIdentity.itemType == .podcast,
                  let records = try? store.loadImportedCommentaryInterjections(layerId: layer.id),
                  !records.isEmpty else { return nil }
            return (layer, records)
        }
        guard !work.isEmpty else { return }
        if recipientTranscript == nil, importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
        }
        if recipientTranscriptOverride != nil { transcriptAssistedResolutionItems.insert(itemId) }
        let generation = (importedPodcastResolutionGenerations[itemId] ?? 0) + 1
        importedPodcastResolutionGenerations[itemId] = generation
        let applicationSupportDirectory = try? applicationSupportDirectory()
        diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "scheduled:\(work.count)"
        Task.detached { [weak self] in
            do {
                let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                let isCurrent = try await MainActor.run { [weak self] in
                    guard let self, self.importedPodcastResolutionGenerations[itemId] == generation else { return false }
                    try Self.invalidatePodcastEdition(itemId: itemId, digest: recipientDigest, store: store)
                    if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                    return true
                }
                guard isCurrent else { return }
                var resolvedWork: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection], ResolvedListeningMapProjection?)] = []
                for (var layer, records) in work {
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
                    let monotonicResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
                        queries: queries,
                        resolutions: Dictionary(uniqueKeysWithValues: records.map { record in
                            let transcriptResolution = recipientTranscript.map {
                                PodcastTranscriptAnchorResolver.resolve(
                                    anchor: record.anchorEvidence,
                                    recipientTimeline: $0
                                )
                            } ?? ImportedAnchorResolution(
                                evidenceClass: .unresolved,
                                algorithmVersion: "podcast-transcript-anchor.v1"
                            )
                            let acousticResolution = resolutions[record.packageScopedId]
                                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
                            return (
                                record.packageScopedId,
                                PodcastAnchorFusionResolver.fuse(
                                    transcript: transcriptResolution,
                                    acoustic: acousticResolution
                                )
                            )
                        })
                    )
                    let projectedResolutions = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
                        queries: queries,
                        resolutions: monotonicResolutions
                    )
                    let fusedResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
                        queries: queries,
                        resolutions: projectedResolutions
                    )
                    var updated = records
                    for index in updated.indices {
                        if let resolution = fusedResolutions[updated[index].packageScopedId] {
                            updated[index].resolution = Self.podcastResolution(
                                previous: updated[index].resolution, proposed: resolution,
                                previousEdition: layer.resolvedRecipientEditionSHA256,
                                currentEdition: recipientDigest, hasTranscript: recipientTranscript != nil)
                        }
                    }
                    layer.resolvedRecipientEditionSHA256 = recipientDigest
                    let resolutionValues = updated.map(\.resolution)
                    if resolutionValues.allSatisfy(Self.isInlinePodcastResolution) {
                        layer.sourceResolutionStatus = .resolved
                    } else if resolutionValues.contains(where: { $0.evidenceClass == .ambiguous }) {
                        layer.sourceResolutionStatus = .ambiguous
                    } else if resolutionValues.allSatisfy({ $0.evidenceClass == .absentFromRecipientEdition }) {
                        layer.sourceResolutionStatus = .unavailable
                    } else {
                        layer.sourceResolutionStatus = .contextOnly
                    }
                    var mapProjection: ResolvedListeningMapProjection?
                    if let spine = layer.editionFingerprintSpines?.first {
                        let landmarkQueries = spine.landmarks.map { landmark -> PodcastPortableAnchorQuery in
                            let evidence = layer.episodeMapEvidencePaths?[landmark.signatureAssetId]
                                .flatMap { path in
                                    Self.resolvedApplicationSupportAssetURL(
                                        for: path,
                                        applicationSupportDirectory: applicationSupportDirectory
                                    )
                                }
                                .flatMap { try? Data(contentsOf: $0) }
                                .map {
                                    [PodcastAcousticEvidenceQuery(
                                        id: landmark.signatureAssetId,
                                        signatureData: $0,
                                        anchorOffsetMs: landmark.anchorMediaTimeMs - landmark.sourceMediaStartMs
                                    )]
                                } ?? []
                            return PodcastPortableAnchorQuery(
                                packageScopedId: landmark.id,
                                senderMediaTimeMs: landmark.anchorMediaTimeMs,
                                evidence: evidence,
                                evidenceWasDeclared: true
                            )
                        }
                        let landmarkResolutions = try await PodcastAcousticAnchorResolver.resolve(
                            queries: landmarkQueries,
                            recipientAudioURL: localURL,
                            senderExactEditionSHA256: spine.producingEditionSHA256,
                            senderDurationMs: spine.producingEditionDurationMs,
                            strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(layer.itemIdentity, localItem)
                        )
                        let sketch = layer.transcriptPhraseSketches?.first
                        let salt = sketch.flatMap { Data(base64Encoded: $0.saltBase64) }
                        let matches = spine.landmarks.compactMap { landmark -> FingerprintLandmarkMatch? in
                            guard let resolution = landmarkResolutions[landmark.id],
                                  let localTime = resolution.localMediaTimeMs,
                                  !resolution.isAmbiguous else { return nil }
                            var transcriptCorroborated = false
                            if let recipientTranscript, let sketch, let salt,
                               let sourceWindow = sketch.windows.first(where: { $0.id == landmark.transcriptSketchWindowId }) {
                                let localText = recipientTranscript.segments
                                    .filter { $0.endMs > localTime - 15_000 && $0.startMs < localTime + 15_000 }
                                    .map(\.text)
                                    .joined(separator: " ")
                                let localHashes = TranscriptPhraseSketchBuilder.hashes(for: localText, salt: salt)
                                let overlap = Set(localHashes).intersection(sourceWindow.hashes).count
                                transcriptCorroborated = overlap >= 8
                                    && TranscriptPhraseSketchBuilder.overlapScore(localHashes, sourceWindow.hashes) >= 0.2
                            }
                            let exact = resolution.evidenceClass == .exactEdition
                            let direct = resolution.evidenceClass == .acousticVerified
                                || resolution.evidenceClass == .fused
                                || exact
                            guard direct else { return nil }
                            return FingerprintLandmarkMatch(
                                id: "match-\(landmark.id)",
                                landmarkId: landmark.id,
                                sourceMediaTimeMs: landmark.anchorMediaTimeMs,
                                recipientMediaTimeMs: localTime,
                                acousticConfidence: resolution.confidence ?? (exact ? 1 : 0.9),
                                transcriptCorroborated: transcriptCorroborated || exact,
                                isUniqueWithinEpisode: exact || transcriptCorroborated
                            )
                        }
                        mapProjection = EpisodeFingerprintAlignment.makeProjection(
                            id: "imported-projection-\(layer.id)",
                            itemId: itemId,
                            proposalId: layer.listeningMapProposals?.first?.id,
                            recipientEditionSHA256: recipientDigest,
                            matches: matches,
                            exactEdition: spine.producingEditionSHA256 != nil
                                && spine.producingEditionSHA256 == recipientDigest
                        )
                    }
                    resolvedWork.append((layer, updated, mapProjection))
                }
                await MainActor.run {
                    guard let self,
                          self.importedPodcastResolutionGenerations[itemId] == generation,
                          let store = self.store else { return }
                    self.transcriptAssistedResolutionItems.remove(itemId)
                    do {
                        for (layer, records, projection) in resolvedWork {
                            try store.saveImportedCommentaryLayer(layer)
                            for record in records { try store.saveImportedCommentaryInterjection(record) }
                            if let projection { try store.saveResolvedListeningMapProjection(projection) }
                            if projection != nil, let proposal = layer.listeningMapProposals?.first {
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    for scene in proposal.scenes where
                                        scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                                        _ = try? await self.prepareSummaryBridgeAsset(
                                            itemId: itemId,
                                            proposalId: proposal.id,
                                            scene: scene,
                                            store: store
                                        )
                                    }
                                    self.updateSkimAvailability()
                                }
                            }
                        }
                        if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                        let resolvedCount = resolvedWork.filter { $0.0.sourceResolutionStatus == .resolved }.count
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "complete:\(resolvedCount)/\(resolvedWork.count)"
                        if recipientTranscript == nil, self.importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
                            self.scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
                        }
                    } catch {
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "persistence_failed:\(error.localizedDescription)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard self?.importedPodcastResolutionGenerations[itemId] == generation else { return }
                    self?.transcriptAssistedResolutionItems.remove(itemId)
                    self?.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "failed:\(error.localizedDescription)"
                }
            }
        }
    }

    private func importedPodcastCommentaryNeedsTranscript(
        itemId: String,
        store: SQLiteSessionStore
    ) -> Bool {
        guard let layers = try? store.loadImportedCommentaryLayers(itemId: itemId) else { return false }
        return layers.contains { layer in
            guard layer.deletedAt == nil,
                  layer.itemIdentity.itemType == .podcast,
                  let records = try? store.loadImportedCommentaryInterjections(layerId: layer.id) else {
                return false
            }
            return records.contains { record in
                !Self.isInlinePodcastResolution(record.resolution)
                    && PodcastTranscriptAnchorResolver.hasUsableContext(record.anchorEvidence)
            }
        }
    }

    private nonisolated static func isInlinePodcastResolution(_ resolution: ImportedAnchorResolution) -> Bool {
        guard resolution.localMediaTimeMs != nil else { return false }
        switch resolution.evidenceClass {
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused,
             .mapInterpolated, .timestampFallback, .recipientConfirmed:
            return true
        case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
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
