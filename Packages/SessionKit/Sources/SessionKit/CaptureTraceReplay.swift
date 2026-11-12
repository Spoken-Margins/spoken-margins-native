import Foundation

/// A recorded run of the events a Margin's recording meets on a real route (#3937): when the recorder opened and what it
/// had captured, when the audio route changed, and which Now Playing or remote commands arrived and when. A fake route
/// event proves our reaction; a trace also carries the order and the delays iOS really produced, which is what #1506,
/// #1708 and #2182 turned on.
///
/// Traces are JSON, one file per bug shape, in `Contracts/fixtures/capture-traces/`. They come from a phone's Diagnostics
/// export (`transport.dispatch_during_recording`, `transport.ends_margin`, `capture.reading` lines) or are written to
/// match one, and carry times and port names only: never a recording, a title, a transcript or an id. A fixture says in
/// `source` which it is.
///
///     { "format": "capture-trace/1", "name": "...", "bug": "#2182", "source": "...",
///       "events": [ { "atMs": 0, "kind": "recordingStarted", "inputs": ["BluetoothHFP"] },
///                   { "atMs": 2182, "kind": "command", "command": "play", "origin": "now_playing" } ] }
///
/// `atMs` is on one clock that only moves forward, and events are in order. Kinds: `recordingStarted` (the recorder
/// accepted its start; `inputs` is the audio session's input port types then), `routeChange` (`inputs` after the
/// change), `recorderReading` (`running`, `capturedMs`), `command` (`command` is a `CompactControlCommand`; `origin` as the
/// app names it, `now_playing…` for a headset, car or Lock Screen command) and `nowPlayingInfo` (kept for the record:
/// what the system's Now Playing card showed; no decision reads it).
public struct CaptureTrace: Codable, Equatable, Sendable {
    public static let format = "capture-trace/1"

    public enum Kind: String, Codable, Sendable {
        case recordingStarted, routeChange, recorderReading, command, nowPlayingInfo
    }

    public struct Event: Codable, Equatable, Sendable {
        public var atMs: Int
        public var kind: Kind
        public var inputs: [String]?
        public var command: CompactControlCommand?
        public var origin: String?
        public var running: Bool?
        public var capturedMs: Int?

        public init(atMs: Int, kind: Kind, inputs: [String]? = nil, command: CompactControlCommand? = nil,
                    origin: String? = nil, running: Bool? = nil, capturedMs: Int? = nil) {
            self.atMs = atMs
            self.kind = kind
            self.inputs = inputs
            self.command = command
            self.origin = origin
            self.running = running
            self.capturedMs = capturedMs
        }
    }

    public var format: String
    public var name: String
    public var bug: String?
    public var source: String
    public var events: [Event]

    public init(name: String, bug: String? = nil, source: String, events: [Event]) {
        self.format = Self.format
        self.name = name
        self.bug = bug
        self.source = source
        self.events = events
    }

    public static func decode(_ data: Data) throws -> CaptureTrace {
        try JSONDecoder().decode(CaptureTrace.self, from: data)
    }
}

/// Replays a `CaptureTrace` on its own clock into the capture decisions the app makes, and says what each one was.
///
/// What it runs is SessionKit's real code: `MarginCaptureSupervisor` for whether audio is arriving and whether to
/// restart, and `RecordingTransportGuard` for whether a command ends the Margin. What it supplies is the wiring the app does around
/// them, which lives in `Gate1AppModel+CompactCommands.swift` and `MarginCaptureWatcher.swift`: elapsed time from the
/// recording's start, time since the last route change *during this recording* (a change before it started is not
/// counted, which is how #2182's phantom play got through), and whether the input is a Bluetooth hands-free port. If
/// that wiring changes in the app, change it here in the same PR.
public enum CaptureTraceReplay {
    public static let handsFreePort = "BluetoothHFP"

    public enum Outcome: Equatable, Sendable {
        /// A command that ends a Margin arrived and the guard took it for headset noise.
        case commandIgnored(CompactControlCommand, RecordingTransportGuard.Reason)
        /// The listener's click: the Margin ended and saved.
        case marginEnded(CompactControlCommand)
        /// A command that cannot end a Margin here (not a Now Playing origin, or not an ending command).
        case commandPassedOn(CompactControlCommand)
        case health(MarginCaptureSupervisor.Health)
        /// The supervisor asked for a new recorder; the replay assumes it starts.
        case restarted
    }

    public struct Step: Equatable, Sendable {
        public let atMs: Int
        public let outcome: Outcome
    }

