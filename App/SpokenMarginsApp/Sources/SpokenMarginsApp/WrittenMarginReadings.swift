import Foundation
import SessionKit
import SessionKitAudio
#if canImport(UIKit)
import UIKit
#endif

/// A friend's written Margin is heard: a tone, then the iPhone's voice reads "Cole wrote: …" (owner, 2026-11-02, #3365).
/// The reading is rendered to a cached audio file and handed to the same players as a recording, so the tone, the pause
/// of the episode, heard-marking, skip, the reply draft and the episode's return all come from the voice paths. This
/// file is the app's side of that: it names the files, starts the renders off the main thread, waits (bounded, and
/// abandoned when the listener moves on) for a reading that isn't ready, and words what the listener is told when one
/// never is. The rendering is `WrittenMarginReader` (SessionKitAudio); asking it if a reading is ready is an in-memory
/// look-up, so nothing here reads the disk on the main thread.
@MainActor
enum WrittenMarginReadings {
    // MARK: Which voice reads (#3391)

    private static weak var model: Gate1AppModel?
    private static let termsTextIsBundled = SpokenMarginsTerms.hasBundledText()

    /// Called whenever the app builds its audio clients, so the reading follows the Terms and the voice chosen in Settings
    /// as they are now. Until then, and whenever the choice says so, the iPhone voice reads.
    static func bind(to model: Gate1AppModel) { Self.model = model }

    /// The one reader, for every voice: its lane, its on-device runner (one model at a time, whichever voice) and its
    /// deletion of a removed item's readings are shared, so a permanent delete reaches every render (#3391).
    private static var reader: WrittenMarginReader { .shared }

    /// The listener's chosen on-device voice for a Margin they are about to hear, or nil when the iPhone voice reads
    /// (`WrittenMarginVoiceChoice`). Asked on every use, so a Terms acceptance or a change of voice applies to the next
    /// reading. Only in-memory facts are read here; nothing touches the disk or the model.
    ///
    /// Only what is played asks with this. `prepare`, which runs when a screen opens, never does: opening a screen must
    /// not run the on-device model, so it renders ahead in the iPhone voice, which costs the listener no battery, heat or
    /// stutter worth noticing (owner rule: default on only when it costs the listener nothing, 2026-10-05). The stage
    /// carries whether the app is in front, read here as a fact: when it is not, nobody can wait, so what exists plays
    /// at once and the on-device voice is not run (`WrittenMarginOnDeviceStage.listenerCanWait`).
    private static var stage: WrittenMarginOnDeviceStage? {
        guard let model else { return nil }
        let selection = model.ttsVoiceSelection
        let choice = WrittenMarginVoiceChoice.choose(
            termsAccepted: model.hasAcceptedCurrentTerms && termsTextIsBundled,
            candidate: WrittenMarginOnDeviceRendering.candidate(for: selection, model: model)
        )
        guard case .onDevice(let key) = choice else { return nil }
        return WrittenMarginOnDeviceRendering.stage(for: selection, key: key, listenerCanWait: appIsInFront, model: model)
    }

    private static var appIsInFront: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// How long "Skip to the Margins" holds off for its readings before it starts anyway. The review's own lead-in
    /// gives a reading 20 more seconds, so a miss takes about half a minute of waiting in all.
    static let reviewHold: TimeInterval = 10

    // MARK: Naming and starting the renders

    /// The reading for a shared Margin, or nil when it has a recording to play instead.
    static func reading(for prompt: ImportedCommentaryPrompt) -> WrittenMarginReading? {
        WrittenMarginReading.of(prompt.interjection, in: prompt.layer)
    }

    /// What a friend's Margin sounds like on this iPhone: the one answer every way of playing one asks for (#3412).
    /// A lookup in memory, so the main thread may ask. It starts no render: `startingRender` does, for what is played.
    static func audio(for margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, voiceFile: (String) -> URL?) -> SharedMarginAudio {
        SharedMarginAudio.resolve(margin, in: layer, voiceFile: voiceFile, reader: reader, onDevice: stage)
    }

    /// The file to hand a player for `audio`, after starting the render of a reading that isn't ready. Nil: nothing can play.
    static func startingRender(_ audio: SharedMarginAudio) -> URL? { audio.startingRender(on: reader, onDevice: stage) }

