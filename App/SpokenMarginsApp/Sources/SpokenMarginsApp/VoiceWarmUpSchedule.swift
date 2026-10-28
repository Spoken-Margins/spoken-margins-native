import Foundation

/// Runs the warm-up of a downloaded voice's model (#2856) one at a time for the whole app.
///
/// Every rebuild of the speech client (a voice or speed picked in Settings) makes a new renderer, and each renderer
/// loads its own copy of the model. Warming each of them would put several copies in memory at once while the
/// listener only sits in Settings. A new warm-up cancels the one before it and waits for it to stop, so at most one
/// load is ever in flight, and it begins only if its renderer is still alive and allowed to render.
final class VoiceWarmUpSchedule: @unchecked Sendable {
    static let shared = VoiceWarmUpSchedule()

    private final class WeakRenderer: @unchecked Sendable {
        weak var renderer: AnyObject?
        init(_ renderer: AnyObject) { self.renderer = renderer }
    }

    private let lock = NSLock()
    private var current: Task<Void, Never>?

    /// `delay` gives a client that is rebuilt straight away (a speed change) time to replace this one before it loads.
    func schedule(_ renderer: any SupertonicRendering, allowed: @escaping @Sendable () -> Bool, delay: Duration = .seconds(2)) {
        let weakRenderer = WeakRenderer(renderer as AnyObject)
        lock.withLock {
            let previous = current
            previous?.cancel()
            current = Task.detached(priority: .utility) {
                await previous?.value
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, allowed(), let renderer = weakRenderer.renderer as? any SupertonicRendering else { return }
                await renderer.prepareToRender()
            }
        }
    }
}
