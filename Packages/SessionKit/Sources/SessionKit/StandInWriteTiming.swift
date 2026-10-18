import Foundation

/// How long the iOS voice took to write a stand-in for a flagged Supertonic chunk (#1695), for the Diagnostics
/// line the output guard already keeps. In lane simulators the first write waited 29 to 303 s behind a voice
/// download; this says whether a phone ever sees that. It counts writes and times them, and carries no text.
public final class StandInWriteLog: @unchecked Sendable {
    /// One log per app launch, so "the first write" means the first since the app started.
    public static let shared = StandInWriteLog()

    private let lock = NSLock()
    private var started = 0

    public init() {}

    /// A write is about to start: its place among this launch's stand-in writes, counting from 1.
    public func writeStarted() -> Int {
        lock.withLock {
            started += 1
            return started
        }
    }

    /// The Diagnostics wording for a write, whether it produced a file or failed or timed out. Seconds to two
    /// decimals; a negative elapsed time (a clock that went backwards) reads as zero.
    public static func describe(writeNumber: Int, elapsed: TimeInterval) -> String {
        let seconds = String(format: "%.2f", max(0, elapsed))
        let place = writeNumber == 1 ? "first write this launch" : "write \(writeNumber) this launch"
        return "iOS voice \(place) took \(seconds) s"
    }
}
