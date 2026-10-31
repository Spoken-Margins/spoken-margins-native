import Combine
import CryptoKit
import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitSharing

/// The canonical sender progression for Build 23. Presentation code may move
/// backward, but it may not skip review or share bytes that have not produced a
/// successful recipient preview.
enum Build23SharingStage: String, CaseIterable, Equatable, Sendable {
    case select
    case review
    case recipientPreview = "recipient_preview"
    case share
}

enum Build23SharingPreviewState: Equatable, Sendable {
    case notBuilt
    case building
    case ready
    case stale
    case failed(String)
}

enum Build23RecipientTransport: String, Equatable, Sendable {
    case reference
    case embeddedText = "embedded_text"
    case recipientSupplied = "recipient_supplied"
}

enum Build23SharingReviewTokenKind: String, Equatable {
    case word
    case pause
}

struct Build23SharingReviewTokenSnapshot: Identifiable, Equatable {
    let id: String
    let kind: Build23SharingReviewTokenKind
    let text: String
    let isRemoved: Bool
    let decisionID: String?
    let segmentID: String?
}

struct Build23SharingMarginSnapshot: Identifiable, Equatable {
    let id: String
    let reviewedText: String
    let representation: ShareMarginRepresentationChoice
    let reviewTokens: [Build23SharingReviewTokenSnapshot]
    let isIncluded: Bool
    let isStarred: Bool
    let privateNote: String?
    let warning: String?
    let preparationMessage: String?
    let anchorBefore: String
    let anchorAfter: String
    let canUndo: Bool
    let canRedo: Bool
    let canPrepareCleanup: Bool
    let automaticCleanupEnabled: Bool
    let isPreparing: Bool
    let hasOriginalVoice: Bool
    let hasCleanedVoice: Bool
    let originalVoiceURL: URL?
    let cleanedVoiceURL: URL?
    /// The stand-in words a word-less voice Margin starts with (#3027); `nil` when it had words of its own.
    var placeholderText: String? = nil
    /// The words that will be sent are still the placeholder.
    var isShowingPlaceholder = false
}

extension Build23SharingMarginSnapshot {
    /// Included, but with no reviewed words, so the packet can't carry it (#1185).
    var isLeftOutForMissingText: Bool {
        isIncluded && !SharedMarginTextRequirement.hasReviewedText(reviewedText)
    }

    /// The words VoiceOver reads for the Margin, saying when they are only the placeholder (#3027).
    var spokenWordsDescription: String {
        isShowingPlaceholder ? "placeholder words: \(reviewedText)" : reviewedText
    }

    /// What VoiceOver says about the Margin's place in the packet; matches the visible status.
    var shareStatusDescription: String {
        isLeftOutForMissingText ? "left out, no transcript yet" : (isIncluded ? "included" : "not included")
    }
}

struct Build23RecipientPreviewMargin: Identifiable, Equatable, Sendable {
    let id: String
    let reviewedText: String
    let representation: String
    let positionDescription: String
    let includesVoice: Bool
}

/// A projection made only from a successfully round-tripped archive. It is not
/// a projection of draft UI state.
struct Build23VerifiedRecipientPreview: Equatable, Sendable {
    let packageID: String
    let contentDigest: String
    let fileURL: URL
    let fileByteCount: Int
    let itemTitle: String
    let senderLabel: String
    let transport: Build23RecipientTransport
    let margins: [Build23RecipientPreviewMargin]
    let voiceAssetCount: Int
    let acousticEvidenceCount: Int
    let listeningMapProposalCount: Int
    let disclosures: [String]
}

struct Build23SharingSnapshot: Equatable {
    let stage: Build23SharingStage
    let itemTitle: String
    let senderDisplayLabel: String
    let includesAcousticEvidence: Bool
    let confirmsPrivateSharingRights: Bool
    let transport: Build23RecipientTransport
    let selectedMarginID: String?
    let filter: ShareMarginDraftFilter
    let margins: [Build23SharingMarginSnapshot]
    let isPreparingSelection: Bool
    let isPreparingAll: Bool
    let preparationCompleted: Int
    let preparationTotal: Int
    let preparationFailures: Int
    let autoCleanSelectedEnabled: Bool
    let needsAutoCleanDecision: Bool
    let previewState: Build23SharingPreviewState
    let verifiedPreview: Build23VerifiedRecipientPreview?
    let errorMessage: String?
    let canAdvance: Bool
    let canShareVerifiedFile: Bool
}