    /// Starts the iPhone voice's renders for the short written Margins waiting on the item screen, whichever voice is
    /// chosen: they play at once when the app is not in front and are the fallback of a slow on-device try. A long note
    /// waits until it is asked for. Opening a screen never runs the on-device model, and a reading made here is not the
    /// first hearing of an on-device listener (`WrittenMarginReader.prepareAhead`). Touches no disk on the main thread.
    static func prepare(_ entries: [SharedMarginReview.Entry]) {
        var readings: [String: WrittenMarginReading] = [:]
        for entry in entries { if let reading = entry.writtenReading, reading.isShortEnoughToRenderAhead { readings[entry.marginId] = reading } }
        reader.prepareAhead(readings)
    }

    /// What changes which readings the item screen needs: the ids of the written Margins still new.
    static func waitingKey(_ item: ItemDetailState) -> [String] {
        item.importedCommentaryInterjections.values.joined().filter { $0.isNewToListener && $0.readsAloud }.map(\.id).sorted()
    }

    // MARK: A tap on a written Margin

    /// A wait for a reading: its own id, so a finished wait never clears a newer one for the same Margin.
    private struct Wait {
        let id: UUID
        let wasPending: Bool
        let task: Task<Void, Never>
        let itemId: String?
        let reading: WrittenMarginReading
    }
    private static var tapWaits: [String: Wait] = [:]
    private static var holds: [String: Task<Void, Never>] = [:]

    /// Listen on a written Margin whose reading isn't ready: the same path as a voice Margin once it is. Waits in one
    /// task, which gives up with a line when the render does, and does nothing when the listener has moved on (the card
    /// dismissed, another card, another item, a recording started) by the time the reading arrives. The card's own
    /// expiry is stopped for the wait, so a tone-only card cannot run out while the reading is being made.
    static func waitThenListen(_ prompt: ImportedCommentaryPrompt, model: Gate1AppModel) {
        guard let reading = reading(for: prompt) else { return }
        let wasPending = model.pendingImportedCommentary?.id == prompt.id
        if let running = tapWaits[prompt.id] {
            if running.wasPending == wasPending { return } // a second tap on the same card, or the same Timeline row
            running.task.cancel() // a card tap after a dismiss, or the other way round: the newest tap is the one that counts
        }
        model.importedCommentaryAutoPlayTask?.cancel()
        model.importedCommentaryAutoPlayTask = nil
        model.reportConfirmation("Getting that Margin ready to read aloud.")
        let id = UUID()
        let wait = askReaderNow(reading) // asked here, not from the task below (#3619's T3)
        let task = Task { @MainActor [weak model] in
            let rendered = await wait()
            if tapWaits[prompt.id]?.id == id { tapWaits[prompt.id] = nil }
            guard !Task.isCancelled, let model else { return }
            guard model.selectedItem.id == prompt.layer.itemId, !model.recordingNavigationIsLocked else { return } // the listener left
            if wasPending, model.pendingImportedCommentary?.id != prompt.id { return } // the card was dismissed or replaced
            guard rendered else {
                if wasPending { model.dismissPendingImportedCommentary() }
                model.reportWarning("That Margin couldn't be read aloud, so listening continues.")
                return
            }
            if !wasPending, model.pendingImportedCommentary != nil || model.playingImportedCommentary != nil || model.marginMoment != nil {
                // Something else took the sound while the reading was made; the tap is not dropped without a word.
                model.reportWarning("That Margin is ready now. Tap it again to hear it.")
                return
            }
            model.hangTelemetry.labels.scoped("writtenMarginListen") { model.listenToImportedCommentary(prompt) }
        }
        tapWaits[prompt.id] = Wait(id: id, wasPending: wasPending, task: task, itemId: prompt.layer.itemId, reading: reading)
    }

    /// Asks the reader for `reading` now, before this returns, so it is counted as waited on from the caller's next line
    /// (a tap that asks from a task of its own leaves a moment with nobody waiting, #3619's T3). The returned wait gives
    /// whether the reading was made, and stops waiting if the task awaiting it is cancelled: the listener left or tapped
    /// again, and an on-device try nobody else waits for stops (#3391).
    private static func askReaderNow(_ reading: WrittenMarginReading) -> @Sendable () async -> Bool {
        let (answer, give) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let stopWaiting = reader.requestRender(reading, onDevice: stage) { result in
            give.yield((try? result.get()) != nil)
            give.finish()
        }
        return {
            await withTaskCancellationHandler {
                var answered = false
                for await value in answer { answered = value }
                return answered
            } onCancel: { stopWaiting() }
        }
    }

