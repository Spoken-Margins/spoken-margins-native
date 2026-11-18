import Foundation

/// Whether the app's memory held steady or kept growing, and in which step, read from footprint samples (#122).
///
/// Two kinds of growth matter for an out-of-memory kill: memory that stays behind each time playback moves
/// to another item (growth per switch), and memory that climbs while one item plays (growth per minute).
/// - Per switch: the change in footprint from one switch into a media type to the next switch into the same type,
///   taking the median so one reload doesn't decide it. The first switch into a type is left out, because it is
///   when that type's engine loads (for example the text voice), and so is the first one after a memory warning,
///   since the app unloads its voices on a warning. It needs at least two changes: four switches into one type.
/// - Per minute: within one stretch of playback samples of the same media type with no switch in between, from
///   its first playback sample (a minute in, after loading) to its last.
/// Only the samples after the newest `launch` count, since a relaunch starts memory over. The log keeps 20 samples,
/// so a long run may have dropped its launch; the verdict then reads the samples it has.
public enum MemoryFootprintVerdict: Equatable, Sendable {
    case steady(switches: Int, playbackMinutes: Int)
    case growingPerSwitch(mediaType: String, megabytesPerSwitch: Int)
    case growingPerMinute(mediaType: String, megabytesPerMinute: Int)
    /// Not enough samples to say: fewer than four switches into one media type and no stretch of three
    /// playback samples.
    case tooFewSamples

    /// Growth below these is noise: caches filling and the allocator's own slack. 10 MB a switch reaches a
    /// gigabyte in 100 switches; 5 MB a minute reaches it in about three hours of listening.
    public static let switchThresholdBytes: Double = 10 * 1_048_576
    public static let minuteThresholdBytes: Double = 5 * 1_048_576

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
                if let last = stretch.last, last.mediaType != sample.mediaType {
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
        var worstSwitch: (type: String, perSwitch: Double)?
        for type in typeOrder {
            let changes = changesByType[type, default: []].sorted()
            guard changes.count >= 2 else { continue }
            measured = true
            let middle = changes.count / 2
            let perSwitch = changes.count.isMultiple(of: 2) ? (changes[middle - 1] + changes[middle]) / 2 : changes[middle]
            if perSwitch >= Self.switchThresholdBytes, perSwitch > (worstSwitch?.perSwitch ?? 0) {
                worstSwitch = (type, perSwitch)
            }
        }

        var worstMinute: (type: String, perMinute: Double)?
        var playbackSeconds: TimeInterval = 0
        for stretch in stretches where stretch.count >= 3 {
            guard let first = stretch.first, let last = stretch.last else { continue }
            let seconds = last.time.timeIntervalSince(first.time)
            guard seconds > 0 else { continue }
            measured = true
            playbackSeconds += seconds
            let perMinute = (Double(last.footprintBytes) - Double(first.footprintBytes)) / seconds * 60
            if perMinute >= Self.minuteThresholdBytes, perMinute > (worstMinute?.perMinute ?? 0) {
                worstMinute = (first.mediaType, perMinute)
            }
        }

        if let worstSwitch {
            self = .growingPerSwitch(mediaType: worstSwitch.type, megabytesPerSwitch: Self.megabytes(worstSwitch.perSwitch))
        } else if let worstMinute {
            self = .growingPerMinute(mediaType: worstMinute.type, megabytesPerMinute: Self.megabytes(worstMinute.perMinute))
        } else if measured {
            let switches = current.filter { $0.event == .itemSwitch }.count
            self = .steady(switches: switches, playbackMinutes: Int((playbackSeconds / 60).rounded()))
        } else {
            self = .tooFewSamples
        }
    }

    /// For Diagnostics, for example `growing 35MB per switch into text`.
    public var diagnosticsLine: String {
        switch self {
        case let .steady(switches, playbackMinutes):
            return "steady: \(switches) switches, \(playbackMinutes) playback minutes measured"
        case let .growingPerSwitch(mediaType, megabytes):
            return "growing \(megabytes)MB per switch into \(mediaType)"
        case let .growingPerMinute(mediaType, megabytes):
            return "growing \(megabytes)MB per minute playing \(mediaType)"
        case .tooFewSamples:
            return "too few samples to say"
        }
    }

    private static func megabytes(_ bytes: Double) -> Int {
        Int((bytes / 1_048_576).rounded())
    }
}
