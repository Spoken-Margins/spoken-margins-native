import Foundation
import SessionKit

extension Gate1AppModel {
    /// Called by `snapshot`'s `willSet`, which replaces the `@Published` wrapper (#2074).
    ///
    /// The playhead goes to the clock on every change. The model, which every screen reads, publishes unless the new
    /// snapshot differs from the held one in its playback position alone: those are the progress ticks, two a second
    /// while audio plays. A write of an identical snapshot still publishes, as it did under `@Published`, because a few
    /// paths write `snapshot = snapshot` to make the screens look again.
    func publishSnapshotChange(to next: SessionSnapshot) {
        playbackClock.snapshotWillChange(to: next)
        let positionOnly = next != snapshot && next.equalIgnoringPlaybackPosition(to: snapshot)
        if !positionOnly { objectWillChange.send() }
    }
}
