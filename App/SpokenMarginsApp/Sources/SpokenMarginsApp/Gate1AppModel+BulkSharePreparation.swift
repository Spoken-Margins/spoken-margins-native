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
    /// "Prepare All Included" (#969): the run and its stale-work rule live in `BulkPreparationRun`; what happens to one
    /// Margin, and the state the sheet shows, stay here. The counters are on `sharingState` because the sheet and the
    /// Build23 preview fingerprint read them there.
    var bulkSharePreparationEligibleCount: Int {
        sharingState.drafts.filter(isEligibleForBulkSharePreparation).count
    }

    func prepareAllIncludedShareDrafts() {
        guard !sharingState.isBulkPreparing else { return }
        let draftIDs = sharingState.drafts
            .filter(isEligibleForBulkSharePreparation)
            .map(\.id)
        guard !draftIDs.isEmpty else { return }

        sharingState.isBulkPreparing = true
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = draftIDs.count
        sharingState.bulkPreparationFailureCount = 0
        sharingState.errorMessage = nil
        diagnostics["bulkSharePreparation"] = "started:total=\(draftIDs.count)"

        bulkSharePreparation.start(ids: draftIDs, host: self)
    }

    func cancelBulkSharePreparation() {
        guard sharingState.isBulkPreparing || bulkSharePreparation.hasTask else { return }
        bulkSharePreparation.invalidateAndCancel()
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

    fileprivate func prepareShareDraftForBulk(
        _ id: String,
        ticket: BulkPreparationTicket
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
        var analysisFailure: ShareCleanupWords.Failure?
        if let sourceURL {
            sharingState.drafts[analysisIndex].isAnalyzingPauses = true
            let analyzer = shareMarginSilenceAnalysisHandler
            let analysis = await Task.detached {
                do {
                    return (try analyzer(sourceURL, aligned), nil as String?)
                } catch {
                    return ([], SafeErrorText.describe(error))
                }
            }.value
            guard ticket.isLive,
                  let current = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
                return false
            }
            sharingState.drafts[current].isAnalyzingPauses = false
            sharingState.drafts[current].acousticPauseDecisions = analysis.0
            if let reason = analysis.1 {
                analysisFailure = .pauseAnalysisUnavailable
                // The reason is for a support report, not the screen (#3853).
                diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", sharingState.drafts[current].interjection)] = "pause_analysis:\(reason)"
            }
            applyShareEditState(at: current, renderCleanedAudio: false)
        } else if audioPath != nil {
            analysisFailure = .recordingMissing
        }

        guard ticket.isLive else { return false }
        let rendered = await renderBulkCleanup(forShareDraft: id, ticket: ticket)
        guard ticket.isCurrent,
              let finalIndex = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let analysisFailure {
            let analysisMessage = analysisFailure.message
            // A missing recording is said once, never wrapped in the pause line.
            if analysisFailure != .recordingMissing, let renderMessage = sharingState.drafts[finalIndex].preparationMessage {
                sharingState.drafts[finalIndex].preparationMessage = "\(renderMessage) \(analysisMessage)"
            } else {
                sharingState.drafts[finalIndex].preparationMessage = analysisMessage
            }
        }
        return rendered && analysisFailure == nil
    }

    private func renderBulkCleanup(
        forShareDraft id: String,
        ticket: BulkPreparationTicket
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
                ShareCleanupWords.Failure.recordingMissing.message
            return false
        }
        guard let root = try? applicationSupportDirectory()
            .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            sharingState.drafts[index].preparationMessage =
                ShareCleanupWords.Failure.voiceNotPrepared.message
            diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", sharingState.drafts[index].interjection)] = "render_storage_unavailable"
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
            result = (nil, SafeErrorText.describe(error))
        }
        guard ticket.isLive,
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
        sharingState.drafts[current].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
        diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", sharingState.drafts[current].interjection)] = "render:\(result.failure ?? "unknown")"
        return false
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
}

/// The model is the bulk run's host (#969). The run holds it weakly until a run starts and strongly for the length of
/// one run, as the model's own task did before, so a model can't be released under a Margin that is being prepared.
extension Gate1AppModel: BulkPreparationHost {
    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> Bool {
        await prepareShareDraftForBulk(itemID, ticket: ticket)
    }

    func bulkRunDidFinishOne(prepared: Bool) {
        sharingState.bulkPreparationCompleted += 1
        if !prepared {
            sharingState.bulkPreparationFailureCount += 1
        }
    }

    func bulkRunDidComplete() {
        sharingState.isBulkPreparing = false
        diagnostics["bulkSharePreparation"] = [
            "complete",
            "prepared=\(sharingState.bulkPreparationCompleted)",
            "fallbacks=\(sharingState.bulkPreparationFailureCount)"
        ].joined(separator: ";")
    }
}
