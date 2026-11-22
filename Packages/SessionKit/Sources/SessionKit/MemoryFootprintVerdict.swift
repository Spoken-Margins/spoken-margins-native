import Foundation

/// Whether the app's memory held steady or kept growing, and in which step, read from footprint samples (#122).
///
/// Two kinds of growth matter for an out-of-memory kill: memory that stays behind each time playback moves
/// to another item (growth per switch), and memory that climbs while one item plays (growth per minute).
/// - Per switch: the change in footprint from one switch into a media type to the next switch into the same type.
///   The first switch into a type is left out, because it is when that type's engine loads (for example the text
///   voice), and so is the first one after a memory warning, since the app unloads its voices on a warning. It needs
///   at least four changes: six switches into one type, because a voice keeps settling for about two switches after it
///   loads (`minimumChangesPerType`). It takes the median, and with an even count the lower of the middle two,
///   so that settling, or one reload, doesn't decide it.
///   A switch is sampled as the new item starts, so its footprint is mostly what the items before it left behind.
///   When listening alternates between two types, memory left behind by either one shows up in both types' changes,
///   and the verdict names every type that grew: the samples can't say which of the two leaves it.
/// - Per minute: within one stretch of playback samples of the same media type, with no switch and no pause in
///   between, the least-squares slope of footprint over time, from the stretch's first playback sample (a minute in,
///   after loading). A stretch counts once it covers five minutes, so a few megabytes of wobble over two minutes
///   don't read as a climb. Playback samples come about a minute apart; a longer gap is a pause, which starts a
///   new stretch so the paused time isn't counted as playback.
/// Only the samples after the newest `launch` count, since a relaunch starts memory over. The log keeps 20 samples,
/// so a long run may have dropped its launch; the verdict then reads the samples it has.
public enum MemoryFootprintVerdict: Equatable, Sendable {
    case steady(switches: Int, playbackMinutes: Int)
    /// `mediaTypes`: every type whose switches grew, the worst first; `megabytesPerSwitch` is the worst.
    case growingPerSwitch(mediaTypes: [String], megabytesPerSwitch: Int)
    case growingPerMinute(mediaType: String, megabytesPerMinute: Int)
    /// Not enough samples to say: fewer than six switches into one media type and no five-minute stretch of
    /// playback samples.
    case tooFewSamples

    /// Growth below these is noise: caches filling and the allocator's own slack. 10 MB a switch reaches a
    /// gigabyte in 100 switches; 5 MB a minute reaches it in about three hours of listening.
    public static let switchThresholdBytes: Double = 10 * 1_048_576
    public static let minuteThresholdBytes: Double = 5 * 1_048_576
    /// The shortest stretch of playback that is measured per minute.
    public static let minimumStretchSeconds: TimeInterval = 300
    /// Playback samples further apart than this have a pause between them (the recorder samples about each minute).
    public static let pauseGapSeconds: TimeInterval = 150
    /// The fewest changes per switch into one media type that are read for growth. After its engine loads, a voice
    /// keeps settling for about two more switches (Supertonic on main-t3 at c9e5697, 2026-11-22: 363 → 410 → 428 →
    /// 428 MB). With two changes both were that settling, and the verdict read it as 18 MB per switch. With four,
    /// three must reach the threshold, and the settling supplies only two. Memory left behind at every switch still
    /// reads as growth.
    public static let minimumChangesPerType = 4
    /// Switches into each media type in the measured run (`PodcastToArticleMemoryTests`): the first loads the engine,
    /// the second is where measuring starts, and each one after it is a change.
    public static let switchesPerTypeInMeasuredRun = minimumChangesPerType + 2