extension Build23SharingSnapshot {
    /// What the packet will hold. The Review and Share buttons count this, not the include flags.
    var selectionSummary: SharedMarginSelectionSummary {
        SharedMarginSelectionSummary(margins, isIncluded: { $0.isIncluded }, text: { $0.reviewedText })
    }
}

struct Build23RecipientImportSnapshot: Equatable {
    let itemTitle: String
    let senderLabel: String
    let marginCount: Int
    let transport: Build23RecipientTransport
    let includesEmbeddedItem: Bool
    let requiresRecipientSource: Bool
    let isImporting: Bool
    let errorMessage: String?
    let canImport: Bool
    /// A podcast packet whose source was private: the sender's links were dropped (#168), so the
    /// recipient can recover the episode from their own feed (#454).
    var isPrivatePodcastSource = false
    /// Set for a file that carries a Listening Map and no Margins (#1471): how many chapters it holds.
    var mapChapterCount: Int? = nil
    /// The item already has a different shared map; adding this one replaces it.
    var replacesExistingMap = false

    var isListeningMap: Bool { mapChapterCount != nil }
}

struct Build23RecipientSourceRequest: Identifiable, Equatable {
    let id: String
    let packageURL: URL
    let itemTitle: String
    let itemType: SharedItemType
    let acceptedSourceKinds: [String]
}

struct Build23ImportedMarginSnapshot: Identifiable, Equatable {
    let id: String
    let reviewedText: String
    let resolution: AnchorResolutionEvidenceClass
    let positionDescription: String
    let isPlayable: Bool
    let hasVoice: Bool
    /// Shown instead of the resolution while the Margin is being placed (#872).
    var placementLabel: String? = nil
}

struct Build23ImportedLayerSnapshot: Identifiable, Equatable {
    let id: String
    let senderLabel: String
    let itemTitle: String
    let integrity: ImportedCommentaryIntegrityStatus
    let sourceResolution: ImportedSourceResolutionStatus
    let isEnabled: Bool
    let isMuted: Bool
    let revealMode: ImportedCommentaryRevealMode
    let listeningMapProposalCount: Int
    let margins: [Build23ImportedMarginSnapshot]
}

/// Canonical sender actions. Ultra UI work should call these actions rather
/// than mutating Gate1AppModel or InterjectionSharingState directly.
enum Build23SenderAction: Equatable {
    case begin
    case setFilter(ShareMarginDraftFilter)
    case setSenderDisplayLabel(String)
    case setIncludesAcousticEvidence(Bool)
    case setPrivateSharingRightsConfirmed(Bool)
    case setIncluded(id: String, included: Bool)
    case setVisibleIncluded(ids: [String], included: Bool)
    case setAutoCleanSelectedEnabled(Bool)
    case selectMargin(String?)
    case setRepresentation(id: String, choice: ShareMarginRepresentationChoice)
    case setAnchorBefore(id: String, text: String)
    case setAnchorAfter(id: String, text: String)
    case setReviewedWords(id: String, text: String)
    case prepareCleanup(id: String)
    case setCleanupDecision(draftID: String, decisionID: String, accepted: Bool)
    case toggleTranscriptWord(draftID: String, segmentID: String)
    case undo(id: String)
    case redo(id: String)
    case restoreOriginal(id: String)
    case prepareAllIncluded
    case cancelPreparation
    case returnToSelect
    case advanceToReview
    case buildRecipientPreview
    case presentSystemShare
    case returnFromSystemShare
    case cancel
}

enum Build23RecipientAction: Equatable {
    case requestMissingSource
    case dismissSourceRequest
    case resumeAfterAddingSource
    case confirmImport
    case cancelImport
    case setLayerEnabled(id: String, enabled: Bool)
    case setLayerMuted(id: String, muted: Bool)
    case setLayerRevealMode(id: String, mode: ImportedCommentaryRevealMode)
    case listenToMargin(layerID: String, marginID: String)
}

