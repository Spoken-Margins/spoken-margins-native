import Foundation
import SessionKit

/// What one Margin's "Prepare All Included" work reads and writes on its host, the app model (#969).
///
/// The drafts stay where the share sheet and the Build23 preview fingerprint read them (the model's published
/// `sharingState`); each write through `bulkShareDrafts` is one publish, as each write to `sharingState.drafts` was
/// when this work lived on the model.
@MainActor
public protocol BulkShareDraftHost: AnyObject {
    /// The share sheet's drafts.
    var bulkShareDrafts: [ShareInterjectionDraft] { get set }
    /// The drafts a bulk run turned automatic cleanup on for, so turning the switch off can take it off again.
    var bulkAutomaticallyCleanedDraftIDs: Set<String> { get set }
    /// The recording a Margin's audio path names, or `nil` when it is gone.
    func bulkShareAudioURL(forAudioPath path: String) -> URL?
    /// A new, empty place for one cleaned copy, or `nil` when the app's storage can't be reached.
    func bulkShareRevisionFolder() -> URL?
    /// Keeps why a Margin's cleanup failed for a support report. The reason never goes on the screen (#3853).
    func recordBulkShareCleanupFailure(_ reason: String, for interjection: Interjection)
}

/// The pause analysis a bulk run asks for: the quiet runs in a recording, against its aligned words.
public typealias BulkShareSilenceAnalyzer = @Sendable (
    _ sourceURL: URL,
    _ alignedTranscript: AlignedInterjectionTranscript
) throws -> [InterjectionCleanupDecision]

/// The renderer a bulk run asks for: writes the cleaned copy and returns its length in milliseconds.
public typealias BulkShareAudioRenderer = @Sendable (
    _ sourceURL: URL,
    _ destinationURL: URL,
    _ decisions: [InterjectionCleanupDecision]
) async throws -> Int

/// What happens to one Margin in a "Prepare All Included" run, and to the drafts when the run is cancelled or the
/// switch is turned off (#969). `BulkPreparationRun` owns the loop and the run counter; this owns each Margin's steps.
///
/// The stale-work rule, after every await:
/// - the ticket must still be live (`BulkPreparationTicket.isLive`), else the result is dropped;
/// - a cleaned copy also needs its draft's `renderGeneration` unchanged since the render began, else the copy is
///   deleted, because no draft will ever point at it;
/// - the pause analysis runs detached and can't be cancelled, so a stale result is simply not applied.
@MainActor
public struct BulkShareDraftPreparation {
    public let analyze: BulkShareSilenceAnalyzer
    public let render: BulkShareAudioRenderer
    /// Deletes a stale render's cleaned copy. The default does it off the main actor (#2510).
    public let discardStaleCopy: @Sendable (URL) -> Void

    public init(
        analyze: @escaping BulkShareSilenceAnalyzer,
        render: @escaping BulkShareAudioRenderer,
        discardStaleCopy: @escaping @Sendable (URL) -> Void = { url in
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
        }
    ) {
        self.analyze = analyze
        self.render = render
        self.discardStaleCopy = discardStaleCopy
    }

    /// A Margin a bulk run takes: included, with aligned words, and not already cleaned automatically.
    public static func isEligible(_ draft: ShareInterjectionDraft) -> Bool {
        draft.isIncluded
            && draft.interjection.alignedTranscript != nil
            && !draft.currentEditState.automaticCleanupEnabled
    }

    /// Prepares one Margin: turns automatic cleanup on, analyses its pauses, and renders the cleaned copy.
    /// Returns whether it got the cleaned copy with nothing missing (`false`: it fell back, or the work went stale).
    public func prepare(
        _ id: String,
        ticket: BulkPreparationTicket,
        host: any BulkShareDraftHost
    ) async -> Bool {
        guard let initialIndex = host.bulkShareDrafts.firstIndex(where: { $0.id == id }),
              let aligned = host.bulkShareDrafts[initialIndex].interjection.alignedTranscript else {
            return false
        }
        host.bulkShareDrafts[initialIndex].preparationMessage = nil
        Self.recordEdit(for: id, host: host) { $0.automaticCleanupEnabled = true }
        host.bulkAutomaticallyCleanedDraftIDs.insert(id)

        guard let analysisIndex = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let audioPath = host.bulkShareDrafts[analysisIndex].interjection.audioPath
        let sourceURL = audioPath.flatMap(host.bulkShareAudioURL(forAudioPath:))
        var analysisFailure: ShareCleanupWords.Failure?
        if let sourceURL {
            host.bulkShareDrafts[analysisIndex].isAnalyzingPauses = true
            let analyzer = analyze
            let analysis = await Task.detached {
                do {
                    return (try analyzer(sourceURL, aligned), nil as String?)
                } catch {
                    return ([], SafeErrorText.describe(error))
                }
            }.value
            guard ticket.isLive,
                  let current = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
                return false
            }
            host.bulkShareDrafts[current].isAnalyzingPauses = false
            host.bulkShareDrafts[current].acousticPauseDecisions = analysis.0
            if let reason = analysis.1 {
                analysisFailure = .pauseAnalysisUnavailable
                host.recordBulkShareCleanupFailure("pause_analysis:\(reason)", for: host.bulkShareDrafts[current].interjection)
            }
            Self.applyEditState(at: current, host: host)
        } else if audioPath != nil {
            analysisFailure = .recordingMissing
        }

