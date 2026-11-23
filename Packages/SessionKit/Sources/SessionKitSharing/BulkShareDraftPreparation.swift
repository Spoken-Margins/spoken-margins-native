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

    /// Whether a Margin's work in the run should stop: it was switched out, or the sender picked As recorded or Words
    /// only (#4647). Its result is not written and it is neither finished nor failed.
    public static func leftTheRun(_ draft: ShareInterjectionDraft) -> Bool {
        !draft.isIncluded || draft.optedOutOfCleanedVoice
    }

    // MARK: Words first (#4647)

    /// The text step: turns automatic cleanup on for one Margin with no render, so its cleaned words show at once. The
    /// voice is made later by the run. Does nothing for a Margin with no word timing or with cleanup already on.
    /// Returns whether it changed the Margin.
    @discardableResult
    public static func applyTextStep(for id: String, host: any BulkShareDraftHost) -> Bool {
        guard let index = host.bulkShareDrafts.firstIndex(where: { $0.id == id }),
              host.bulkShareDrafts[index].interjection.alignedTranscript != nil,
              !host.bulkShareDrafts[index].currentEditState.automaticCleanupEnabled else { return false }
        host.bulkShareDrafts[index].preparationMessage = nil
        recordEdit(for: id, host: host) { $0.automaticCleanupEnabled = true }
        return true
    }

    /// The switch turned on, or the list opened with it stored on: every eligible Margin gets its cleaned words at once,
    /// including one set to As recorded or Words only, and is remembered as cleaned by the switch. Returns, in list
    /// order, the ones whose voice should be made: all of those but the ones the sender set to As recorded or Words only.
    public static func startPass(host: any BulkShareDraftHost) -> [String] {
        let eligible = host.bulkShareDrafts.filter(isEligible).map(\.id)
        var voices: [String] = []
        for id in eligible {
            applyTextStep(for: id, host: host)
            host.bulkAutomaticallyCleanedDraftIDs.insert(id)
            if let draft = host.bulkShareDrafts.first(where: { $0.id == id }), !draft.optedOutOfCleanedVoice {
                voices.append(id)
            }
        }
        return voices
    }

    /// One Margin switched in, or whose words arrived, with the switch on: only that Margin gets its cleaned words and,
    /// unless the sender opted out, joins the run. Other Margins are never swept up. Returns whether its voice should be
    /// made.
    public static func includePass(id: String, host: any BulkShareDraftHost) -> Bool {
        guard let draft = host.bulkShareDrafts.first(where: { $0.id == id }), draft.isIncluded,
              draft.interjection.alignedTranscript != nil else { return false }
        if applyTextStep(for: id, host: host) {
            host.bulkAutomaticallyCleanedDraftIDs.insert(id)
        }
        guard let current = host.bulkShareDrafts.first(where: { $0.id == id }) else { return false }
        return !current.optedOutOfCleanedVoice && !(current.currentEditState.automaticCleanupEnabled && current.cleanedAudioURL != nil)
    }

    /// Whether asking for a Margin's voice should queue it (#4647): not when it is already queued or in progress, and
    /// not when its automatic cleanup is on and its voice without ums is already made.
    public static func needsVoice(_ id: String, pending: Set<String>, host: any BulkShareDraftHost) -> Bool {
        guard !pending.contains(id), let draft = host.bulkShareDrafts.first(where: { $0.id == id }) else { return false }
        return !(draft.currentEditState.automaticCleanupEnabled && draft.cleanedAudioURL != nil)
    }

    /// Prepares one Margin's voice: analyses its pauses and renders the cleaned copy, from the words as they are when its
    /// turn comes. Its words were cleaned when it was queued (`applyTextStep`), never here, so an "Undo all edits" made
    /// while it waited is not redone.
    ///
    /// - `.skipped`: it left the run (`leftTheRun`) before its turn's work began or before a result was written.
    /// - `.requeued`: a hand edit changed its words while the render was out, so the copy is stale; it goes again.
    /// - `.prepared` / `.fellBack`: it got the cleaned copy with nothing missing, or fell back.
    public func prepare(
        _ id: String,
        ticket: BulkPreparationTicket,
        host: any BulkShareDraftHost
    ) async -> BulkPreparationOutcome {
        guard let initialIndex = host.bulkShareDrafts.firstIndex(where: { $0.id == id }),
              let aligned = host.bulkShareDrafts[initialIndex].interjection.alignedTranscript else {
            return .fellBack
        }
        guard !Self.leftTheRun(host.bulkShareDrafts[initialIndex]) else { return .skipped }
        host.bulkShareDrafts[initialIndex].preparationMessage = nil

        let audioPath = host.bulkShareDrafts[initialIndex].interjection.audioPath
        let sourceURL = audioPath.flatMap(host.bulkShareAudioURL(forAudioPath:))
        var analysisFailure: ShareCleanupWords.Failure?
        if let sourceURL {
            host.bulkShareDrafts[initialIndex].isAnalyzingPauses = true
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
                return .fellBack
            }
            host.bulkShareDrafts[current].isAnalyzingPauses = false
            guard !Self.leftTheRun(host.bulkShareDrafts[current]) else { return .skipped }
            host.bulkShareDrafts[current].acousticPauseDecisions = analysis.0
            if let reason = analysis.1 {
                analysisFailure = .pauseAnalysisUnavailable
                host.recordBulkShareCleanupFailure("pause_analysis:\(reason)", for: host.bulkShareDrafts[current].interjection)
            }
            Self.applyEditState(at: current, host: host)
        } else if audioPath != nil {
            analysisFailure = .recordingMissing
        }

        guard ticket.isLive else { return .fellBack }
        let rendered = await renderCleanup(forDraft: id, ticket: ticket, host: host)
        switch rendered {
        case .skipped: return .skipped
        case .requeued: return .requeued
        case .done, .failed: break
        }
        guard ticket.isCurrent,
              let finalIndex = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            return .fellBack
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
        return rendered == .done && analysisFailure == nil ? .prepared : .fellBack
    }

    private enum RenderResult { case done, failed, skipped, requeued }

    private func renderCleanup(
        forDraft id: String,
        ticket: BulkPreparationTicket,
        host: any BulkShareDraftHost
    ) async -> RenderResult {
        guard let index = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            return .failed
        }
        guard let decisions = host.bulkShareDrafts[index].cleanup?.decisions else {
            return .done
        }
        guard let sourcePath = host.bulkShareDrafts[index].interjection.audioPath,
              let sourceURL = host.bulkShareAudioURL(forAudioPath: sourcePath) else {
            host.bulkShareDrafts[index].representationChoice = .textOnly
            host.bulkShareDrafts[index].preparationMessage = ShareCleanupWords.Failure.recordingMissing.message
            return .failed
        }
        guard let folder = host.bulkShareRevisionFolder() else {
            host.bulkShareDrafts[index].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
            host.recordBulkShareCleanupFailure("render_storage_unavailable", for: host.bulkShareDrafts[index].interjection)
            return .failed
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
              let current = host.bulkShareDrafts.firstIndex(where: { $0.id == id }) else {
            discardStaleCopy(destination)
            return .failed
        }
        guard host.bulkShareDrafts[current].renderGeneration == renderGeneration else {
            // The words changed while the copy was made (a hand edit, or Undo all edits): the copy is for words that
            // no longer go. It is deleted, and the Margin goes again with its words as they are now (#4647).
            discardStaleCopy(destination)
            host.bulkShareDrafts[current].isPreparingCleanup = false
            return .requeued
        }
        host.bulkShareDrafts[current].isPreparingCleanup = false
        let draft = host.bulkShareDrafts[current]
        if let duration = result.duration {
            host.bulkShareDrafts[current].cleanedAudioURL = destination
            host.bulkShareDrafts[current].cleanedAudioDurationMs = duration
            // A sender's pick holds (#4647): the copy goes when they picked nothing or picked Without ums, even for a
            // Margin switched out meanwhile, so switching it back in sends the voice its cleaned words describe. A left-out
            // Margin's version is never read (the packet and the fingerprint take only included Margins), and it is
            // not counted as done.
            let now = host.bulkShareDrafts[current]
            if !now.optedOutOfCleanedVoice {
                host.bulkShareDrafts[current].representationChoice = .cleaned
            }
            guard !Self.leftTheRun(now) else { return .skipped }
            return .done
        }
        host.bulkShareDrafts[current].cleanedAudioURL = nil
        host.bulkShareDrafts[current].cleanedAudioDurationMs = nil
        let keepsWordsOnly = draft.representationChoice == .textOnly || draft.senderPickedVersion == .textOnly
        host.bulkShareDrafts[current].representationChoice =
            keepsWordsOnly || !Self.hasOriginalAudio(draft, host: host) ? .textOnly : .original
        if host.bulkShareDrafts[current].senderPickedVersion == .cleaned {
            host.bulkShareDrafts[current].senderPickedVersion = nil
        }
        guard !Self.leftTheRun(draft) else { return .skipped }
        host.bulkShareDrafts[current].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
        host.recordBulkShareCleanupFailure("render:\(result.failure ?? "unknown")", for: host.bulkShareDrafts[current].interjection)
        return .failed
    }

    /// The Cancel button, after the run is invalidated: every draft stops showing work, and a draft whose work was in
    /// flight, or that was still queued (`pending`, #4647), gets its automatic cleanup taken back (words back as
    /// recorded), so it is eligible again. Every draft in flight, on purpose: a manual cleanup in flight is rolled back too
    /// (characterised on #969, 2026-10-12). Margins already finished keep theirs.
    public static func rollBackInFlightDrafts(host: any BulkShareDraftHost, pending: Set<String> = []) {
        for index in host.bulkShareDrafts.indices {
            let wasInFlight = host.bulkShareDrafts[index].isAnalyzingPauses
                || host.bulkShareDrafts[index].isPreparingCleanup
                || pending.contains(host.bulkShareDrafts[index].id)
            host.bulkShareDrafts[index].isAnalyzingPauses = false
            host.bulkShareDrafts[index].isPreparingCleanup = false
            guard wasInFlight, host.bulkShareDrafts[index].currentEditState.automaticCleanupEnabled else { continue }
            let hasOriginalAudio = hasOriginalAudio(host.bulkShareDrafts[index], host: host)
            var withoutAutomatic = host.bulkShareDrafts[index].currentEditState
            withoutAutomatic.disableAutomaticCleanup()
            let history = host.bulkShareDrafts[index].editHistory
            let position = host.bulkShareDrafts[index].editHistoryIndex
            if position > 0, history[position - 1] == withoutAutomatic {
                // The last edit was the automatic one: take it back as an undo, so redo still has it.
                _ = host.bulkShareDrafts[index].undoEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false)
            } else {
                // Edits came after it: take only the automatic part off, as a new edit, and keep the sender's own.
                _ = host.bulkShareDrafts[index].recordEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: false) {
                    $0.disableAutomaticCleanup()
                }
            }
            host.bulkAutomaticallyCleanedDraftIDs.remove(host.bulkShareDrafts[index].id)
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
