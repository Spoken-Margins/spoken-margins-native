import Foundation

/// One finished store read: which public method asked, what it pulled out of SQLite and how long it took (#2258).
public struct StoreReadSample: Equatable, Sendable {
    /// The public store method (or, for a few internal text reads, the read's own name).
    public var method: String
    public var rows: Int
    /// UTF-8 bytes of the row payloads handed to the decoder (or returned as text).
    public var bytes: Int
    /// Wall time of the whole read: the SQLite step loop plus decoding.
    public var durationNs: UInt64
    public var onMainThread: Bool

    public var milliseconds: Double { Double(durationNs) / 1_000_000 }
}

/// What a test or a diagnostics export sees for one method after many reads.
public struct StoreReadTotals: Equatable, Sendable {
    public var calls = 0
    public var rows = 0
    public var bytes = 0
    public var durationNs: UInt64 = 0
    public var maxDurationNs: UInt64 = 0
    public var mainThreadCalls = 0
}

/// Counts what each `SQLiteSessionStore` read decodes (#2258), so "reads too much" is a number a test can assert on.
///
/// Read-only instrumentation: it never changes a query, a row or the schema. A store built without a meter
/// (the app's default) does one `nil` check per read and takes no clock reading and no lock.
public final class StoreReadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StoreReadSample] = []

    public init() {}

    func record(_ sample: StoreReadSample) {
        lock.withLock { recorded.append(sample) }
    }

    /// Every read since the last `reset()`, oldest first.
    public var samples: [StoreReadSample] { lock.withLock { recorded } }

    public func reset() {
        lock.withLock { recorded.removeAll(keepingCapacity: true) }
    }

    /// Reads grouped by method.
    public func totals() -> [String: StoreReadTotals] {
        var result: [String: StoreReadTotals] = [:]
        for sample in samples {
            var entry = result[sample.method, default: StoreReadTotals()]
            entry.calls += 1
            entry.rows += sample.rows
            entry.bytes += sample.bytes
            entry.durationNs += sample.durationNs
            entry.maxDurationNs = max(entry.maxDurationNs, sample.durationNs)
            if sample.onMainThread { entry.mainThreadCalls += 1 }
            result[sample.method] = entry
        }
        return result
    }

    public func totals(for method: String) -> StoreReadTotals { totals()[method] ?? StoreReadTotals() }

    /// Runs `body` and returns what it read, leaving earlier samples out. For "this tap reads at most N" assertions.
    public func measuring<T>(_ body: () throws -> T) rethrows -> (value: T, samples: [StoreReadSample]) {
        let start = lock.withLock { recorded.count }
        let value = try body()
        let all = samples
        return (value, Array(all[min(start, all.count)...]))
    }
}

/// A started measurement. `nil` when the store has no meter, so the unmetered path takes no clock reading.
struct StoreReadTimer {
    private let meter: StoreReadMeter
    private let method: String
    private let start = DispatchTime.now().uptimeNanoseconds
    private let onMainThread = Thread.isMainThread

    init?(_ meter: StoreReadMeter?, method: String) {
        guard let meter else { return nil }
        self.meter = meter
        self.method = method
    }

    func finish(rows: Int, bytes: Int) {
        meter.record(StoreReadSample(
            method: method, rows: rows, bytes: bytes,
            durationNs: DispatchTime.now().uptimeNanoseconds - start, onMainThread: onMainThread))
    }
}
