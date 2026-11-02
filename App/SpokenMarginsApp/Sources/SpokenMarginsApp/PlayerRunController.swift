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
/// The runs are kept on the main actor, where the snapshot changes. The write itself runs off the main thread, in order
/// (`StoreReader.readInOrder`, #2505): `PlayerItemMargin` moves the item's saved place for a few milliseconds and puts it
/// back. If the player saves its own place in that instant, the put-back is overwritten by the player's next save half a
/// second later, so the resume point is at worst that stale for an instant.
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
    static func fileOntoPlayerItem(_ placement: LiveSessionFileWorker.PlayerPlacement) async -> Bool {
        guard let model, let store = model.store else { return false }
        let saved: Interjection
        do {
            saved = try await StoreReader(store).readInOrder("player-item-margin") {
                try PlayerItemMargin.placeSpoken(
                    audioPath: placement.audioPath, atMediaTimeMs: placement.positionMs, markedAt: placement.markedAt,
                    itemId: placement.itemId, repository: $0
                )
            }
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
}
