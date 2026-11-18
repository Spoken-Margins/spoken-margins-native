import Foundation

/// Whether the app's memory held steady or kept growing, and in which step, read from footprint samples (#122).
///
/// Two kinds of growth matter for an out-of-memory kill: memory that stays behind each time playback moves
/// to another item (growth per switch), and memory that climbs while one item plays (growth per minute).
/// - Per switch: the footprint at each switch into the same media type, from the second such switch on. The
///   first one is left out because it is when that type's engine loads, for example the text voice.
/// - Per minute: within one stretch of playback samples of the same media type with no switch in between, from
///   its first playback sample (a minute in, after loading) to its last.
/// Only the samples after the newest `launch` count, since a relaunch starts memory over.
public enum MemoryFootprintVerdict: Equatable, Sendable {
    case steady(switches: Int, playbackMinutes: Int)
    case growingPerSwitch(mediaType: String, megabytesPerSwitch: Int)
    case growingPerMinute(mediaType: String, megabytesPerMinute: Int)
    /// Not enough samples to say: fewer than three switches into one media type and no stretch of three
    /// playback samples.
    case tooFewSamples

    /// Growth below these is noise: caches filling and the allocator's own slack. 10 MB a switch reaches a
    /// gigabyte in 100 switches; 5 MB a minute reaches it in about three hours of listening.
    public static let switchThresholdBytes: Double = 10 * 1_048_576
    public static let minuteThresholdBytes: Double = 5 * 1_048_576

    public init(samples: [MemoryFootprintLog.Sample]) {
        let lastLaunch = samples.lastIndex { $0.event == .launch }
        let current = lastLaunch.map { Array(samples[samples.index(after: $0)...]) } ?? samples

        var switchesByType: [String: [MemoryFootprintLog.Sample]] = [:]
        var typeOrder: [String] = []
        var stretches: [[MemoryFootprintLog.Sample]] = []
        var stretch: [MemoryFootprintLog.Sample] = []
        for sample in current {
            switch sample.event {
            case .itemStart, .itemSwitch:
                if switchesByType[sample.mediaType] == nil { typeOrder.append(sample.mediaType) }
                switchesByType[sample.mediaType, default: []].append(sample)
                stretches.append(stretch)
                stretch = []
            case .playback:
                if let last = stretch.last, last.mediaType != sample.mediaType {
                    stretches.append(stretch)
                    stretch = []
                }
                stretch.append(sample)
            case .launch, .memoryWarning:
                break
            }
        }
        stretches.append(stretch)

        var measured = false
        var worstSwitch: (type: String, perSwitch: Double)?
        for type in typeOrder {
            let afterLoad = Array(switchesByType[type, default: []].dropFirst())
            guard afterLoad.count >= 2, let first = afterLoad.first, let last = afterLoad.last else { continue }
            measured = true
            let perSwitch = (Double(last.footprintBytes) - Double(first.footprintBytes)) / Double(afterLoad.count - 1)
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
            return "steady since launch: \(switches) switches, \(playbackMinutes) playback minutes measured"
        case let .growingPerSwitch(mediaType, megabytes):
            return "growing \(megabytes)MB per switch into \(mediaType)"
        case let .growingPerMinute(mediaType, megabytes):
            return "growing \(megabytes)MB per minute playing \(mediaType)"
        case .tooFewSamples:
            return "too few samples since launch"
        }
    }

    private static func megabytes(_ bytes: Double) -> Int {
        Int((bytes / 1_048_576).rounded())
    }
}
