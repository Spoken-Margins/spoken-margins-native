import Foundation

/// What iOS says about how the previous run of the app ended (#1682), as the fields of one
/// `app.previous_exit` Diagnostics event.
///
/// Built from the JSON form of MetricKit's reports (`MXDiagnosticPayload.jsonRepresentation()` and
/// `MXMetricPayload.jsonRepresentation()`), so it is host-testable with recorded reports. It keeps counts,
/// category names, a few system-supplied numbers and the report's dates, and nothing else: no device model,
/// OS version, bundle or exception text, so nothing in it can tell whose phone it came from. For a crash, CPU
/// exception or hang it also keeps the top frames of the heaviest thread that lie in the app's own binary, as
/// offsets into that binary plus the binary's build UUID (#2099). Those name the code the app shipped, which
/// the Mac can symbolicate, and nothing about the listener.
///
/// MetricKit hands the same report over again for 24 hours, so `Seen` remembers how far earlier launches
/// already reported and a report is only counted once.
public struct PreviousRunExit: Sendable, Equatable {
    public static let eventKind = "app.previous_exit"

    /// The newest report end (`yyyy-MM-dd HH:mm:ss`, or just the day) already put in the log, per kind of report.
    public struct Seen: Sendable, Equatable {
        public var diagnosticsThrough: String?
        public var metricsThrough: String?

        public init(diagnosticsThrough: String? = nil, metricsThrough: String? = nil) {
            self.diagnosticsThrough = diagnosticsThrough
            self.metricsThrough = metricsThrough
        }
    }

    /// The event's fields: `source`, `reason` (comma-separated names, or `none_reported`), counts, and periods.
    public let fields: [String: String]
    /// How many reports were new, that is, not already covered by `Seen`.
    public let newReports: Int
    /// `Seen` to keep after this summary.
    public let seen: Seen

    private static let diagnosticSections: [(key: String, reason: String, countField: String)] = [
        ("crashDiagnostics", "crash", "crashes"),
        ("cpuExceptionDiagnostics", "cpu_exception", "cpuExceptions"),
        ("hangDiagnostics", "hang", "hangs"),
        ("diskWriteExceptionDiagnostics", "disk_write_exception", "diskWriteExceptions"),
    ]

    /// What each section's newest entry adds to the event: the entry's meta-data key, then the event field.
    private static let diagnosticDetails: [String: [(key: String, field: String)]] = [
        "crashDiagnostics": [
            ("exceptionType", "crashExceptionType"),
            ("exceptionCode", "crashExceptionCode"),
            ("signal", "crashSignal"),
            ("terminationReason", "crashTermination"),
        ],
        "cpuExceptionDiagnostics": [
            ("totalCPUTime", "cpuTime"),
            ("totalSampledTime", "cpuSampledTime"),
        ],
        "hangDiagnostics": [
            ("hangDuration", "hangDuration"),
        ],
        "diskWriteExceptionDiagnostics": [
            ("writesCaused", "diskWrites"),
        ],
    ]

    /// The sections whose newest entry also gives the app's top frames, and the event field for them.
    private static let frameFields: [String: String] = [
        "crashDiagnostics": "crashFrames",
        "cpuExceptionDiagnostics": "cpuFrames",
        "hangDiagnostics": "hangFrames",
    ]

    /// How many of the app's own frames are kept, leaf first.
    static let maxFrames = 8

    private static let exitCounts: [(section: String, key: String, field: String, reason: String)] = [
        ("backgroundExitData", "cumulativeCPUResourceLimitExitCount", "bgCpuLimit", "background_cpu_limit"),
        ("backgroundExitData", "cumulativeMemoryResourceLimitExitCount", "bgMemoryLimit", "background_memory_limit"),
        ("backgroundExitData", "cumulativeMemoryPressureExitCount", "bgMemoryPressure", "background_memory_pressure"),
        ("backgroundExitData", "cumulativeAppWatchdogExitCount", "bgWatchdog", "background_watchdog"),
        ("backgroundExitData", "cumulativeSuspendedWithLockedFileExitCount", "bgSuspendedLockedFile", "background_suspended_locked_file"),
        ("backgroundExitData", "cumulativeBackgroundTaskAssertionTimeoutExitCount", "bgTaskTimeout", "background_task_timeout"),
        ("backgroundExitData", "cumulativeBadAccessExitCount", "bgBadAccess", "background_bad_access"),
        ("backgroundExitData", "cumulativeIllegalInstructionExitCount", "bgIllegalInstruction", "background_illegal_instruction"),
        ("backgroundExitData", "cumulativeAbnormalExitCount", "bgAbnormal", "background_abnormal"),
        ("foregroundExitData", "cumulativeMemoryResourceLimitExitCount", "fgMemoryLimit", "foreground_memory_limit"),
        ("foregroundExitData", "cumulativeAppWatchdogExitCount", "fgWatchdog", "foreground_watchdog"),
        ("foregroundExitData", "cumulativeBadAccessExitCount", "fgBadAccess", "foreground_bad_access"),
        ("foregroundExitData", "cumulativeIllegalInstructionExitCount", "fgIllegalInstruction", "foreground_illegal_instruction"),
        ("foregroundExitData", "cumulativeAbnormalExitCount", "fgAbnormal", "foreground_abnormal"),
    ]

