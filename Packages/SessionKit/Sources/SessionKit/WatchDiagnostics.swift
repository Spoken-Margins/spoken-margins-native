import Foundation

// The Watch's own record of launches, failures and unclean endings (#3506).
//
// Until now the Watch kept nothing: a launch that crashed left no trace, and the phone's Diagnostics export holds
// only what the Watch managed to say. This file is the format and the rules; the Watch app writes it to a small file
// on each change, sends it to the phone when it can, and the phone keeps the latest copy for its Diagnostics export.
//
// Like `WatchContract.swift`, SessionKit compiles this file for the phone and project.yml compiles it straight into
// the Watch app, which doesn't link SessionKit. So it uses Foundation only.
//
// What may go in: launch counts, event kinds, error domains and codes, and type names. Never Margin text, titles,
// addresses, paths or audio. `WatchDiagnosticsLog.cleaned(_:)` enforces it for the free-text detail by keeping only
// a short run of plain characters, so a stray error string can't carry anything long or readable out of the Watch.

/// One line in the Watch's record.
public struct WatchDiagnosticEvent: Codable, Equatable, Sendable {
    /// What happened. A struct, not an enum, so a kind a later Watch build adds still decodes on this phone.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        /// The app started (in front or for a background wake).
        public static let launched = Kind("launched")
        /// The app came to the front for the first time since it launched.
        public static let becameActive = Kind("becameActive")
        /// The last launch never reached the front, and nothing says it went to the background: it crashed or was
        /// ended while starting. This is the line a crash at every launch leaves.
        public static let previousLaunchNeverBecameActive = Kind("previousLaunchNeverBecameActive")
        /// The last run was in front when it ended, with no step to the background: a crash, or the system ending it.
        public static let previousRunEndedInFront = Kind("previousRunEndedInFront")
        /// A step failed. The detail says which and carries an error domain and code.
        public static let failure = Kind("failure")
        /// An Objective-C exception reached the top. Swift traps (a force unwrap, an index out of range) do not come
        /// here; they show up as `previousLaunchNeverBecameActive` or `previousRunEndedInFront` on the next launch.
        public static let uncaughtException = Kind("uncaughtException")
    }

    /// Counts up for the life of the file, so the phone can tell what it has already seen.
    public var number: Int
    public var at: Date
    public var kind: Kind
    public var detail: String

    public init(number: Int, at: Date, kind: Kind, detail: String = "") {
        self.number = number
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

/// What the Watch keeps across launches: the last 40 events and where the previous run stood.
public struct WatchDiagnosticsLog: Codable, Equatable, Sendable {
    /// How far the last run got, written as it goes so the next launch can tell how it ended.
    public enum Phase: String, Codable, Sendable {
        /// Nothing recorded yet (a fresh install).
        case none
        /// Launched in front and not yet active: a launch that ends here crashed while starting.
        case launching
        /// In front.
        case active
        /// Went to the background, or woke there. An end here is ordinary.
        case background
    }

    public static let maxEvents = 40
    public static let maxDetailLength = 80
    /// The whole log, encoded, stays under this. Oldest events go first.
    public static let maxEncodedBytes = 8 * 1024

    public private(set) var phase: Phase
    public private(set) var launchCount: Int
    public private(set) var nextNumber: Int
    /// The highest event number handed to WatchConnectivity.
    public private(set) var sentThrough: Int
    public private(set) var events: [WatchDiagnosticEvent]

    public init() {
        phase = .none
        launchCount = 0
        nextNumber = 1
        sentThrough = 0
        events = []
    }

    /// Events the phone has not been sent yet.
    public var hasUnsent: Bool {
        guard let last = events.last else { return false }
        return last.number > sentThrough
    }

    // MARK: Recording

    /// The app launched. First reads how the previous run ended and records it, then starts this run.
    /// `inFront` is false for a background wake (a WatchConnectivity delivery), which never becomes active and so
    /// must not look like a launch crash next time.
    public mutating func launched(at date: Date, inFront: Bool = true) {
        switch phase {
        case .launching:
            append(.previousLaunchNeverBecameActive, "launches=\(launchCount)", at: date)
        case .active:
            append(.previousRunEndedInFront, "launches=\(launchCount)", at: date)
        case .none, .background:
            break
        }
        launchCount += 1
        activeSinceLaunch = false
        phase = inFront ? .launching : .background
        append(.launched, "n=\(launchCount) front=\(inFront ? "yes" : "no")", at: date)
    }

    /// The app is in front. Only the first time after a launch is an event; a wrist raise is not.
    public mutating func becameActive(at date: Date) {
        phase = .active
        guard !activeSinceLaunch else { return }
        activeSinceLaunch = true
        append(.becameActive, "", at: date)
    }

    /// The app left the front, so an end from here on is ordinary.
    public mutating func wentToBackground() {
        phase = .background
    }

    /// A step failed. `what` names the step in plain words ("transferFailed"); `detail` should be an error domain and
    /// code (`WatchDiagnosticsLog.errorCode(_:)`), never a message the listener wrote or heard.
    public mutating func failed(_ what: String, detail: String = "", at date: Date) {
        let tail = detail.isEmpty ? "" : " \(detail)"
        append(.failure, "\(what)\(tail)", at: date)
    }

    public mutating func uncaughtException(name: String, at date: Date) {
        append(.uncaughtException, name, at: date)
    }

    /// Everything recorded so far has been handed to WatchConnectivity.
    public mutating func markSent() {
        sentThrough = (events.last?.number ?? nextNumber - 1)
    }

    /// `NSCocoaErrorDomain/513`: the domain and code of an error, which carry no text of the listener's.
    public static func errorCode(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)/\(ns.code)"
    }

    /// Plain characters only, one line, at most `maxDetailLength`. Spaces, letters, digits and `. _ : - = , /`
    /// stay; everything else (quotes, brackets, accents, newlines) is dropped. A slash stays only as part of a
    /// short code, since the length cap leaves no room for an address or a path worth reading.
    public static func cleaned(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._:-=,/")
        var kept = String(text.filter { allowed.contains($0) })
        // `//` begins an address and `/x/y` a path; neither is wanted, so a slash survives only between a domain and
        // a code (`Domain/513`).
        kept = kept.replacingOccurrences(of: "//", with: "")
        if kept.filter({ $0 == "/" }).count > 1 {
            kept = kept.replacingOccurrences(of: "/", with: "")
        }
        if kept.count > maxDetailLength { kept = String(kept.prefix(maxDetailLength)) }
        return kept
    }

    // MARK: The report for the phone

    public func report(build: String, osVersion: String, at date: Date) -> WatchDiagnosticsReport {
        WatchDiagnosticsReport(build: Self.cleaned(build), osVersion: Self.cleaned(osVersion), sentAt: date,
                               launchCount: launchCount, phase: phase, events: events)
    }

    // MARK: Internals

    /// Set when this run has been in front; kept in the log so `becameActive` records once per launch.
    private var activeSinceLaunch = false

    private enum CodingKeys: String, CodingKey {
        case phase, launchCount, nextNumber, sentThrough, events, activeSinceLaunch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = (try? c.decode(Phase.self, forKey: .phase)) ?? .none
        launchCount = (try? c.decode(Int.self, forKey: .launchCount)) ?? 0
        nextNumber = max(1, (try? c.decode(Int.self, forKey: .nextNumber)) ?? 1)
        sentThrough = (try? c.decode(Int.self, forKey: .sentThrough)) ?? 0
        events = (try? c.decode([WatchDiagnosticEvent].self, forKey: .events)) ?? []
        activeSinceLaunch = (try? c.decode(Bool.self, forKey: .activeSinceLaunch)) ?? false
    }

    private mutating func append(_ kind: WatchDiagnosticEvent.Kind, _ detail: String, at date: Date) {
        events.append(WatchDiagnosticEvent(number: nextNumber, at: date, kind: kind, detail: Self.cleaned(detail)))
        nextNumber += 1
        trim()
    }

    private mutating func trim() {
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        while events.count > 1, Self.encodedSize(self) > Self.maxEncodedBytes {
            events.removeFirst()
        }
    }

    private static func encodedSize(_ log: WatchDiagnosticsLog) -> Int {
        (try? WatchDiagnosticsCoding.encoder.encode(log).count) ?? 0
    }
}