    // MARK: A review

    /// A tap on a Timeline row, for a Margin whose reading in the chosen voice isn't made yet: it waits for that reading (the
    /// on-device voice, within its short budget, else the iPhone voice, never silence), then plays the moment as an
    /// ordinary tap does. True when this took the tap. Never twice for one wait: after the wait the moment is played from
    /// whatever file there is, so a reading that can't be made can't send the tap round again.
    static func waitsThenPlays(_ audio: SharedMarginAudio, row: SharedMarginRow, model: Gate1AppModel) -> Bool {
        let key = row.interjection.id
        guard case .readingRendering(let reading, _) = audio, !replayingAfterWait.contains(key),
              reader.wantsOnDevice(reading, stage: stage) else { return false } // the iPhone voice's moment starts at once, as it always did
        if tapWaits[key] != nil { return true } // a second tap during the wait
        model.reportConfirmation("Getting that Margin ready to read aloud.")
        let id = UUID()
        let wait = askReaderNow(reading)
        let task = Task { @MainActor [weak model] in
            let rendered = await wait()
            if tapWaits[key]?.id == id { tapWaits[key] = nil }
            // The row's callers are not all on the item screen (Now Playing, skim stops, reactions), so `leftItemScreen` does not
            // see every way out. Selecting another item, and Trash (which clears the selection), are caught here: the tap is
            // dropped unless the row's item is still the selected one.
            guard !Task.isCancelled, let model, model.selectedItem.id == row.layer.itemId, !model.recordingNavigationIsLocked else { return }
            guard rendered else { return model.reportWarning("That Margin couldn't be read aloud, so listening continues.") }
            if model.pendingImportedCommentary != nil || model.playingImportedCommentary != nil || model.marginMoment != nil {
                // Something else took the sound while the reading was made; the tap is not dropped without a word.
                return model.reportWarning("That Margin is ready now. Tap it again to hear it.")
            }
            replayingAfterWait.insert(key)
            defer { replayingAfterWait.remove(key) }
            model.hangTelemetry.labels.scoped("writtenMarginRowTap") { model.playSharedMarginMoment(row) }
        }
        tapWaits[key] = Wait(id: id, wasPending: false, task: task, itemId: row.layer.itemId, reading: reading)
        return true
    }

    private static var replayingAfterWait = Set<String>()

    /// What the listener is doing, as the hold sees it. Any change ends the hold: another item or session, playback paused
    /// or started, a Margin moment begun, a card shown or a Margin voice playing. Leaving the screen ends it too
    /// (`leftItemScreen`). Anything but time passing means they took over. A recording being started is not in this list;
    /// the review's own check (`rejectNavigationOrSessionMutationWhileRecording`) refuses it.
    private struct Where: Equatable {
        let selected: String
        let playingItem: String?
        let session: String?
        let active: Bool
        let moment: Bool
        let pending: String?
        let playing: String?
    }

    private static func listenerPlace(_ model: Gate1AppModel) -> Where {
        Where(selected: model.selectedItem.id, playingItem: model.snapshot.itemId, session: model.snapshot.sessionId,
              active: model.snapshot.status.isPlaybackActive, moment: model.marginMoment != nil,
              pending: model.pendingImportedCommentary?.id, playing: model.playingImportedCommentary?.id)
    }

