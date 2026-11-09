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

/// Which run an event belongs to. A run ends when the pass finds nothing left to do or is stopped; the
/// next event starts a new run, which replaces the last summary. A heat pause doesn't end a run: it is
/// one of the run's numbers.
public struct AudioPreparationRunTracker: Equatable, Sendable {
    public private(set) var current: AudioPreparationRunSummary?
    private var isOpen = false

    public init() {}

    /// The summary line after `event`, for Diagnostics.
    @discardableResult
    public mutating func chunkCommitted(renderMs: Int, thermalAtStart: SpeechThermalLevel, thermalAtEnd: SpeechThermalLevel, at: TimeInterval) -> String {
        // The render began renderMs before it was committed.
        update(startingAt: at - Double(max(0, renderMs)) / 1_000) {
            $0.chunkCommitted(renderMs: renderMs, thermalAtStart: thermalAtStart, thermalAtEnd: thermalAtEnd, at: at)
        }
    }

    @discardableResult
    public mutating func heatPaused(thermal: SpeechThermalLevel, at: TimeInterval) -> String {
        update(startingAt: at) { $0.heatPaused(thermal: thermal, at: at) }
    }

    /// The pass stopped or found no work. The summary stays until the next run replaces it.
    public mutating func ended() {
        isOpen = false
    }

    private mutating func update(startingAt start: TimeInterval, _ change: (inout AudioPreparationRunSummary) -> Void) -> String {
        var summary = isOpen ? (current ?? AudioPreparationRunSummary(startedAt: start)) : AudioPreparationRunSummary(startedAt: start)
        change(&summary)
        current = summary
        isOpen = true
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
