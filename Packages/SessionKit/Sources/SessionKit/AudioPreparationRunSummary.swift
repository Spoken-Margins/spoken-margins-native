import Foundation

/// What one "Make available offline" run cost (#3816): chunks rendered, how long each took, heat pauses,
/// the hottest the phone got, and the wall-clock time. It is one text line in the basic Diagnostics
/// export under `audioPreparationLastRun`, so the owner doesn't have to turn on detailed recording and
/// repeat a hard run to read those numbers (#64).
///
/// The line holds counts, times and a heat level only: no titles, text, or item ids.
public struct AudioPreparationRunSummary: Equatable, Sendable {
    public static let diagnosticsKey = "audioPreparationLastRun"

    public private(set) var chunkRenderMs: [Int] = []
    public private(set) var heatPauses = 0
    public private(set) var peakThermal: SpeechThermalLevel = .nominal
    /// Seconds on any clock, as long as every call uses the same one.
    public private(set) var startedAt: TimeInterval
    public private(set) var lastActivityAt: TimeInterval

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        lastActivityAt = startedAt
    }

    public var chunks: Int { chunkRenderMs.count }

    /// A chunk was committed at `at`, after `renderMs` of rendering. `thermalAtStart` and `thermalAtEnd`
    /// are the heat read before and after the render; the hotter one counts toward the peak.
    public mutating func chunkCommitted(renderMs: Int, thermalAtStart: SpeechThermalLevel, thermalAtEnd: SpeechThermalLevel, at: TimeInterval) {
        chunkRenderMs.append(max(0, renderMs))
        observe(thermalAtStart)
        observe(thermalAtEnd)
        lastActivityAt = max(lastActivityAt, at)
    }

    /// The pass stopped before a chunk because the phone was too warm.
    public mutating func heatPaused(thermal: SpeechThermalLevel, at: TimeInterval) {
        heatPauses += 1
        observe(thermal)
        lastActivityAt = max(lastActivityAt, at)
    }

    private mutating func observe(_ thermal: SpeechThermalLevel) {
        if thermal.rank > peakThermal.rank { peakThermal = thermal }
    }

    /// The middle render time; the mean of the two middle ones for an even count. Nil for an empty run.
    public var renderMsMedian: Int? {
        guard !chunkRenderMs.isEmpty else { return nil }
        let sorted = chunkRenderMs.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle] + 1) / 2 : sorted[middle]
    }

    /// The 90th percentile, nearest rank: the render time 9 in 10 chunks came in at or under. Nil for an empty run.
    public var renderMsP90: Int? {
        guard !chunkRenderMs.isEmpty else { return nil }
        let sorted = chunkRenderMs.sorted()
        let rank = Int((Double(sorted.count) * 0.9).rounded(.up))
        return sorted[min(sorted.count, max(1, rank)) - 1]
    }

    public var wallClockSeconds: Int { max(0, Int((lastActivityAt - startedAt).rounded())) }

    /// `chunks=12;renderMsMedian=5200;renderMsP90=8100;heatPauses=1;peakThermal=fair;wallClockS=143`.
    public var line: String {
        [
            "chunks=\(chunks)",
            "renderMsMedian=\(renderMsMedian.map(String.init) ?? "none")",
            "renderMsP90=\(renderMsP90.map(String.init) ?? "none")",
            "heatPauses=\(heatPauses)",
            "peakThermal=\(peakThermal.rawValue)",
            "wallClockS=\(wallClockSeconds)"
        ].joined(separator: ";")
    }
}

/// Which run an event belongs to. No loop, task or wait ends a run: the foreground loop, the background task and
/// the pause wait take turns on one queue, and each can stop while another goes on, so an "I'm done" call from
/// one of them cut another's run in two (found at three places in review and audit of #3835). A run is the
/// events that follow one another on one queue, and it ends in one of two ways, neither tied to who is running:
/// the queue is empty after a committed chunk (`queueDrained()`), or nothing happens for longer than `idleGap`,
/// which is longer than the longest heat wait (`OfflinePreparationRun.maximumHeatWaitSeconds`) so a pause being
/// waited out doesn't split its run. The next event after either starts a new run and replaces the last summary.
public struct AudioPreparationRunTracker: Equatable, Sendable {
    public static let idleGap = TimeInterval(OfflinePreparationRun.maximumHeatWaitSeconds + 5 * 60)

    public private(set) var current: AudioPreparationRunSummary?
    private var isDrained = false

    public init() {}

    /// The queue held no job after a committed chunk: whatever comes next is a new request, not this run.
    public mutating func queueDrained() {
        isDrained = true
    }

    /// The summary line after `event`, for Diagnostics.
    @discardableResult
    public mutating func chunkCommitted(renderMs: Int, thermalAtStart: SpeechThermalLevel, thermalAtEnd: SpeechThermalLevel, at: TimeInterval) -> String {
        // The render began renderMs before it was committed.
        update(startingAt: at - Double(max(0, renderMs)) / 1_000, at: at) {
            $0.chunkCommitted(renderMs: renderMs, thermalAtStart: thermalAtStart, thermalAtEnd: thermalAtEnd, at: at)
        }
    }

    @discardableResult
    public mutating func heatPaused(thermal: SpeechThermalLevel, at: TimeInterval) -> String {
        update(startingAt: at, at: at) { $0.heatPaused(thermal: thermal, at: at) }
    }

    private mutating func update(startingAt start: TimeInterval, at: TimeInterval, _ change: (inout AudioPreparationRunSummary) -> Void) -> String {
        var summary: AudioPreparationRunSummary
        if let current, !isDrained, at - current.lastActivityAt <= Self.idleGap {
            summary = current
        } else {
            summary = AudioPreparationRunSummary(startedAt: start)
        }
        change(&summary)
        current = summary
        isDrained = false
        return summary.line
    }
}

private extension SpeechThermalLevel {
    var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}