@MainActor
protocol Build23SharingCoordinating: AnyObject {
    var snapshot: Build23SharingSnapshot { get }
    var recipientSnapshot: Build23RecipientImportSnapshot? { get }
    var pendingRecipientSourceRequest: Build23RecipientSourceRequest? { get }
    var verifiedShareFileURL: URL? { get }
    var importedLayers: [Build23ImportedLayerSnapshot] { get }

    func send(_ action: Build23SenderAction)
    func send(_ action: Build23RecipientAction)
}

/// Steward-owned adapter between the existing implementation and the Build 23
/// experience. Sender and recipient views can be built independently against
/// this type while shared model/root files stay frozen.
@MainActor
final class Build23SharingCoordinator: ObservableObject, Build23SharingCoordinating {
    @Published private(set) var stage: Build23SharingStage = .select
    @Published private(set) var selectedMarginID: String?
    @Published private(set) var previewState: Build23SharingPreviewState = .notBuilt
    @Published private(set) var verifiedPreview: Build23VerifiedRecipientPreview?
    @Published private(set) var pendingRecipientSourceRequest: Build23RecipientSourceRequest?

    private let model: Gate1AppModel
    /// Recovers a private-feed packet's episode from the recipient's own feed (#454).
    let episodeRecovery: SharedEpisodeRecovery
    private var previewFingerprint: String?
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var modelChangeCancellables: Set<AnyCancellable> = []
    private var modelChangePending = false
    @Published private(set) var importedLayers: [Build23ImportedLayerSnapshot] = []

    init(model: Gate1AppModel) {
        self.model = model
        episodeRecovery = SharedEpisodeRecovery(services: SharedEpisodeRecovery.services(model: model))
        importedLayers = makeImportedLayers(from: model.selectedItem)
        model.$selectedItem.sink { [weak self] item in
            guard let self else { return }
            let layers = self.makeImportedLayers(from: item)
            if self.importedLayers != layers { self.importedLayers = layers }
        }.store(in: &modelChangeCancellables)
        // A different package (or none) starts the episode recovery over.
        model.$spokenMarginsPackageImportReview
            .map { $0?.contents.manifest.packageId }
            .removeDuplicates()
            .sink { [weak self] _ in self?.episodeRecovery.reset() }
            .store(in: &modelChangeCancellables)
        // Playback position and diagnostics are not sharing inputs. Observe the
        // relevant publishers and coalesce their willSet notifications.
        model.$sharingState.map { _ in () }
            .merge(with: model.$selectedItem.map { _ in () },
                   model.$spokenMarginsPackageImportReview.map { _ in () },
                   model.$isImportingSpokenMarginsPackage.map { _ in () },
                   model.$spokenMarginsPackageImportError.map { _ in () },
                   model.$sharedSpokenMarginsPackageURL.map { _ in () })
            .sink { [weak self] in self?.scheduleModelChange() }
            .store(in: &modelChangeCancellables)
    }

