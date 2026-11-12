import Foundation

/// The clock a recording's headset rules read (#3937): when the recording began and when the audio route last
/// changed during it. `MarginCaptureWatcher` holds one and `RecordingRouteReplay` holds one, so a replayed trace
/// reaches `RecordingTransportGuard` and `HeadphoneMuteGestureDetector` through the same two numbers the app gives
/// them. Pure: every call is told the time on a clock that only moves forward.
public struct RecordingRouteClock: Equatable, Sendable {
    public private(set) var startedAtMs: Int?
    public private(set) var lastRouteChangeAtMs: Int?

    public init() {}

    /// A recording began. A route change from the last recording must not hold back this one's first click.
    public mutating func begin(atMs: Int) {
        startedAtMs = atMs
        lastRouteChangeAtMs = nil
    }

    /// The audio route changed. Ignored while nothing records.
    public mutating func routeChanged(atMs: Int) {
        guard startedAtMs != nil else { return }
        lastRouteChangeAtMs = atMs
    }

    /// The recording ended or is no longer watched.
    public mutating func end() {
        startedAtMs = nil
        lastRouteChangeAtMs = nil
    }

    /// Milliseconds since the recording began, 0 when nothing records.
    public func elapsedMs(atMs now: Int) -> Int {
        startedAtMs.map { max(0, now - $0) } ?? 0
    }

    /// Milliseconds since the route last changed during this recording, nil when it has not.
    public func msSinceRouteChange(atMs now: Int) -> Int? {
        lastRouteChangeAtMs.map { max(0, now - $0) }
    }
}

/// A recorded run of what a Bluetooth, AirPlay or wired route did while a Margin recorded, with when each thing
/// happened (#3937). It is the fixture format for route-timing bugs the host could not reach: a fake route event
/// proves our reaction, but not the order and delay of the events iOS sends. Traces are written by hand from the
/// timings a bug report or a Diagnostics line states (the `recordingMs` and `sinceRouteChangeMs` fields of
/// `transport.ignored_during_recording`), never from a listener's recordings.
///
/// JSON, one object: `{"name": "...", "issue": "#2182", "events": [{"atMs": 0, "event": "recording_started", ...}]}`.
/// Times are milliseconds on one clock that only moves forward. Event kinds: `recording_started` (optional
/// `handsFreeInput`, `muted`), `route_changed` (optional `handsFreeInput`), `command` (`command` is a
/// `CompactControlCommand` raw value, `origin` where it arrived, e.g. `now_playing_remote`) and `mute_changed`
/// (`muted`, the headset's microphone mute state).
public struct RecordingRouteTrace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case recordingStarted = "recording_started"
        case routeChanged = "route_changed"
        case command
        case muteChanged = "mute_changed"
    }

    public struct Event: Codable, Equatable, Sendable {
        public var atMs: Int
        public var event: Kind
        public var command: CompactControlCommand?
        public var origin: String?
        public var handsFreeInput: Bool?
        public var muted: Bool?

        public init(
            atMs: Int, event: Kind, command: CompactControlCommand? = nil, origin: String? = nil,
            handsFreeInput: Bool? = nil, muted: Bool? = nil
        ) {
            self.atMs = atMs
            self.event = event
            self.command = command
            self.origin = origin
            self.handsFreeInput = handsFreeInput
            self.muted = muted
        }
    }

    public enum TraceError: Error, Equatable, Sendable {
        case noEvents
        case mustStartWithRecordingStarted
        case timeWentBackwards(atMs: Int)
        case missingField(event: Kind, field: String, atMs: Int)
        case secondRecordingStarted(atMs: Int)
    }

    public var name: String
    public var issue: String?
    public var events: [Event]

    public init(name: String, issue: String? = nil, events: [Event]) {
        self.name = name
        self.issue = issue
        self.events = events
    }

    /// Reads a trace from JSON and checks that it can be replayed.
    public static func decode(_ json: Data) throws -> RecordingRouteTrace {
        let trace = try JSONDecoder().decode(RecordingRouteTrace.self, from: json)
        try trace.validate()
        return trace
    }

    public func validate() throws {
        guard let first = events.first else { throw TraceError.noEvents }
        guard first.event == .recordingStarted else { throw TraceError.mustStartWithRecordingStarted }
        var last = first.atMs
        for (index, event) in events.enumerated() {
            if event.atMs < last { throw TraceError.timeWentBackwards(atMs: event.atMs) }
            last = event.atMs
            switch event.event {
            case .recordingStarted:
                if index > 0 { throw TraceError.secondRecordingStarted(atMs: event.atMs) }
            case .command:
                if event.command == nil { throw TraceError.missingField(event: .command, field: "command", atMs: event.atMs) }
                if event.origin == nil { throw TraceError.missingField(event: .command, field: "origin", atMs: event.atMs) }
            case .muteChanged:
                if event.muted == nil { throw TraceError.missingField(event: .muteChanged, field: "muted", atMs: event.atMs) }
            case .routeChanged:
                break
            }
        }
    }
}