    /// - Parameter appBinaryNames: the names MetricKit gives the app's own executable in a call stack. Empty
    ///   keeps no frames.
    public static func summarize(
        diagnosticPayloads: [Data],
        metricPayloads: [Data],
        seen: Seen = Seen(),
        appBinaryNames: Set<String> = []
    ) -> PreviousRunExit {
        var fields: [String: String] = ["source": "metrickit"]
        var reasons: [String] = []
        var newReports = 0
        var keep = seen

        // Diagnostics: counts per kind, and the details of the newest entry of each kind.
        let diagnostics = reports(diagnosticPayloads, after: seen.diagnosticsThrough)
        if !diagnostics.isEmpty {
            newReports += diagnostics.count
            var counts: [String: Int] = [:]
            for report in diagnostics {
                for section in diagnosticSections {
                    let entries = report.root[section.key] as? [[String: Any]] ?? []
                    guard let latest = entries.last else { continue }
                    counts[section.key, default: 0] += entries.count
                    let meta = latest["diagnosticMetaData"] as? [String: Any] ?? [:]
                    for detail in diagnosticDetails[section.key] ?? [] {
                        if let text = label(meta[detail.key], keepingCodes: detail.key == "terminationReason") {
                            fields[detail.field] = text
                        }
                    }
                    if let field = frameFields[section.key],
                       let frames = topFrames(of: latest["callStackTree"], inBinaries: appBinaryNames) {
                        fields[field] = frames.offsets.joined(separator: ",")
                        fields[field + "Binary"] = frames.binary
                    }
                }
            }
            for section in diagnosticSections {
                let found = counts[section.key] ?? 0
                fields[section.countField] = String(found)
                if found > 0 { reasons.append(section.reason) }
            }
            if let span = period(diagnostics) { fields["diagnosticsPeriod"] = span }
            keep.diagnosticsThrough = newest(diagnostics, over: seen.diagnosticsThrough)
        }

        // App-exit counts: summed over the new reports; a count no report gives stays out.
        let metrics = reports(metricPayloads, after: seen.metricsThrough)
            .filter { $0.root["applicationExitMetrics"] is [String: Any] }
        if !metrics.isEmpty {
            newReports += metrics.count
            for spec in exitCounts {
                var running: Int?
                for report in metrics {
                    let exits = report.root["applicationExitMetrics"] as? [String: Any]
                    let section = exits?[spec.section] as? [String: Any]
                    if let value = count(section?[spec.key]) { running = (running ?? 0) + value }
                }
                guard let total = running else { continue }
                fields[spec.field] = String(total)
                if total > 0 { reasons.append(spec.reason) }
            }
            if let span = period(metrics) { fields["exitsPeriod"] = span }
            keep.metricsThrough = newest(metrics, over: seen.metricsThrough)
        }

        fields["newReports"] = String(newReports)
        fields["reason"] = reasons.isEmpty ? "none_reported" : reasons.joined(separator: ",")
        return PreviousRunExit(fields: fields, newReports: newReports, seen: keep)
    }

    // MARK: - Reading the reports

    /// The frames of the heaviest thread in `tree` (MetricKit's `callStackTree`) that are in one of `binaries`,
    /// innermost first, as hex offsets into that binary's text segment, with the binary's build UUID.
    /// "Heaviest" is the thread MetricKit attributes the report to, else the one with the most samples; down
    /// the stack it follows the child with the most samples. Nil when the tree has no such frame.
    private static func topFrames(of tree: Any?, inBinaries binaries: Set<String>) -> (offsets: [String], binary: String)? {
        guard !binaries.isEmpty, let tree = tree as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return nil }
        func weight(_ frames: [[String: Any]]) -> Int { frames.reduce(0) { $0 + (count($1["sampleCount"]) ?? 0) } }
        func roots(_ stack: [String: Any]) -> [[String: Any]] { stack["callStackRootFrames"] as? [[String: Any]] ?? [] }
        let chosen = stacks.first { $0["threadAttributed"] as? Bool == true }
            ?? stacks.max { weight(roots($0)) < weight(roots($1)) }
        guard let chosen else { return nil }