/// What travels to the phone: the whole record, which is small, so the phone keeps only the latest copy.
public struct WatchDiagnosticsReport: Codable, Equatable, Sendable {
    public var build: String
    public var osVersion: String
    public var sentAt: Date
    public var launchCount: Int
    public var phase: WatchDiagnosticsLog.Phase
    public var events: [WatchDiagnosticEvent]

    public init(build: String, osVersion: String, sentAt: Date, launchCount: Int,
                phase: WatchDiagnosticsLog.Phase, events: [WatchDiagnosticEvent]) {
        self.build = build
        self.osVersion = osVersion
        self.sentAt = sentAt
        self.launchCount = launchCount
        self.phase = phase
        self.events = events
    }

    /// The phone doesn't trust what arrives: it cuts the events, the text and the whole to the same limits the Watch
    /// keeps, so a bug or a hand-made message can't fill the phone's file or its export.
    public func clamped() -> WatchDiagnosticsReport {
        var copy = self
        copy.build = WatchDiagnosticsLog.cleaned(build)
        copy.osVersion = WatchDiagnosticsLog.cleaned(osVersion)
        copy.events = Array(events.suffix(WatchDiagnosticsLog.maxEvents)).map { event in
            var event = event
            event.detail = WatchDiagnosticsLog.cleaned(event.detail)
            event.kind = .init(WatchDiagnosticsLog.cleaned(event.kind.rawValue))
            return event
        }
        while copy.events.count > 1,
              ((try? WatchDiagnosticsCoding.encoder.encode(copy).count) ?? 0) > WatchDiagnosticsLog.maxEncodedBytes {
            copy.events.removeFirst()
        }
        return copy
    }
}

