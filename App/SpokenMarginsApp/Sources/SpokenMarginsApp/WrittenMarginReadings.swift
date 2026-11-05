import Foundation
import SessionKit
import SessionKitAudio

/// A friend's written Margin is heard: a tone, then the iPhone's voice reads "Cole wrote: …" (owner, 2026-11-02, #3365).
/// The reading is rendered to a cached audio file and handed to the same Margin-moment conductor as a recording, so the
/// tone, the pause of the episode, heard-marking, skip and interruptions all come from the voice path. This file is the
/// app's side of that: it names the files, starts the renders off the main thread, and words what the listener is told
/// when a reading isn't ready. The rendering is `WrittenMarginReader` (SessionKitAudio).
@MainActor
enum WrittenMarginReadings {
    private static let reader = WrittenMarginReader.shared
    /// Prompts being waited on, so a second tap on the same card doesn't start a second review.
    private static var starting = Set<String>()

    /// The files for the written Margins among `entries`, keyed by `marginId`, and the renders started for any that
    /// aren't on disk yet. Touches no disk on the calling thread: the paths come from the words, and the check and the
    /// render run on the reader's own queue.
    static func start(for entries: [SharedMarginReview.Entry]) -> [String: URL] {
        var readings: [String: WrittenMarginReading] = [:]
        for entry in entries { readings[entry.marginId] = entry.writtenReading }
        return reader.start(readings)
    }

    /// Starts the renders for the written Margins waiting on the item screen, so they are ready before "Hear only the
    /// Margins" is tapped.
    static func prepare(_ entries: [SharedMarginReview.Entry]) {
        _ = start(for: entries)
    }

    /// What changes which readings the item screen needs: the ids of the written Margins still new.
    static func waitingKey(_ item: ItemDetailState) -> [String] {
        item.importedCommentaryInterjections.values.joined().filter { $0.isNewToListener && $0.isWritten }.map(\.id).sorted()
    }

    /// A reading that isn't ready when its turn comes behaves as a missing recording does: a warning, listening carries
    /// on, and the Margin stays new. The words don't say "recording", which a written Margin never was.
    static func rewordUnavailable(on conductor: MarginMomentConductor?, entries: [SharedMarginReview.Entry], model: Gate1AppModel) {
        let written = Set(entries.filter { $0.interjection.isWritten }.map(\.marginId))
        guard let conductor, !written.isEmpty else { return }
        let previous = conductor.onVoiceUnavailable
        conductor.onVoiceUnavailable = { [weak model] marginId, reason in
            guard written.contains(marginId) else { return previous?(marginId, reason) ?? () }
            model?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            model?.reportWarning("That Margin couldn't be read aloud, so listening continues.")
        }
    }

    /// Listen on a written Margin's card (the tone has already sounded): a review of that one Margin, with no second
    /// tone and no second lead-in, once its reading is on disk. The render runs on the reader's queue; this only waits.
    static func readNow(_ prompt: ImportedCommentaryPrompt, model: Gate1AppModel) {
        guard let itemId = prompt.layer.itemId, let mediaTimeMs = prompt.interjection.resolution.localMediaTimeMs, mediaTimeMs >= 0 else {
            model.dismissPendingImportedCommentary()
            model.reportFailure("This shared Margin has no place in this episode to be read at.")
            return
        }
        let evidence = prompt.interjection.resolution.evidenceClass
        let entry = SharedMarginReview.Entry(
            layer: prompt.layer, interjection: prompt.interjection, mediaTimeMs: mediaTimeMs,
            isApproximate: evidence == .mapInterpolated || evidence == .timestampFallback
        )
        guard let reading = entry.writtenReading, starting.insert(prompt.id).inserted else { return }
        Task { @MainActor [weak model] in
            // A render that fails goes on to the review all the same: the conductor reports it as it does a missing recording.
            _ = try? await reader.rendered(reading)
            starting.remove(prompt.id)
            guard let model else { return }
            model.hangTelemetry.labels.scoped("writtenMarginRead") {
                let returnsSource = model.sharedMarginReturn.promptDismissed()
                model.reviewNewMargins(itemId: itemId, thenContinue: returnsSource, entries: [entry])
                // The card's tone has sounded already, and the Margin is here, so there is no lead-in to wait through.
                model.marginMomentConductor?.chimedMarginIds = []
                model.marginMomentConductor?.playTargetNow()
            }
        }
    }
}