    private func scheduleModelChange() {
        guard !modelChangePending else { return }
        modelChangePending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.modelChangePending = false
            self.modelDidChange()
        }
    }

    var snapshot: Build23SharingSnapshot {
        let state = model.sharingState
        let margins = state.drafts.map { draft in
            let originalVoiceURL = model.originalAudioURL(forShareDraft: draft.id)
            return Build23SharingMarginSnapshot(
                id: draft.id,
                reviewedText: draft.approvedTranscript,
                representation: draft.representationChoice,
                reviewTokens: reviewTokens(for: draft),
                isIncluded: draft.isIncluded,
                isStarred: draft.interjection.isStarredForSharing == true,
                privateNote: draft.interjection.privateSharingNote?.nilIfEmpty,
                warning: draft.warning,
                preparationMessage: draft.preparationMessage,
                anchorBefore: draft.anchorBefore,
                anchorAfter: draft.anchorAfter,
                canUndo: draft.canUndoEdit,
                canRedo: draft.canRedoEdit,
                canPrepareCleanup: draft.isIncluded
                    && draft.interjection.alignedTranscript != nil
                    && !draft.currentEditState.automaticCleanupEnabled,
                automaticCleanupEnabled: draft.currentEditState.automaticCleanupEnabled,
                isPreparing: draft.isAnalyzingPauses || draft.isPreparingCleanup,
                hasOriginalVoice: originalVoiceURL != nil,
                hasCleanedVoice: draft.cleanedAudioURL != nil,
                originalVoiceURL: originalVoiceURL,
                cleanedVoiceURL: draft.cleanedAudioURL,
                placeholderText: draft.placeholderText,
                isShowingPlaceholder: draft.isShowingPlaceholder
            )
        }
        let hasReviewedSelection = margins.contains {
            $0.isIncluded && !$0.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let previewIsCurrent = verifiedPreview != nil
            && previewFingerprint == currentDraftFingerprint()
            && verifiedPreview.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } == true
        let canAdvance: Bool
        switch stage {
        case .select:
            canAdvance = margins.contains(where: \.isIncluded)
        case .review:
            canAdvance = hasReviewedSelection && !state.isBulkPreparing && !state.isExporting
        case .recipientPreview, .share:
            canAdvance = previewIsCurrent
        }
        return Build23SharingSnapshot(
            stage: stage,
            itemTitle: model.selectedItem.title,
            senderDisplayLabel: state.senderDisplayLabel,
            includesAcousticEvidence: state.includesAcousticEvidence,
            confirmsPrivateSharingRights: state.confirmsPrivateSharingRights,
            transport: currentTransport,
            selectedMarginID: selectedMarginID,
            filter: state.draftFilter,
            margins: margins,
            isPreparingSelection: state.isPreparing,
            isPreparingAll: state.isBulkPreparing,
            preparationCompleted: state.bulkPreparationCompleted,
            preparationTotal: state.bulkPreparationTotal,
            preparationFailures: state.bulkPreparationFailureCount,
            autoCleanSelectedEnabled: state.autoCleanSelectedEnabled,
            needsAutoCleanDecision: state.needsAutoCleanDecision,
            previewState: previewState,
            verifiedPreview: verifiedPreview,
            errorMessage: state.errorMessage,
            canAdvance: canAdvance,
            canShareVerifiedFile: previewIsCurrent
        )
    }

    var recipientSnapshot: Build23RecipientImportSnapshot? {
        guard let review = model.spokenMarginsPackageImportReview else { return nil }
        return Build23RecipientImportSnapshot(
            itemTitle: review.contents.manifest.item.title,
            senderLabel: review.senderLabel,
            marginCount: review.marginCount,
            transport: Self.transport(review.contents.manifest.itemTransport.kind),
            includesEmbeddedItem: review.includesEmbeddedItem,
            requiresRecipientSource: review.requiresRecipientItem,
            isImporting: model.isImportingSpokenMarginsPackage,
            errorMessage: model.spokenMarginsPackageImportError,
            canImport: !review.requiresRecipientItem && !model.isImportingSpokenMarginsPackage,
            isPrivatePodcastSource: SharedEpisodeFeedMatcher.isPrivatePodcastSource(review.contents.manifest),
            mapChapterCount: review.isListeningMap ? review.mapChapterCount : nil,
            replacesExistingMap: review.replacesExistingMap
        )
    }

    /// Reads the feed the recipient pasted and adds the episode this package's Margins belong to.
    func recoverSharedEpisode(feedLink: String) {
        guard let item = model.spokenMarginsPackageImportReview?.contents.manifest.item else { return }
        Task { await episodeRecovery.recover(item, feedLink: feedLink) }
    }

    func chooseRecoveredEpisode(_ candidateID: String) {
        Task { await episodeRecovery.choose(candidateID) }
    }

    var verifiedShareFileURL: URL? {
        snapshot.canShareVerifiedFile ? verifiedPreview?.fileURL : nil
    }

    private func makeImportedLayers(from item: ItemDetailState) -> [Build23ImportedLayerSnapshot] {
        // Paragraph numbers for text positions (#1974); the text is only read as far as the furthest offset.
        let furthestOffset = item.importedCommentaryInterjections.values.joined().compactMap(\.resolution.localStartChar).max()
        let paragraphs = furthestOffset.map { MarginPlaceIndex(chapters: [], text: item.text, readingUpTo: $0) }
        return item.importedCommentaryLayers
            .filter { $0.deletedAt == nil }
            .map { layer in
                let margins = item.importedCommentaryInterjections[layer.id, default: []]
                    .map { margin -> Build23ImportedMarginSnapshot in
                        let placement = SharedMarginPlacementStatus(resolution: margin.resolution, marginId: margin.id,
                            layerStatus: layer.sourceResolutionStatus, pass: item.sharedMarginPlacement,
                            hasPositionEvidence: margin.carriesPositionEvidence(in: layer),
                            awaitingPlacementPass: layer.awaitsPlacementPass)
                        return Build23ImportedMarginSnapshot(
                            id: margin.id,
                            reviewedText: margin.approvedTranscript,
                            resolution: margin.resolution.evidenceClass,
                            positionDescription: placement.positionDescription ?? Self.positionDescription(for: margin.resolution, paragraphs: paragraphs),
                            isPlayable: Gate1AppModel.isPlayableImportedCommentaryResolution(margin.resolution),
                            hasVoice: margin.audioPath != nil,
                            placementLabel: placement.label
                        )
                    }
                return Build23ImportedLayerSnapshot(
                    id: layer.id,
                    senderLabel: layer.displayLabel?.nilIfEmpty ?? "Unsigned sender",
                    itemTitle: layer.itemIdentity.title,
                    integrity: layer.integrityStatus,
                    sourceResolution: layer.sourceResolutionStatus,
                    isEnabled: layer.isEnabled,
                    isMuted: layer.isMuted,
                    revealMode: layer.revealMode ?? layer.suggestedRevealMode ?? .companion,
                    listeningMapProposalCount: layer.listeningMapProposals?.count ?? 0,
                    margins: margins
                )
            }
    }

    func send(_ action: Build23SenderAction) {
        switch action {
        case .begin:
            discardPreview(resetTo: .select)
            if model.sharingState.draftsPreparedForExport && model.isSharingInterjectionsPresented {
                model.sharingState.draftsPreparedForExport = false
            } else {
                model.prepareShareInterjections()
            }
            selectedMarginID = model.sharingState.drafts.first(where: \.isIncluded)?.id
            model.prepareAutomaticallyCleanedShareDraftsIfEnabled()
        case .setFilter(let filter):
            model.sharingState.draftFilter = filter
        case .setSenderDisplayLabel(let label):
            mutatePackage { model.sharingState.senderDisplayLabel = label }
        case .setIncludesAcousticEvidence(let includes):
            mutatePackage { model.sharingState.includesAcousticEvidence = includes }
        case .setPrivateSharingRightsConfirmed(let confirmed):
            mutatePackage { model.sharingState.confirmsPrivateSharingRights = confirmed }
        case .setIncluded(let id, let included):
            mutatePackage { model.setShareDraftIncluded(id, included: included) }
            if included, model.sharingState.autoCleanSelectedEnabled {
                model.prepareAllIncludedShareDrafts()
            }
        case .setVisibleIncluded(let ids, let included):
            mutatePackage { model.setShareDraftsIncluded(ids, included: included) }
            if included, model.sharingState.autoCleanSelectedEnabled {
                model.prepareAllIncludedShareDrafts()
            }
        case .setAutoCleanSelectedEnabled(let enabled):
            mutatePackage { model.setShareAutoCleanSelectedEnabled(enabled) }
        case .selectMargin(let id):
            selectedMarginID = id
        case .setRepresentation(let id, let choice):
            mutatePackage { model.setShareDraftRepresentation(id, choice: choice) }
        case .setAnchorBefore(let id, let text):
            mutatePackage { model.setShareDraftAnchorBefore(id, value: text) }
        case .setAnchorAfter(let id, let text):
            mutatePackage { model.setShareDraftAnchorAfter(id, value: text) }
        case .setReviewedWords(let id, let text):
            // Replaces a word-less voice Margin's placeholder words (#3027); the draft keeps the rule.
            mutatePackage {
                guard let index = model.sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
                model.sharingState.drafts[index].setReviewedWords(text)
            }
        case .prepareCleanup(let id):
            mutatePackage { model.prepareCleanup(forShareDraft: id) }
        case .setCleanupDecision(let draftID, let decisionID, let accepted):
            mutatePackage {
                model.setCleanupDecision(draftID: draftID, decisionID: decisionID, accepted: accepted)
            }
        case .toggleTranscriptWord(let draftID, let segmentID):
            mutatePackage { model.toggleShareDraftWord(draftID: draftID, segmentID: segmentID) }
        case .undo(let id):
            mutatePackage { model.undoShareDraftEdit(id) }
        case .redo(let id):
            mutatePackage { model.redoShareDraftEdit(id) }
        case .restoreOriginal(let id):
            mutatePackage { model.restoreOriginalShareDraft(id) }
        case .prepareAllIncluded:
            mutatePackage { model.prepareAllIncludedShareDrafts() }
        case .cancelPreparation:
            mutatePackage { model.cancelBulkSharePreparation() }
        case .returnToSelect:
            stage = .select
        case .advanceToReview:
            guard snapshot.margins.contains(where: \.isIncluded) else { return }
            stage = .review
            if selectedMarginID == nil {
                selectedMarginID = snapshot.margins.first(where: \.isIncluded)?.id
            }
        case .buildRecipientPreview:
            buildRecipientPreview()
        case .presentSystemShare:
            guard verifiedShareFileURL != nil else { return }
            stage = .share
        case .returnFromSystemShare:
            stage = .review
        case .cancel:
            model.cancelBulkSharePreparation()
            model.isSharingInterjectionsPresented = false
            discardPreview(resetTo: .select)
        }
        objectWillChange.send()
    }

    func send(_ action: Build23RecipientAction) {
        switch action {
        case .requestMissingSource:
            guard let review = model.spokenMarginsPackageImportReview,
                  review.requiresRecipientItem else { return }
            pendingRecipientSourceRequest = Build23RecipientSourceRequest(
                id: review.contents.manifest.packageId,
                packageURL: review.packageURL,
                itemTitle: review.contents.manifest.item.title,
                itemType: review.contents.manifest.item.itemType,
                acceptedSourceKinds: Self.acceptedSourceKinds(for: review.contents.manifest.item.itemType)
            )
        case .dismissSourceRequest:
            pendingRecipientSourceRequest = nil
        case .resumeAfterAddingSource:
            model.refreshSpokenMarginsPackageImportAfterAddingSource()
            if model.spokenMarginsPackageImportReview?.requiresRecipientItem == false {
                pendingRecipientSourceRequest = nil
            }
        case .confirmImport:
            guard recipientSnapshot?.canImport == true else { return }
            model.confirmSpokenMarginsPackageImport()
        case .cancelImport:
            pendingRecipientSourceRequest = nil
            model.cancelSpokenMarginsPackageImport()
        case .setLayerEnabled(let id, let enabled):
            model.setImportedCommentaryLayerEnabled(id, enabled: enabled)
        case .setLayerMuted(let id, let muted):
            model.setImportedCommentaryLayerMuted(id, muted: muted)
        case .setLayerRevealMode(let id, let mode):
            model.setImportedCommentaryRevealMode(id, mode: mode)
        case .listenToMargin(let layerID, let marginID):
            model.listenToImportedCommentary(layerID: layerID, interjectionID: marginID)
        }
        objectWillChange.send()
    }

    private var currentTransport: Build23RecipientTransport {
        let state = model.sharingState
        if state.itemReferenceURL != nil { return .reference }
        if state.canEmbedLinklessItem,
           state.isAppAuthoredItem || state.confirmsPrivateSharingRights {
            return .embeddedText
        }
        return .recipientSupplied
    }

    private func mutatePackage(_ mutation: () -> Void) {
        discardPreview(resetTo: stage == .select ? .select : .review)
        mutation()
    }

    private func discardPreview(resetTo newStage: Build23SharingStage) {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        previewFingerprint = nil
        verifiedPreview = nil
        previewState = .notBuilt
        stage = newStage
    }

    /// The share sheet sent the verified packet (logged as an I4 `share` for its item, #483).
    func recordSystemShareCompleted(packetURL: URL) {
        model.listeningSignals.share(packetURL: packetURL)
    }

    private func buildRecipientPreview() {
        guard stage == .review,
              snapshot.canAdvance else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let fingerprint = currentDraftFingerprint()
        previewTask?.cancel()
        verifiedPreview = nil
        previewFingerprint = nil
        previewState = .building
        stage = .recipientPreview
        model.exportSharedInterjections(presentsReadySheet: false)
        guard let fileURL = model.sharedSpokenMarginsPackageURL,
              model.sharingState.errorMessage == nil else {
            previewState = .failed(model.sharingState.errorMessage ?? "The package could not be built.")
            stage = .review
            return
        }
        previewTask = Task { [weak self] in
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try Self.roundTrippedPreview(fileURL: fileURL)
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.previewGeneration == generation else { return }
                guard self.currentDraftFingerprint() == fingerprint else {
                    self.previewState = .stale
                    self.stage = .review
                    return
                }
                self.previewFingerprint = fingerprint
                self.verifiedPreview = preview
                self.previewState = .ready
                self.model.isSharedSpokenMarginsPackagePresented = false
            } catch {
                guard let self,
                      self.previewGeneration == generation else { return }
                self.previewState = .failed(error.localizedDescription)
                self.stage = .review
            }
        }
    }

    private func modelDidChange() {
        if verifiedPreview != nil,
           previewFingerprint != currentDraftFingerprint() {
            discardPreview(resetTo: .review)
            previewState = .stale
        }
        objectWillChange.send()
    }

    private func currentDraftFingerprint() -> String {
        let state = model.sharingState
        var fields = [
            state.senderDisplayLabel,
            String(state.includesAcousticEvidence),
            state.itemReferenceURL ?? "",
            String(state.isAppAuthoredItem),
            String(state.confirmsPrivateSharingRights)
        ]
        for draft in state.drafts.sorted(by: { $0.id < $1.id }) {
            fields.append(contentsOf: [
                draft.id,
                String(draft.isIncluded),
                draft.approvedTranscript,
                draft.representationChoice.rawValue,
                draft.anchorBefore,
                draft.anchorAfter,
                draft.cleanedAudioURL?.path ?? "",
                String(draft.cleanedAudioDurationMs ?? -1),
                String(draft.renderGeneration),
                draft.cleanup?.decisions.map {
                    "\($0.id):\($0.accepted):\($0.startMs):\($0.endMs)"
                }.joined(separator: ",") ?? "",
                draft.interjection.podcastAnchorEvidence?.map {
                    "\($0.id):\($0.localPath):\($0.provenance?.rawValue ?? "")"
                }.joined(separator: ",") ?? ""
            ])
        }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func reviewTokens(for draft: ShareInterjectionDraft) -> [Build23SharingReviewTokenSnapshot] {
        let words = (draft.interjection.alignedTranscript?.segments ?? []).map { segment in
            Build23SharingReviewTokenSnapshot(
                id: "word:\(segment.id)",
                kind: .word,
                text: segment.text,
                isRemoved: model.isShareDraftWordDeleted(draftID: draft.id, segmentID: segment.id),
                decisionID: nil,
                segmentID: segment.id
            )
        }
        let pauses = (draft.cleanup?.decisions ?? [])
            .filter { $0.kind == .longPause }
            .map { decision in
                let duration = Double(max(0, decision.endMs - decision.startMs)) / 1_000
                return Build23SharingReviewTokenSnapshot(
                    id: "pause:\(decision.id)",
                    kind: .pause,
                    text: String(format: "[%.1fs pause]", duration),
                    isRemoved: decision.accepted,
                    decisionID: decision.id,
                    segmentID: nil
                )
            }
        let starts = Dictionary(uniqueKeysWithValues: (draft.interjection.alignedTranscript?.segments ?? []).map {
            ("word:\($0.id)", $0.startMs)
        } + (draft.cleanup?.decisions ?? []).map {
            ("pause:\($0.id)", $0.startMs)
        })
        return (words + pauses).sorted {
            let lhsStart = starts[$0.id] ?? 0
            let rhsStart = starts[$1.id] ?? 0
            return lhsStart == rhsStart ? $0.id < $1.id : lhsStart < rhsStart
        }
    }

    nonisolated private static func roundTrippedPreview(fileURL: URL) throws -> Build23VerifiedRecipientPreview {
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appending(path: "build-23-recipient-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: extractionDirectory) }
        let verified = try SpokenMarginsPackageArchive.read(
            from: fileURL,
            extractingAssetsTo: extractionDirectory
        )
        guard let contentDigest = verified.manifest.contentDigest else {
            throw SpokenMarginsPackageArchiveError.invalidDigest
        }
        let margins = verified.commentaryLayers.flatMap(\.interjections).map { record in
            let representation = record.defaultRepresentation
            return Build23RecipientPreviewMargin(
                id: record.packageScopedId,
                reviewedText: representation?.approvedTranscript ?? "",
                representation: representation?.kind.rawValue ?? "unavailable",
                positionDescription: positionDescription(for: record.anchor),
                includesVoice: representation?.assetId != nil
            )
        }
        let fileByteCount = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return Build23VerifiedRecipientPreview(
            packageID: verified.manifest.packageId,
            contentDigest: contentDigest,
            fileURL: fileURL,
            fileByteCount: fileByteCount,
            itemTitle: verified.manifest.item.title,
            senderLabel: verified.manifest.senderDisplayLabel?.nilIfEmpty ?? "Unsigned sender",
            transport: transport(verified.manifest.itemTransport.kind),
            margins: margins,
            voiceAssetCount: verified.manifest.assets.filter {
                [SpokenMarginsAssetRole.originalVoice, SpokenMarginsAssetRole.cleanedVoice, SpokenMarginsAssetRole.summaryVoice, SpokenMarginsAssetRole.ttsVoice].contains($0.role)
            }.count,
            acousticEvidenceCount: verified.manifest.assets.filter {
                $0.role == SpokenMarginsAssetRole.acousticSignature
            }.count,
            listeningMapProposalCount: verified.listeningMapProposals.count,
            disclosures: SharingRightsPresentation.disclosures(for: verified)
        )
    }

    nonisolated private static func positionDescription(for anchor: PortableAnchorEvidence) -> String {
        if let mediaTimeMs = anchor.mediaTimeMs {
            let totalSeconds = max(0, mediaTimeMs / 1_000)
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
        if let exactText = anchor.exactText?.nilIfEmpty {
            return "Near “\(String(exactText.prefix(80)))”"
        }
        if let roughPercent = anchor.roughPercent {
            return "About \(roughPercent)% through"
        }
        return "Position will be resolved after import"
    }

    nonisolated private static func positionDescription(for resolution: ImportedAnchorResolution, paragraphs: MarginPlaceIndex? = nil) -> String {
        let paragraph = resolution.localStartChar.flatMap { paragraphs?.paragraph(atChar: $0) }
        return SharedMarginPlacementWording.importSheetLine(for: resolution, paragraph: paragraph)
    }

    nonisolated private static func transport(_ kind: SharedItemTransportKind) -> Build23RecipientTransport {
        switch kind {
        case .reference: return .reference
        case .embeddedText: return .embeddedText
        case .recipientSupplied: return .recipientSupplied
        }
    }

    private static func acceptedSourceKinds(for itemType: SharedItemType) -> [String] {
        switch itemType {
        case .pdf: return ["PDF"]
        case .epub: return ["EPUB"]
        case .podcast: return ["Podcast link", "Audio file"]
        case .text: return ["Pasted text", "Web article", "Text file", "PDF", "EPUB"]
        case .other: return ["Text", "Document", "Audio"]
        }
    }
}
