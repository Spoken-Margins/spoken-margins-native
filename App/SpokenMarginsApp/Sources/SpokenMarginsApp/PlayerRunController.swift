import Foundation
import SessionKit
import SessionKitPersistence

/// Our own player's recent playing, kept so a Margin from the Watch or the Lock Screen, taken with no live session while
/// Spoken Margins was playing an item, lands on that item at the time it was taken (#2542; `docs/design/live-sessions/
/// DESIGN.md` section 2 point 12). The model reports each snapshot here (`note`), `PlayerRunRecorder` turns them into
/// runs of steady playback, and `WatchMarginReceiver` hands the runs to `LiveSessionFiling` and each placement back to
/// `fileOntoPlayerItem`. A Lock Screen Mark becomes a written Margin there (#3203), and a Watch Margin taken while an
/// article played its publisher's recording lands on the article's words. A placement that can't be written (an item with
/// no session, a failed write) returns false, and the receiver files it as a quick session as before, so a Margin is never lost.
///
/// All of it runs on the main actor, deliberately: the write moves the item's saved place for a few milliseconds and puts it
/// back (`PlayerItemMargin`), and the engine names a spoken Margin from the count of the session's Margins. The model's own
/// Margin saves and the player's saves run on the main actor, so running here keeps this write from interleaving with them
/// (an off-main write could take the same Margin id as an in-app Save, or put back a stale place). It is a handful of rows.
@MainActor
enum PlayerRunController {
    private static var recorder = PlayerRunRecorder()
    private static weak var model: Gate1AppModel?
    /// The Library's store, once the model has reported to this controller; nil before that.
    static var store: SQLiteSessionStore? { model?.store }
    /// What the Watch was last told the player has loaded (#3494).
    private static var publishedNowPlaying: WatchNowPlaying?

    /// Notes what the player reports now. Cheap: a few comparisons.
    static func note(_ snapshot: SessionSnapshot, in model: Gate1AppModel, at time: Date = Date()) {
        self.model = model
        // The file the engine plays, so a place is kept with the clock it is on (#4779).
        recorder.observe(PlayerRunRecorder.observation(of: snapshot, mediaURL: model.openSessionMediaURL), at: time)
        // The Watch moves the position on by itself, so only a change it could not predict is sent (#3494).
        // A spoken note's file goes with the board, so a Watch Margin carries the clock its place is on (#4779). Only a
        // note has two clocks; other items send none and keep the board small.
        let item = model.engine?.currentItem
        let noteFile = item.flatMap { SpokenNoteItem.isSpokenNote(mediaType: $0.mediaType) ? $0.media?.url : nil }
        let next = WatchNowPlayingFeed.nowPlaying(from: snapshot, at: time, mediaFile: noteFile)
        if WatchNowPlayingFeed.shouldPublish(previous: publishedNowPlaying, next: next) {
            publishedNowPlaying = next
            WatchMarginReceiver.shared.nowPlayingChanged(next)
        }
    }

    /// Which file each item had attached, and since when, newest last (#4779).
    static func filesAttached() -> [LiveSessionFiling.FileAttachment] {
        recorder.filesAttached
    }

    /// Runs a Watch transport command on the player, through the same compact command path as the Lock Screen (#3494).
    /// Nothing runs with no item loaded, or while a Margin records on the phone, which a skip or a play would end.
    static func runWatchTransport(_ transport: WatchTransport) {
        guard let model, WatchNowPlayingFeed.nowPlaying(from: model.snapshot, at: Date()) != nil, !model.snapshot.isRecording else {
            self.model?.recordDeveloperDiagnostic("transport.watch_ignored", ["command": transport.rawValue])
            return
        }
        model.dispatchGate2CompactCommand(transport.compactCommand, origin: "watch")
    }

    static func observation(of snapshot: SessionSnapshot) -> PlayerRunRecorder.Observation {
        PlayerRunRecorder.observation(of: snapshot)
    }

    /// The runs to file against, newest last.
    static func runs(at now: Date = Date()) -> [LiveSessionFiling.PlayerRun] {
        recorder.runs(at: now)
    }

    /// Writes a placement onto its item. True when it is there; false leaves nothing written.
    static func fileOntoPlayerItem(_ placement: LiveSessionFileWorker.PlayerPlacement) -> Bool {
        guard let model, let store = model.store else { return false }
        let saved: Interjection
        do {
            if let audioPath = placement.audioPath {
                saved = try PlayerItemMargin.placeSpoken(
                    audioPath: audioPath, atMediaTimeMs: placement.positionMs, markedAt: placement.markedAt,
                    itemId: placement.itemId, repository: store, readAloudPlace: readAloudPlace(for: placement),
                    playedOnMediaURL: placement.playingThen?.playingMediaURL // the file it was taken on (#4779)
                )
            } else {
                // A Lock Screen Mark: a written Margin with words that say what it is (#3203).
                saved = try PlayerItemMargin.placeMark(
                    atMediaTimeMs: placement.positionMs, markedAt: placement.markedAt, itemId: placement.itemId, repository: store,
                    playedOnMediaURL: placement.playingThen?.playingMediaURL
                )
            }
        } catch {
            model.diagnostics["playerItemMargin"] = "filed as quick: \(SafeErrorText.describe(error))"
            return false
        }
        model.diagnostics["playerItemMargin"] = "placed \(saved.id)"
        model.hangTelemetry.labels.scoped("playerItemMargin") {
            model.scheduleTranscription(for: saved)
            model.refreshMarginRowsInBackground(forItem: placement.itemId)
            if model.activeItemId == placement.itemId { model.refreshSelectedItemInBackground() }
        }
        return true
    }

    /// For an article read aloud with the on-device voice, which has no media time: the text place it was paused at when
    /// the Watch began recording. A Margin the listener aimed at the item ("On this episode") with no pause on record
    /// goes to the article's saved place rather than a quick session; one nobody aimed there gets no text place (#4561).
    private static func readAloudPlace(for placement: LiveSessionFileWorker.PlayerPlacement) -> PlayerItemMargin.ReadAloudPlace? {
        if let char = recorder.readAloudPlace(itemId: placement.itemId, near: placement.markedAt) { return .textOffset(char) }
        return placement.aimedAtItem ? .savedPlace : nil
    }

    /// The listener deleted a Margin on the Watch that the phone may already have put on an item: marks it deleted there
    /// too (#2542 audit). The scan runs off the main thread; it only sets one Margin's status, which cannot take an id
    /// another save is choosing.
    static func withdrawWatchMargin(id: String) async {
        guard let model, let store = model.store else { return }
        let audioPath = WatchMarginTransfer(id: id, wallStart: Date(timeIntervalSince1970: 1), durationMs: 0).audioPath
        let touched = await Task.detached(priority: .utility) { () -> [String] in
            guard let sessions = try? store.loadSessions() else { return [] }
            return PlayerItemMargin.withdraw(audioPath: audioPath, in: sessions, repository: store) { margin in
                try store.updateInterjection(id: margin.id, sessionId: margin.sessionId) { $0.status = "deleted" } != nil
            }
        }.value
        guard !touched.isEmpty else { return }
        model.diagnostics["playerItemMargin"] = "withdrawn from \(touched.count) source(s)"
        for itemId in touched {
            model.refreshMarginRowsInBackground(forItem: itemId)
            if model.activeItemId == itemId { model.refreshSelectedItemInBackground() }
        }
    }
}