        var path: [[String: Any]] = []
        var level = roots(chosen)
        while let next = level.max(by: { (count($0["sampleCount"]) ?? 0) < (count($1["sampleCount"]) ?? 0) }) {
            path.append(next)
            level = next["subFrames"] as? [[String: Any]] ?? []
            if path.count > 512 { break }
        }
        let own = path.filter { frame in
            guard let name = frame["binaryName"] as? String else { return false }
            return binaries.contains(name)
        }
        guard let innermost = own.last, let uuid = innermost["binaryUUID"] as? String else { return nil }
        let sameBuild = own.filter { $0["binaryUUID"] as? String == uuid }
        let offsets = sameBuild.reversed().prefix(maxFrames).compactMap { frame -> String? in
            guard let offset = count(frame["offsetIntoBinaryTextSegment"]), offset >= 0 else { return nil }
            return "0x" + String(offset, radix: 16)
        }
        guard !offsets.isEmpty, let binary = label(uuid) else { return nil }
        return (Array(offsets), binary)
    }

    private struct Report {
        let root: [String: Any]
        let begin: String?
        let end: String?
    }

    /// The reports that are JSON objects and end after `through`, oldest first. One that gives no end can't be
    /// told from an earlier delivery, so it counts.
    private static func reports(_ payloads: [Data], after through: String?) -> [Report] {
        payloads
            .compactMap { data -> Report? in
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                return Report(root: root, begin: timestamp(root["timeStampBegin"]), end: timestamp(root["timeStampEnd"]))
            }
            .filter { report -> Bool in
                guard let through, let end = report.end else { return true }
                return end > through
            }
            .sorted { ($0.end ?? "") < ($1.end ?? "") }
    }

    private static func period(_ reports: [Report]) -> String? {
        guard let begin = reports.compactMap(\.begin).min(), let end = reports.compactMap(\.end).max() else { return nil }
        return "\(begin) to \(end)"
    }

    private static func newest(_ reports: [Report], over through: String?) -> String? {
        [through, reports.compactMap(\.end).max()].compactMap { $0 }.max()
    }

    private static func count(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// `yyyy-MM-dd HH:mm:ss` or `yyyy-MM-dd` from the start of a MetricKit timestamp; nil if it isn't one.
    private static func timestamp(_ value: Any?) -> String? {
        guard let text = value as? String, text.count >= 10 else { return nil }
        let head = Array(text.prefix(19))
        let shape = head.map { $0.isASCII && $0.isNumber ? Character("9") : $0 }
        guard String(shape.prefix(10)) == "9999-99-99" else { return nil }
        let day = String(head.prefix(10))
        if shape.count == 19, shape[10] == " " || shape[10] == "T", String(shape.suffix(8)) == "99:99:99" {
            return day + " " + String(head.suffix(8))
        }
        return day
    }

    /// A value MetricKit supplies (a number, or a short phrase such as `89 sec`), kept only if it is made of
    /// plain characters. Anything else reads `other`, so free text never reaches the log.
    ///
    /// With `keepingCodes`, text that isn't plain still gives up the parts that name why the system ended the
    /// process (#2184): an upper-case `Namespace NAME`, and a `code:` or `domain:` number or hex value, such as the watchdog's
    /// `code:0x8BADF00D` inside a `<RBSTerminateContext| ...>` description. Everything else in it, which can carry
    /// an app or file name, is dropped, and a text with no such part reads `other`.
    private static func label(_ value: Any?, keepingCodes: Bool = false) -> String? {
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:,-")
        guard trimmed.count <= 60, trimmed.allSatisfy({ plain.contains($0) }) else {
            return keepingCodes ? terminationCodes(in: trimmed) ?? "other" : "other"
        }
        return trimmed
    }

    /// The system's own shapes only: an upper-case namespace (`Namespace SIGNAL`, alone or with its `, Code 0x...`), and a
    /// `code:` or `domain:` with a colon. Free text such as "Namespace Smith" or "Domain 2 notes" matches none of them.
    private static let terminationCodePattern = try? NSRegularExpression(
        pattern: #"\bNamespace [A-Z_]{2,24}, Code 0x[0-9a-fA-F]{1,16}\b|\bNamespace [A-Z_]{2,24}\b|\b(?:code|domain):\s*(?:0x[0-9a-fA-F]{1,16}|[0-9]{1,6})\b"#)

    /// The kept parts of a termination reason, in order and joined by ", ", or nil when it has none.
    private static func terminationCodes(in text: String) -> String? {
        guard let pattern = terminationCodePattern else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        let parts = pattern.matches(in: text, range: whole).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
