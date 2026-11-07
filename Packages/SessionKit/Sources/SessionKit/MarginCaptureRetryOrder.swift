import Foundation

/// Try again's order on a dead microphone: the repeating cue has ended, and only then does the new recorder start, or
/// the cue's tail opens the new file. Ending the cue can wait on the system's audio service, so the main thread doesn't
/// wait for it: it sends the stop, goes on, and the restart runs when the stop says it has landed.
///
/// Things can happen in that gap, and this type is what settles them. While it waits, `isWaiting` is true, so the
/// watcher holds its polling (a poll could start the cue again or restart the recorder ahead of the cue's stop). A
/// second tap adds nothing. A recording that ends calls `cancel()`, so a late answer can't restart the recorder of the
/// next recording.
@MainActor
public final class MarginCaptureRetryOrder {
    public private(set) var isWaiting = false
    private var attempt = 0

    public init() {}

    /// Sends `stop`, then runs `step` once `stop` has called what it was given. Ignored while an earlier one waits.
    public func begin(
        stop: @MainActor (_ finished: @escaping @MainActor () -> Void) -> Void,
        then step: @escaping @MainActor () -> Void
    ) {
        guard !isWaiting else { return }
        attempt += 1
        let mine = attempt
        isWaiting = true
        stop { [weak self] in
            guard let self, self.isWaiting, self.attempt == mine else { return }
            self.isWaiting = false
            step()
        }
    }

    /// Drops what is waiting: its step will not run, whenever its stop answers.
    public func cancel() {
        isWaiting = false
    }
}