    public struct Result: Equatable, Sendable {
        public let steps: [Step]
        /// When the Margin ended, nil if the trace ends with it still recording.
        public var endedAtMs: Int? {
            steps.first { if case .marginEnded = $0.outcome { return true } else { return false } }?.atMs
        }
        public var ignored: [(atMs: Int, reason: RecordingTransportGuard.Reason)] {
            steps.compactMap { if case .commandIgnored(_, let reason) = $0.outcome { return ($0.atMs, reason) } else { return nil } }
        }
        public var healthChanges: [MarginCaptureSupervisor.Health] {
            steps.compactMap { if case .health(let health) = $0.outcome { return health } else { return nil } }
        }
        public var restarts: Int { steps.filter { $0.outcome == .restarted }.count }

        public static func == (lhs: Result, rhs: Result) -> Bool { lhs.steps == rhs.steps }
    }

    public enum TraceError: Error, Equatable, CustomStringConvertible {
        case wrongFormat(String)
        case outOfOrder(atMs: Int, after: Int)
        case missing(String, atMs: Int)
        case startedTwice(atMs: Int)

        public var description: String {
            switch self {
            case .wrongFormat(let found): return "format \(found), expected \(CaptureTrace.format)"
            case .outOfOrder(let atMs, let after): return "event at \(atMs) ms comes after one at \(after) ms"
            case .missing(let what, let atMs): return "event at \(atMs) ms is missing \(what)"
            case .startedTwice(let atMs): return "second recordingStarted at \(atMs) ms"
            }
        }
    }

    public static func replay(_ trace: CaptureTrace) throws -> Result {
        guard trace.format == CaptureTrace.format else { throw TraceError.wrongFormat(trace.format) }
        var steps: [Step] = []
        var inputs: [String] = []
        var startedAtMs: Int?
        var lastRouteChangeAtMs: Int?
        var supervisor: MarginCaptureSupervisor?
        var lastHealth: MarginCaptureSupervisor.Health?
        var ended = false
        var previous = Int.min

        func observe(_ reading: RecordingCaptureReading, at atMs: Int) {
            guard var current = supervisor else { return }
            func noteHealth() {
                guard current.health != lastHealth else { return }
                lastHealth = current.health
                steps.append(Step(atMs: atMs, outcome: .health(current.health)))
            }
            let action = current.observe(reading, nowMs: atMs)
            noteHealth() // what the screen would say before a restart, then after it
            if action == .restartCapture {
                current.captureRestarted(nowMs: atMs)
                steps.append(Step(atMs: atMs, outcome: .restarted))
                noteHealth()
            }
            supervisor = current
        }

        for event in trace.events {
            guard event.atMs >= previous else { throw TraceError.outOfOrder(atMs: event.atMs, after: previous) }
            previous = event.atMs
            switch event.kind {
            case .recordingStarted:
                guard startedAtMs == nil else { throw TraceError.startedTwice(atMs: event.atMs) }
                guard let ports = event.inputs else { throw TraceError.missing("inputs", atMs: event.atMs) }
                inputs = ports
                startedAtMs = event.atMs
                lastRouteChangeAtMs = nil // a change before the recording began is not counted
                supervisor = MarginCaptureSupervisor(beganAtMs: event.atMs)
                observe(RecordingCaptureReading(recorderRunning: true, capturedMs: 0), at: event.atMs)
            case .routeChange:
                guard let ports = event.inputs else { throw TraceError.missing("inputs", atMs: event.atMs) }
                inputs = ports
                if startedAtMs != nil { lastRouteChangeAtMs = event.atMs }
            case .recorderReading:
                guard !ended, startedAtMs != nil else { continue }
                guard let running = event.running, let captured = event.capturedMs else {
                    throw TraceError.missing("running and capturedMs", atMs: event.atMs)
                }
                observe(RecordingCaptureReading(recorderRunning: running, capturedMs: captured), at: event.atMs)
            case .command:
                guard let command = event.command, let origin = event.origin else {
                    throw TraceError.missing("command and origin", atMs: event.atMs)
                }
                guard let started = startedAtMs, !ended, command.endsRecordingMargin, origin.hasPrefix("now_playing") else {
                    if startedAtMs != nil, !ended { steps.append(Step(atMs: event.atMs, outcome: .commandPassedOn(command))) }
                    continue
                }
                let verdict = RecordingTransportGuard.verdict(
                    command: command,
                    recordingMs: event.atMs - started,
                    sinceRouteChangeMs: lastRouteChangeAtMs.map { event.atMs - $0 },
                    onHandsFreeProfile: inputs.contains(handsFreePort)
                )
                switch verdict {
                case .endMargin:
                    ended = true
                    steps.append(Step(atMs: event.atMs, outcome: .marginEnded(command)))
                case .ignore(let reason):
                    steps.append(Step(atMs: event.atMs, outcome: .commandIgnored(command, reason)))
                }
            case .nowPlayingInfo:
                break
            }
        }
        return Result(steps: steps)
    }
}
