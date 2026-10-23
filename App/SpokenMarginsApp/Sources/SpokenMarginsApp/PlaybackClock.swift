import Combine
import SwiftUI
import SessionKit

/// Where playback stands, published on its own so a progress tick wakes the few views that follow the playhead
/// instead of every screen (#2074).
///
/// While audio plays, the app ticks twice a second and each tick changes the media time and text offset. The model
/// is one `ObservableObject` read by every screen, so publishing those changes through it re-ran each screen's
/// `body`, scrolling or not. The model now publishes a snapshot change to all screens only when something other than
/// the position moved (`SessionSnapshot.equalIgnoringPlaybackPosition`), and hands every snapshot to this clock.
/// A view that draws the playhead (the scrubber, the Now rows, the Timeline's current row, the mini player's chapter
/// line) follows the clock with `followsPlaybackClock`.
final class PlaybackClock: ObservableObject {
    @Published private(set) var position = PlaybackTickPosition()

    /// Every snapshot the model is about to hold, for subscribers outside SwiftUI (the start cue, the memory
    /// recorder). Like the `@Published` property it replaces, it sends before the model's value changes, and sends
    /// the current value to a new subscriber.
    let snapshots = CurrentValueSubject<SessionSnapshot, Never>(SessionSnapshot())

    func snapshotWillChange(to next: SessionSnapshot) {
        let nextPosition = next.tickPosition
        if nextPosition != position { position = nextPosition }
        snapshots.send(next)
    }
}

extension View {
    /// Re-runs the host view's `body` on each playback tick. The host keeps `@State private var playbackTick = 0`,
    /// reads it at the top of `body` (`let _ = playbackTick`) and passes `$playbackTick` here.
    func followsPlaybackClock(_ clock: PlaybackClock, tick: Binding<Int>) -> some View {
        onReceive(clock.objectWillChange) { _ in tick.wrappedValue &+= 1 }
    }
}