public enum WatchDiagnosticsCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// The Watch's log file: read and rewritten whole on every change (a few kilobytes), synchronously, so the phase is on
/// disk before whatever comes next can crash. A missing or unreadable file starts a fresh log.
public final class WatchDiagnosticsRecorder: @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()

    /// `nil` keeps nothing (previews and tests that must not touch disk).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public func load() -> WatchDiagnosticsLog {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// Reads the log, applies `change`, writes it back, and returns the result.
    @discardableResult
    public func update(_ change: (inout WatchDiagnosticsLog) -> Void) -> WatchDiagnosticsLog {
        lock.lock()
        defer { lock.unlock() }
        var log = read()
        change(&log)
        if let fileURL, let data = try? WatchDiagnosticsCoding.encoder.encode(log) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return log
    }

    private func read() -> WatchDiagnosticsLog {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let log = try? WatchDiagnosticsCoding.decoder.decode(WatchDiagnosticsLog.self, from: data) else {
            return WatchDiagnosticsLog()
        }
        return log
    }
}

/// The phone's copy of the Watch's latest report, and its line in the Diagnostics export.
public enum WatchDiagnosticsStore {
    public static let schemaVersion = "spoken-margins.watch-diagnostics.v1"
    /// The export key the report goes under.
    public static let exportKey = "watchDiagnostics"

    /// Where the phone keeps the Watch's latest report: its Application Support folder.
    public static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WatchDiagnostics.json")
    }

    /// Keeps `report` (clamped) unless the file already holds a newer one. The same log can arrive on both lanes, and
    /// the sure lane can arrive late, so an older copy never overwrites a newer one.
    @discardableResult
    public static func save(_ report: WatchDiagnosticsReport, to fileURL: URL) -> Bool {
        let incoming = report.clamped()
        if let existing = read(fileURL), existing.sentAt > incoming.sentAt { return false }
        guard let data = try? WatchDiagnosticsCoding.encoder.encode(incoming) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func read(_ fileURL: URL) -> WatchDiagnosticsReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? WatchDiagnosticsCoding.decoder.decode(WatchDiagnosticsReport.self, from: data)
    }

    /// The JSON text the export carries, or nil when the Watch never sent a report. Dates read as ISO 8601 here.
    public static func exportJSON(fileURL: URL) -> String? {
        guard let report = read(fileURL) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Capture(schemaVersion: schemaVersion, report: report.clamped())) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Capture: Encodable {
        var schemaVersion: String
        var report: WatchDiagnosticsReport
    }
}
