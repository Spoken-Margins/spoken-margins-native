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

extension Gate1AppModel {
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
            guard let sessionId = try ItemShareSessionSelection.sessionId(newestFirst: selectedItem.sessionRows.map(\.id), margins: { try requireStore().loadInterjections(sessionId: $0) }) else { return reportFailure("Record at least one Margin on this item before sharing.") }
            exportSessionId = sessionId; prepareExportShareInterjections() // #147: straight to the Share Margins sheet, not the Share/Export screen.
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
            let context = ExcerptCapRule.select(
                before: interjection.anchor.anchorBefore,
                after: interjection.anchor.anchorAfter,
                commentLength: ExcerptCapRule.commentLength(transcript: transcript)
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
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: destination) } // off main (#2510)
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
}