    public init(samples: [MemoryFootprintLog.Sample]) {
        let lastLaunch = samples.lastIndex { $0.event == .launch }
        let current = lastLaunch.map { Array(samples[samples.index(after: $0)...]) } ?? samples

        // Per type: no entry until the switch that loads its engine, then the footprint each change is measured from.
        enum Measure { case loaded, from(UInt64) }
        var measure: [String: Measure] = [:]
        var changesByType: [String: [Double]] = [:]
        var typeOrder: [String] = []
        var stretches: [[MemoryFootprintLog.Sample]] = []
        var stretch: [MemoryFootprintLog.Sample] = []
        for sample in current {
            switch sample.event {
            case .itemStart, .itemSwitch:
                let type = sample.mediaType
                if !typeOrder.contains(type) { typeOrder.append(type) }
                switch measure[type] {
                case nil:
                    measure[type] = .loaded
                case .loaded:
                    measure[type] = .from(sample.footprintBytes)
                case let .from(previous):
                    changesByType[type, default: []].append(Double(sample.footprintBytes) - Double(previous))
                    measure[type] = .from(sample.footprintBytes)
                }
                stretches.append(stretch)
                stretch = []
            case .playback:
                if let last = stretch.last,
                   last.mediaType != sample.mediaType || sample.time.timeIntervalSince(last.time) > Self.pauseGapSeconds {
                    stretches.append(stretch)
                    stretch = []
                }
                stretch.append(sample)
            case .memoryWarning:
                // The app unloads its voices on a warning, so each type's next switch reloads: start measuring after it.
                measure = [:]
            case .launch:
                break
            }
        }
        stretches.append(stretch)

        var measured = false
        var grownSwitches: [(type: String, perSwitch: Double)] = []
        for type in typeOrder {
            let changes = changesByType[type, default: []].sorted()
            guard changes.count >= Self.minimumChangesPerType else { continue }
            measured = true
            let perSwitch = changes[(changes.count - 1) / 2]
            if perSwitch >= Self.switchThresholdBytes { grownSwitches.append((type, perSwitch)) }
        }

        var worstMinute: (type: String, perMinute: Double)?
        var playbackSeconds: TimeInterval = 0
        for stretch in stretches {
            guard let first = stretch.first, let last = stretch.last else { continue }
            let seconds = last.time.timeIntervalSince(first.time)
            guard seconds >= Self.minimumStretchSeconds else { continue }
            measured = true
            playbackSeconds += seconds
            let perMinute = Self.slopePerSecond(stretch) * 60
            if perMinute >= Self.minuteThresholdBytes, perMinute > (worstMinute?.perMinute ?? 0) {
                worstMinute = (first.mediaType, perMinute)
            }
        }

        if let worst = grownSwitches.map(\.perSwitch).max() {
            // Stable sort: equal growth keeps the order the types first played in.
            let types = grownSwitches.enumerated()
                .sorted { ($0.element.perSwitch, -$0.offset) > ($1.element.perSwitch, -$1.offset) }
                .map(\.element.type)
            self = .growingPerSwitch(mediaTypes: types, megabytesPerSwitch: Self.megabytes(worst))
        } else if let worstMinute {
            self = .growingPerMinute(mediaType: worstMinute.type, megabytesPerMinute: Self.megabytes(worstMinute.perMinute))
        } else if measured {
            let switches = current.filter { $0.event == .itemSwitch }.count
            self = .steady(switches: switches, playbackMinutes: Int((playbackSeconds / 60).rounded()))
        } else {
            self = .tooFewSamples
        }
    }

    /// For Diagnostics, for example `growing 35MB per switch into text` or
    /// `growing 35MB per switch into transcript_backed_media and text`.
    public var diagnosticsLine: String {
        switch self {
        case let .steady(switches, playbackMinutes):
            return "steady: \(switches) switches, \(playbackMinutes) playback minutes measured"
        case let .growingPerSwitch(mediaTypes, megabytes):
            return "growing \(megabytes)MB per switch into \(mediaTypes.joined(separator: " and "))"
        case let .growingPerMinute(mediaType, megabytes):
            return "growing \(megabytes)MB per minute playing \(mediaType)"
        case .tooFewSamples:
            return "too few samples to say"
        }
    }

    /// Least-squares slope of footprint over time, in bytes per second. The stretch spans at least
    /// `minimumStretchSeconds`, so its times are not all equal.
    private static func slopePerSecond(_ stretch: [MemoryFootprintLog.Sample]) -> Double {
        let origin = stretch[0].time
        let points = stretch.map { ($0.time.timeIntervalSince(origin), Double($0.footprintBytes)) }
        let meanT = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let covariance = points.map { ($0.0 - meanT) * ($0.1 - meanY) }.reduce(0, +)
        let variance = points.map { ($0.0 - meanT) * ($0.0 - meanT) }.reduce(0, +)
        return covariance / variance
    }

    private static func megabytes(_ bytes: Double) -> Int {
        Int((bytes / 1_048_576).rounded())
    }
}
