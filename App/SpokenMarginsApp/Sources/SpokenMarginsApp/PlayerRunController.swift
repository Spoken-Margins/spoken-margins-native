import Foundation
import SessionKit
import SessionKitPersistence

/// Our own player's recent playing, kept so a Margin from the Watch or the Lock Screen, taken with no live session while
/// Spoken Margins was playing an item, lands on that item at the time it was taken (#2542; `docs/design/live-sessions/
/// DESIGN.md` section 2 point 12). The model reports each snapshot here (`note`), `PlayerRunRecorder` turns them into
/// runs of steady playback, and `WatchMarginReceiver` hands the runs to `LiveSessionFiling` and each placement back to
/// `fileOntoPlayerItem`. A placement that can't be written (an item with no session, a Mark with no recording, a failed write) returns
/// false, and the receiver files it as a quick session as before, so a Margin is never lost.
///
/// All of it runs on the main actor, deliberately: the write moves the item's saved place for a few milliseconds and puts it
/// back (`PlayerItemMargin`), and the engine names a spoken Margin from the count of the session's Margins. The model's own
/// Margin saves and the player's saves run on the main actor, so running here keeps this write from interleaving with them
/// (an off-main write could take the same Margin id as an in-app Save, or put back a stale place). It is a handful of rows.
@MainActor
enum PlayerRunController {
    private static var recorder = PlayerRunRecorder()
    private static weak var model: Gate1AppModel?

    /// Notes what the player reports now. Cheap: a few comparisons.
    static func note(_ snapshot: SessionSnapshot, in model: Gate1AppModel, at time: Date = Date()) {
        self.model = model
        recorder.observe(observation(of: snapshot), at: time)
    }

    static func observation(of snapshot: SessionSnapshot) -> PlayerRunRecorder.Observation {
        .init(
            itemId: snapshot.itemId, mediaTimeMs: snapshot.currentMediaTimeMs, rate: snapshot.playbackRate,
            isPlaying: snapshot.status == .playing
        )
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
            saved = try PlayerItemMargin.placeSpoken(
                audioPath: placement.audioPath, atMediaTimeMs: placement.positionMs, markedAt: placement.markedAt,
                itemId: placement.itemId, repository: store
            )
        } catch {
            model.diagnostics["playerItemMargin"] = "filed as quick: \(String(describing: error))"
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
        model.diagnostics["playerItemMargin"] = "withdrawn from \(touched.count) item(s)"
        for itemId in touched {
            model.refreshMarginRowsInBackground(forItem: itemId)
            if model.activeItemId == itemId { model.refreshSelectedItemInBackground() }
        }
    }
}