/// Plays a `RecordingRouteTrace` into the rules the app applies while a Margin records, on the trace's own clock (#3937).
public enum RecordingRouteReplay {
    /// The decisions the replay asks, so a test can run a trace against the rule as it was before a fix.
    public struct Rules: Sendable {
        public var transport: @Sendable (_ command: CompactControlCommand, _ recordingMs: Int, _ sinceRouteChangeMs: Int?, _ handsFree: Bool) -> RecordingTransportGuard.Verdict
        public var mute: @Sendable (_ detector: inout HeadphoneMuteGestureDetector, _ muted: Bool, _ recordingMs: Int, _ sinceRouteChangeMs: Int?) -> HeadphoneMuteGestureDetector.Verdict

        public init(
            transport: @escaping @Sendable (CompactControlCommand, Int, Int?, Bool) -> RecordingTransportGuard.Verdict,
            mute: @escaping @Sendable (inout HeadphoneMuteGestureDetector, Bool, Int, Int?) -> HeadphoneMuteGestureDetector.Verdict
        ) {
            self.transport = transport
            self.mute = mute
        }

        /// The rules the app ships.
        public static let production = Rules(
            transport: { command, recordingMs, sinceRouteChangeMs, handsFree in
                RecordingTransportGuard.verdict(
                    command: command, recordingMs: recordingMs, sinceRouteChangeMs: sinceRouteChangeMs, onHandsFreeProfile: handsFree)
            },
            mute: { detector, muted, recordingMs, sinceRouteChangeMs in
                switch detector.observe(muted: muted, recordingMs: recordingMs, sinceRouteChangeMs: sinceRouteChangeMs) {
                case .endMargin: return .endMargin
                case .ignore(let reason): return .ignore(reason)
                }
            }
        )
    }

    /// What one event did.
    public enum Outcome: Equatable, Sendable {
        /// The recording began, the route changed or a command that never ends a Margin (a skip back) arrived.
        case noDecision
        /// The listener's click or press: the Margin ends and saves here. The replay stops.
        case endsMargin
        /// Headset noise, left recording. The reason is the guard's own (`recording_just_started`, ...).
        case ignored(String)
    }

    public struct Step: Equatable, Sendable {
        public let atMs: Int
        public let event: RecordingRouteTrace.Event
        public let outcome: Outcome
    }

    public struct Result: Equatable, Sendable {
        public let steps: [Step]
        /// When the Margin ended, nil when the trace ends with it still recording.
        public var endedAtMs: Int? { steps.last(where: { $0.outcome == .endsMargin })?.atMs }
        /// The reasons of the events the rules ignored, in order.
        public var ignoredReasons: [String] {
            steps.compactMap { if case .ignored(let reason) = $0.outcome { reason } else { nil } }
        }
    }

    public static func replay(_ trace: RecordingRouteTrace, rules: Rules = .production) throws -> Result {
        try trace.validate()
        var clock = RecordingRouteClock()
        var handsFree = false
        var detector = HeadphoneMuteGestureDetector(initiallyMuted: false)
        var steps: [Step] = []
        for event in trace.events {
            var outcome = Outcome.noDecision
            switch event.event {
            case .recordingStarted:
                clock.begin(atMs: event.atMs)
                handsFree = event.handsFreeInput ?? false
                detector = HeadphoneMuteGestureDetector(initiallyMuted: event.muted ?? false)
            case .routeChanged:
                clock.routeChanged(atMs: event.atMs)
                if let input = event.handsFreeInput { handsFree = input }
            case .command:
                // `validate` has checked the fields.
                if let command = event.command, let origin = event.origin,
                   RecordingTransportGuard.isEndCandidate(command: command, origin: origin) {
                    let verdict = rules.transport(
                        command, clock.elapsedMs(atMs: event.atMs), clock.msSinceRouteChange(atMs: event.atMs), handsFree)
                    outcome = .init(verdict)
                }
            case .muteChanged:
                let verdict = rules.mute(
                    &detector, event.muted ?? false, clock.elapsedMs(atMs: event.atMs), clock.msSinceRouteChange(atMs: event.atMs))
                outcome = .init(verdict)
            }
            steps.append(Step(atMs: event.atMs, event: event, outcome: outcome))
            if outcome == .endsMargin { break } // the Margin is saved; nothing later reaches it
        }
        return Result(steps: steps)
    }
}

extension RecordingRouteReplay.Outcome {
    init(_ verdict: RecordingTransportGuard.Verdict) {
        switch verdict {
        case .endMargin: self = .endsMargin
        case .ignore(let reason): self = .ignored(reason.rawValue)
        }
    }

    init(_ verdict: HeadphoneMuteGestureDetector.Verdict) {
        switch verdict {
        case .endMargin: self = .endsMargin
        case .ignore(let reason): self = .ignored(reason.rawValue)
        }
    }
}