        guard ticket.isLive else { return false }
        let rendered = await renderCleanup(forDraft: id, ticket: ticket, host: host)
        guard ticket.isCurrent,
              let finalIndex = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let analysisFailure {
            let analysisMessage = analysisFailure.message
            // A missing recording is said once, never wrapped in the pause line.
            if analysisFailure != .recordingMissing, let renderMessage = host.bulkShareDrafts[finalIndex].preparationMessage {
                host.bulkShareDrafts[finalIndex].preparationMessage = "\(renderMessage) \(analysisMessage)"
            } else {
                host.bulkShareDrafts[finalIndex].preparationMessage = analysisMessage
            }
        }
        return rendered && analysisFailure == nil
    }

    private func renderCleanup(
        forDraft id: String,
        ticket: BulkPreparationTicket,
        host: any BulkShareDraftHost
    ) async -> Bool {
        guard let index = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard let decisions = host.bulkShareDrafts[index].cleanup?.decisions else {
            return true
        }
        guard let sourcePath = host.bulkShareDrafts[index].interjection.audioPath,
              let sourceURL = host.bulkShareAudioURL(forAudioPath: sourcePath) else {
            host.bulkShareDrafts[index].representationChoice = .textOnly
            host.bulkShareDrafts[index].preparationMessage = ShareCleanupWords.Failure.recordingMissing.message
            return false
        }
        guard let folder = host.bulkShareRevisionFolder() else {
            host.bulkShareDrafts[index].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
            host.recordBulkShareCleanupFailure("render_storage_unavailable", for: host.bulkShareDrafts[index].interjection)
            return false
        }
        host.bulkShareDrafts[index].renderGeneration += 1
        let renderGeneration = host.bulkShareDrafts[index].renderGeneration
        host.bulkShareDrafts[index].isPreparingCleanup = true
        let destination = folder.appendingPathComponent("cleaned-\(PodcastAnchorEvidencePaths.safeComponent(id)).m4a")
        let renderer = render
        let result: (duration: Int?, failure: String?)
        do {
            result = (try await renderer(sourceURL, destination, decisions), nil)
        } catch {
            result = (nil, SafeErrorText.describe(error))
        }
        guard ticket.isLive,
              let current = host.bulkShareDrafts.firstIndex(where: { $0.id == id }),
              host.bulkShareDrafts[current].renderGeneration == renderGeneration else {
            discardStaleCopy(destination)
            return false
        }
        host.bulkShareDrafts[current].isPreparingCleanup = false
        if let duration = result.duration {
            host.bulkShareDrafts[current].cleanedAudioURL = destination
            host.bulkShareDrafts[current].cleanedAudioDurationMs = duration
            host.bulkShareDrafts[current].representationChoice = .cleaned
            return true
        }
        host.bulkShareDrafts[current].cleanedAudioURL = nil
        host.bulkShareDrafts[current].cleanedAudioDurationMs = nil
        host.bulkShareDrafts[current].representationChoice =
            Self.hasOriginalAudio(host.bulkShareDrafts[current], host: host) ? .original : .textOnly
        host.bulkShareDrafts[current].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
        host.recordBulkShareCleanupFailure("render:\(result.failure ?? "unknown")", for: host.bulkShareDrafts[current].interjection)
        return false
    }

    /// The Cancel button, after the run is invalidated: every draft stops showing work, and a draft whose work was in
    /// flight gets its automatic cleanup taken back, so it is eligible again. Every draft, on purpose: a manual
    /// cleanup in flight is rolled back too (characterised on #969, 2026-10-12).
    public static func rollBackInFlightDrafts(host: any BulkShareDraftHost) {
        for index in host.bulkShareDrafts.indices {
            let wasInFlight = host.bulkShareDrafts[index].isAnalyzingPauses
                || host.bulkShareDrafts[index].isPreparingCleanup
            host.bulkShareDrafts[index].isAnalyzingPauses = false
            host.bulkShareDrafts[index].isPreparingCleanup = false
            if wasInFlight,
               host.bulkShareDrafts[index].currentEditState.automaticCleanupEnabled,
               host.bulkShareDrafts[index].canUndoEdit {
                let hasOriginalAudio = hasOriginalAudio(host.bulkShareDrafts[index], host: host)
                _ = host.bulkShareDrafts[index].undoEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false)
            }
        }
    }

    /// The switch turned off: each draft a bulk run cleaned gets automatic cleanup taken off, as a new edit the
    /// sender can undo.
    public static func undoAutomaticCleanup(host: any BulkShareDraftHost) {
        let draftIDs = host.bulkAutomaticallyCleanedDraftIDs
        for id in draftIDs {
            recordEdit(for: id, host: host) { $0.disableAutomaticCleanup() }
        }
        host.bulkAutomaticallyCleanedDraftIDs.removeAll()
    }

    // MARK: Edits without a render

    // A bulk run never asks a draft to render on its own (`renderCleanedAudio: false`): with that, `recordEdit` and
    // `applyEditState` always return `false`, so there is no render request to pass back to the host.

    private static func recordEdit(
        for id: String,
        host: any BulkShareDraftHost,
        mutate: (inout ShareMarginEditState) -> Void
    ) {
        guard let index = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = hasOriginalAudio(host.bulkShareDrafts[index], host: host)
        _ = host.bulkShareDrafts[index].recordEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false, mutate: mutate)
    }

    private static func applyEditState(at index: Int, host: any BulkShareDraftHost) {
        guard host.bulkShareDrafts.indices.contains(index) else { return }
        let hasOriginalAudio = hasOriginalAudio(host.bulkShareDrafts[index], host: host)
        _ = host.bulkShareDrafts[index].applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false)
    }

    private static func hasOriginalAudio(_ draft: ShareInterjectionDraft, host: any BulkShareDraftHost) -> Bool {
        draft.interjection.audioPath.flatMap(host.bulkShareAudioURL(forAudioPath:)) != nil
    }
}
