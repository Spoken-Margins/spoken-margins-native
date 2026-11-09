import Foundation

/// The microphone route of the Margin being recorded, read off the main thread and kept for the capture poll (#2511).
///
/// The poll runs every 50 ms for the first seconds of a Margin (#1506), which is exactly when Bluetooth headphones settle
/// into the hands-free profile. It used to read `AVAudioSession.currentRoute` each time, on the main thread. That getter
/// asks the audio server, so a server busy with the route change could hold the screen once per poll. Now the poll only
/// reads `value`, which never waits: a read of the route runs on this cache's own queue, started when a recording begins
/// and again on every route change, and its answer is kept here.
///
/// `set` and `clear` win over a read still in flight, so a Margin never shows the route of the one before it.
public final class CaptureInputRouteCache: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var route: String?
    /// Moves on every `set`, `clear` and `refreshOffMain`; a read that finds it moved on is out of date and is dropped.
    private var generation: UInt64 = 0

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// The route last read, or nil before the first read lands. Never waits for a read in flight.
    public var value: String? { lock.withLock { route } }

    /// A recording began with no route known yet: forget the last Margin's.
    public func clear() {
        lock.withLock {
            generation &+= 1
            route = nil
        }
    }

    /// A route already read somewhere that may wait (the preparation queue, after its session switch).
    public func set(_ newRoute: String?) {
        lock.withLock {
            generation &+= 1
            route = newRoute
        }
    }

    /// Reads the route on the cache's queue and keeps the answer. A newer `refreshOffMain`, `set` or `clear` made before
    /// this read finishes drops its answer, so the last word is always the newest request's.
    public func refreshOffMain(read: @escaping @Sendable () -> String?) {
        let mine = lock.withLock { () -> UInt64 in
            generation &+= 1
            return generation
        }
        queue.async { [self] in
            let fresh = read()
            lock.withLock {
                guard generation == mine else { return }
                route = fresh
            }
        }
    }

    /// Returns once every read queued so far has finished. For tests.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