    /// "Skip to the Margins" with a written Margin whose reading isn't ready holds off, for `reviewHold` seconds at
    /// most, then starts, unless the listener did anything else meanwhile (checked every quarter second against where
    /// they were when they asked); a reading still missing then gets the ordinary warning. True when this took the call
    /// (the review starts later, from here).
    static func holdReview(itemId: String, thenContinue: Bool, entries: [SharedMarginReview.Entry], model: Gate1AppModel) -> Bool {
        let key = "review::\(itemId)"
        if releasedReviews.contains(key) { return false } // this is the start after the hold
        if holds[key] != nil { return true } // a second tap while the hold is running
        let readings = entries.compactMap(\.writtenReading)
        let stage = stage
        guard readings.contains(where: { !reader.playbackState(for: $0, onDevice: stage).isReady }) else { return false }
        let from = listenerPlace(model)
        model.reportConfirmation("Getting your new Margins ready.")
        let settled = Flag()
        let stopWaiting = reader.whenRendered(readings, upTo: reviewHold, onDevice: stage) { settled.set() } // asked now, as a tap's wait is
        holds[key] = Task { @MainActor [weak model] in
            // However the hold ends (the review starts, the listener moves, they leave the screen), the wait for the readings
            // ends with it, and an on-device try nobody waits for stops (#3391).
            defer { holds[key] = nil; stopWaiting() }
            while !settled.isSet {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let model, listenerPlace(model) == from else { return } // they went elsewhere: nothing starts
            }
            guard !Task.isCancelled, let model, listenerPlace(model) == from else { return }
            releasedReviews.insert(key)
            model.hangTelemetry.labels.scoped("writtenMarginReview") { model.reviewNewMargins(itemId: itemId, thenContinue: thenContinue, entries: entries) }
            releasedReviews.remove(key)
        }
        return true
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// The listener left the item's screen (back to the Library, another tab) or moved the item to Trash: a tap's wait and a
    /// review's hold for that item end, so nothing starts or pulls them back later. A row's wait also checks the selected
    /// item when it finishes, which covers the other ways out.
    static func leftItemScreen(_ itemId: String) {
        for (key, wait) in tapWaits where wait.itemId == itemId {
            wait.task.cancel() // its place in the reader's queue goes; a render nobody else waits for stops at its next step (#3391)
            tapWaits[key] = nil
        }
        holds["review::\(itemId)"]?.cancel()
    }

    /// The listener dismissed the card of a written Margin whose reading is being made for that card: the wait ends, and an
    /// on-device render stops at its next step if no one else waits for it (#3391). A wait that began from a Timeline row
    /// is the listener's own tap on the row, not the card's, so dismissing the card leaves it.
    static func skipped(_ prompt: ImportedCommentaryPrompt) {
        guard let wait = tapWaits[prompt.id], wait.wasPending else { return }
        wait.task.cancel()
        tapWaits[prompt.id] = nil
    }

    /// Reviews being started after their hold, so the second call doesn't hold again.
    private static var releasedReviews = Set<String>()

    /// The review is starting: any tap still waiting on a reading gives way (nothing plays from it). Returns each entry's
    /// file, its recording or its reading, and starts the renders of readings that aren't ready.
    static func startingReview(for entries: [SharedMarginReview.Entry], voiceFile: (String) -> URL?) -> [String: URL] {
        tapWaits.values.forEach { $0.task.cancel() }
        tapWaits.removeAll()
        var files: [String: URL] = [:]
        for entry in entries {
            files[entry.marginId] = startingRender(audio(for: entry.interjection, in: entry.layer, voiceFile: voiceFile))
        }
        return files
    }

    // MARK: A reading that isn't there when its turn comes

    /// A reading that isn't ready when its turn comes behaves as a missing recording does: a warning, listening carries
    /// on, and the Margin stays new. The words don't say "recording", which a written Margin never was.
    static func rewordUnavailable(on conductor: MarginMomentConductor?, entries: [SharedMarginReview.Entry], model: Gate1AppModel) {
        let written = Dictionary(entries.compactMap { entry in entry.writtenReading.map { (entry.marginId, $0) } }) { first, _ in first }
        reword(on: conductor, readings: written, model: model)
    }

    /// The same for one Margin's moment, from the `audio` it was started with (a recording has nothing to reword).
    static func rewordUnavailable(on conductor: MarginMomentConductor?, marginId: String, audio: SharedMarginAudio, model: Gate1AppModel) {
        guard let reading = audio.reading else { return }
        reword(on: conductor, readings: [marginId: reading], model: model)
    }

    private static func reword(on conductor: MarginMomentConductor?, readings written: [String: WrittenMarginReading], model: Gate1AppModel) {
        guard let conductor, !written.isEmpty else { return }
        let previous = conductor.onVoiceUnavailable
        conductor.onVoiceUnavailable = { [weak model] marginId, reason in
            guard let reading = written[marginId] else { return previous?(marginId, reason) ?? () }
            reader.forget(reading, onDevice: stage) // its file is gone: the next try renders it again
            model?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            model?.reportWarning("That Margin couldn't be read aloud, so listening continues.")
        }
    }
}
