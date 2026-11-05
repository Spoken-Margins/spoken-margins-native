import Foundation
import SessionKit
import SessionKitAudio

/// A friend's written Margin is heard: a tone, then the iPhone's voice reads "Cole wrote: …" (owner, 2026-11-02, #3365).
/// The reading is rendered to a cached audio file and handed to the same players as a recording, so the tone, the pause
/// of the episode, heard-marking, skip, the reply draft and the episode's return all come from the voice paths. This
/// file is the app's side of that: it names the files, starts the renders off the main thread, waits (bounded, and
/// abandoned when the listener moves on) for a reading that isn't ready, and words what the listener is told when one
/// never is. The rendering is `WrittenMarginReader` (SessionKitAudio); asking it if a reading is ready is an in-memory
/// look-up, so nothing here reads the disk on the main thread.
@MainActor
enum WrittenMarginReadings {
    private static let reader = WrittenMarginReader.shared
    /// How long "Hear only the Margins" holds off for its readings before it starts anyway. The review's own lead-in
    /// gives a reading 20 more seconds, so a miss takes about half a minute of waiting in all.
    static let reviewHold: TimeInterval = 10
    /// Taps and review starts being waited on, so a second tap on the same card doesn't start a second wait.
    private static var waits: [String: Task<Void, Never>] = [:]

    // MARK: Naming and starting the renders

    /// The reading for a shared Margin, or nil when it has a recording to play instead.
    static func reading(for prompt: ImportedCommentaryPrompt) -> WrittenMarginReading? {
        guard prompt.interjection.isWritten else { return nil }
        return WrittenMarginReading(
            intro: WrittenMarginReading.intro(senderName: prompt.layer.displayLabel), text: prompt.interjection.approvedTranscript)
    }

    /// The file for `prompt`'s reading once it is ready (answered from memory), else nil.
    static func readyFile(for prompt: ImportedCommentaryPrompt) -> URL? {
        guard let reading = reading(for: prompt), reader.isReady(reading) else { return nil }
        return reader.fileURL(for: reading)
    }

    /// The files for the written Margins among `entries`, keyed by `marginId`, and the renders started for any that
    /// aren't on disk yet. Touches no disk on the calling thread: the paths come from the words, and the check and the
    /// render run on the reader's own thread.
    static func start(for entries: [SharedMarginReview.Entry]) -> [String: URL] {
        var readings: [String: WrittenMarginReading] = [:]
        for entry in entries { readings[entry.marginId] = entry.writtenReading }
        return reader.start(readings)
    }

    /// Starts the renders for the short written Margins waiting on the item screen, so they are ready before "Hear only
    /// the Margins" is tapped. A long note waits until it is asked for.
    static func prepare(_ entries: [SharedMarginReview.Entry]) {
        let short = entries.filter { $0.writtenReading?.isShortEnoughToRenderAhead == true }
        _ = start(for: short)
    }

    /// What changes which readings the item screen needs: the ids of the written Margins still new.
    static func waitingKey(_ item: ItemDetailState) -> [String] {
        item.importedCommentaryInterjections.values.joined().filter { $0.isNewToListener && $0.isWritten }.map(\.id).sorted()
    }

    // MARK: A tap on a written Margin

    /// Listen on a written Margin whose reading isn't ready: the same path as a voice Margin once it is. Waits in one
    /// task, which gives up with a line when the render does, and does nothing when the listener has moved on (the card
    /// dismissed, another card, another item, a recording started) by the time the reading arrives.
    static func waitThenListen(_ prompt: ImportedCommentaryPrompt, model: Gate1AppModel) {
        guard let reading = reading(for: prompt) else { return }
        guard waits[prompt.id] == nil else { return } // a second tap while the first is waiting
        let wasPending = model.pendingImportedCommentary?.id == prompt.id
        model.reportConfirmation("Getting that Margin ready to read aloud.")
        waits[prompt.id] = Task { @MainActor [weak model] in
            let rendered = (try? await reader.rendered(reading)) != nil
            waits[prompt.id] = nil
            guard !Task.isCancelled, let model, stillWanted(prompt, wasPending: wasPending, model: model) else { return }
            guard rendered else {
                if wasPending { model.dismissPendingImportedCommentary() }
                model.reportWarning("That Margin couldn't be read aloud, so listening continues.")
                return
            }
            model.hangTelemetry.labels.scoped("writtenMarginListen") { model.listenToImportedCommentary(prompt) }
        }
    }

    /// Whether the listener is still where the tap was: the card still up (or, for a Timeline tap, the same item with
    /// nothing else playing and no recording under way), and the episode not changed.
    private static func stillWanted(_ prompt: ImportedCommentaryPrompt, wasPending: Bool, model: Gate1AppModel) -> Bool {
        guard model.selectedItem.id == prompt.layer.itemId, !model.recordingNavigationIsLocked else { return false }
        if wasPending { return model.pendingImportedCommentary?.id == prompt.id }
        return model.pendingImportedCommentary == nil && model.playingImportedCommentary == nil && model.marginMoment == nil
    }

    // MARK: A review

    /// "Hear only the Margins" with a written Margin whose reading isn't ready holds off, for `reviewHold` seconds at
    /// most, then starts anyway, and only if that item is still the open one; a reading still missing then gets the
    /// ordinary warning. True when this took the call (the review starts later, from here).
    static func holdReview(itemId: String, thenContinue: Bool, entries: [SharedMarginReview.Entry], model: Gate1AppModel) -> Bool {
        let key = "review::\(itemId)"
        if releasedReviews.contains(key) { return false } // this is the start after the hold
        if waits[key] != nil { return true } // a second tap while the hold is running
        let readings = entries.compactMap(\.writtenReading)
        guard readings.contains(where: { !reader.isReady($0) }) else { return false }
        let openItem = model.selectedItem.id
        model.reportConfirmation("Getting your new Margins ready.")
        waits[key] = Task { @MainActor [weak model] in
            await reader.waitUntilSettled(readings, upTo: reviewHold)
            waits[key] = nil
            // Only if the listener is still where they were; a miss after the hold gets the ordinary warning.
            guard !Task.isCancelled, let model, model.selectedItem.id == openItem else { return }
            releasedReviews.insert(key)
            model.hangTelemetry.labels.scoped("writtenMarginReview") { model.reviewNewMargins(itemId: itemId, thenContinue: thenContinue, entries: entries) }
            releasedReviews.remove(key)
        }
        return true
    }

    /// Reviews being started after their hold, so the second call doesn't hold again.
    private static var releasedReviews = Set<String>()

    /// The review is starting: any tap still waiting on a reading gives way (nothing plays from it), and the review's
    /// readings are started or found.
    static func startingReview(for entries: [SharedMarginReview.Entry]) -> [String: URL] {
        waits.values.forEach { $0.cancel() }
        waits.removeAll()
        return start(for: entries)
    }

    // MARK: A reading that isn't there when its turn comes

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
}
