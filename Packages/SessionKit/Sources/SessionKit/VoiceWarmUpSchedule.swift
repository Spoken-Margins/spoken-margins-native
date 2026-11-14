import Foundation

/// What the warm-up schedule needs from a renderer: one best-effort call that loads its model ahead of the first Play
/// (#2856). The app's `SupertonicRendering` extends this, so a renderer is handed over as it is.
public protocol VoiceWarmUpRendering: Sendable {
    /// Loads the model and runs one short render ahead of the first Play, so that first Play doesn't pay the load
    /// (#2856). Best effort: it never throws, and a renderer that has nothing to load does nothing.
    func prepareToRender() async
}

/// Runs the warm-up of a downloaded voice's model (#2856) one at a time for the whole app.
///
/// Every rebuild of the speech client (a voice or speed picked in Settings) makes a new renderer, and each renderer
/// loads its own copy of the model. Warming each of them would put several copies in memory at once while the
/// listener only sits in Settings. A new warm-up cancels the one before it and waits for it to stop, so at most one
/// load is ever in flight, and it begins only if its renderer is still alive and allowed to render.
public final class VoiceWarmUpSchedule: @unchecked Sendable {
    public static let shared = VoiceWarmUpSchedule()

    private final class WeakRenderer: @unchecked Sendable {
        weak var renderer: AnyObject?
        init(_ renderer: AnyObject) { self.renderer = renderer }
    }

    private let lock = NSLock()
    private var current: Task<Void, Never>?

    public init() {}

    /// Stops the pending or running warm-up. The speech client is being built for a voice that has none to run (James,
    /// Lily, Kitten), so a downloaded voice chosen a moment ago must not go on loading its model. A load already under
    /// way can't be interrupted, so the handle stays: the next warm-up still waits for it to finish.
    public func cancel() {
        lock.withLock { current?.cancel() }
    }

    /// `delay` gives a client that is rebuilt straight away (a speed change) time to replace this one before it loads.
    public func schedule(_ renderer: any VoiceWarmUpRendering, allowed: @escaping @Sendable () -> Bool, delay: Duration = .seconds(2)) {
        let weakRenderer = WeakRenderer(renderer as AnyObject)
        lock.withLock {
            let previous = current
            previous?.cancel()
            current = Task.detached(priority: .utility) {
                await previous?.value
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, allowed(), let renderer = weakRenderer.renderer as? any VoiceWarmUpRendering else { return }
                await renderer.prepareToRender()
            }
        }
    }
}
