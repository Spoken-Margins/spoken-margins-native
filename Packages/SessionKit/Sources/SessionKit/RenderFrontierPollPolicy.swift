import Foundation

/// A process-wide counter that moves whenever a prepared-audio manifest is written or invalidated
/// (#2652). Reading it costs a lock and no disk, so a screen can ask "did anything change?" cheaply.
public final class PreparedAudioChangeSignal: @unchecked Sendable {
    public static let shared = PreparedAudioChangeSignal()
    private let lock = NSLock()
    private var value = 0
    public init() {}
    public var generation: Int { lock.lock(); defer { lock.unlock() }; return value }
    public func bump() { lock.lock(); value += 1; lock.unlock() }
}

/// Decides when the playback screen's rendered-frontier poll needs to touch the store and the disk
/// (#2652). While the render is incomplete it reads every pass. Once the fraction is complete it
/// goes quiet and reads again only after the change signal has moved (a re-render, an
/// invalidation, a voice's files replaced).
public struct RenderFrontierPollPolicy: Equatable, Sendable {
    public private(set) var settledGeneration: Int?
    public init() {}

    /// Sample the signal before the read, so a change during the read is not lost.
    public func shouldRead(generation: Int) -> Bool {
        guard let settledGeneration else { return true }
        return settledGeneration != generation
    }

    public mutating func record(fraction: Double, generation: Int) {
        settledGeneration = fraction >= 1 ? generation : nil
    }
}
