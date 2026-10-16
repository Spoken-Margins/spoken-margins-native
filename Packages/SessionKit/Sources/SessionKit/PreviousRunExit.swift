import Foundation

/// What iOS says about how the previous run of the app ended (#1682), as the fields of one
/// `app.previous_exit` Diagnostics event.
///
/// Built from the JSON form of MetricKit's reports (`MXDiagnosticPayload.jsonRepresentation()` and
/// `MXMetricPayload.jsonRepresentation()`), so it is host-testable with recorded reports. It keeps counts,
/// category names, a few system-supplied numbers and the report's dates, and nothing else: no call stacks,
/// device model, OS version, bundle or exception text, so nothing in it can tell whose phone it came from.
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

    public static func summarize(diagnosticPayloads: [Data], metricPayloads: [Data], seen: Seen = Seen()) -> PreviousRunExit {
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
                        if let text = label(meta[detail.key]) { fields[detail.field] = text }
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
    private static func label(_ value: Any?) -> String? {
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
        guard trimmed.count <= 60, trimmed.allSatisfy({ plain.contains($0) }) else { return "other" }
        return trimmed
    }
}
