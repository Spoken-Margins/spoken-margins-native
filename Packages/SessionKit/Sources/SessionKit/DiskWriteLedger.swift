import Foundation

/// Bytes the app wrote to disk, by what asked for the write and by day (#4389).
///
/// iOS flagged the app twice for writing about 4.3 GB in a day, and the Diagnostics export could not say what wrote
/// it: MetricKit gives the total, not the source. The app reports each large write here (a finished download, a
/// rendered chunk of speech, the files that assembling speech makes), so an export says which of them a heavy day
/// was made of. It counts bytes the app asked to write, from file sizes it already knows; it does not see SQLite's
/// own writes or anything the system adds, so the sum is a floor, not iOS's number. The copy of a rendered chunk
/// into prepared audio is not counted: on APFS a copy is a clone that writes almost nothing.
///
/// Days are UTC dates (`yyyy-MM-dd`) and the ledger keeps `keptDays` of them. It holds source names and byte
/// counts, never a path, an item or a title, so its summary can go in the Diagnostics export.
public struct DiskWriteLedger: Codable, Equatable, Sendable {
    /// What asked for the write. The raw value is what the export says.
    public enum Source: String, CaseIterable, Codable, Sendable {
        /// An episode's audio, as the download finished.
        case download
        /// Speech a voice (Kokoro, Supertonic, Kitten, Phonon or Pocket) rendered to a file, before anything is done with it.
        case speechRender = "speech_render"
        /// Chunks joined into one PCM file, and that file encoded again for playback. Counted as each file is
        /// finished, so a failed encode still counts the PCM and not the partial m4a.
        case speechAssembly = "speech_assembly"
    }

    /// How many days are kept, today included.
    public static let keptDays = 14
    /// How many of the newest days the summary names.
    public static let summaryDays = 7

    /// Bytes per source name, per UTC day. Source names are strings so a build that drops a source can still read
    /// a file an older build wrote.
    public private(set) var days: [String: [String: Int64]]

    public init(days: [String: [String: Int64]] = [:]) {
        self.days = days
    }

    public mutating func record(bytes: Int64, source: Source, at date: Date) {
        guard bytes > 0 else { return }
        let day = Self.day(of: date)
        days[day, default: [:]][source.rawValue, default: 0] += bytes
        Self.prune(&days, today: day)
    }

    /// Drops what is not a day, then keeps the newest `keptDays` days up to today and the newest `keptDays` days after
    /// it. A write never deletes a day only because it is later than the write: the clock now may be the wrong one,
    /// and a clock set back would otherwise erase every real day in one write. Days after today are kept apart from
    /// the real ones, so a clock set ahead can't push real days out, and the summary leaves them out until time reaches them.
    private static func prune(_ days: inout [String: [String: Int64]], today: String) {
        for key in days.keys where !isDay(key) { days[key] = nil }
        let sorted = days.keys.sorted()
        let past = sorted.filter { $0 <= today }
        let later = sorted.filter { $0 > today }
        for stale in past.dropLast(keptDays) { days[stale] = nil }
        for stale in later.dropFirst(keptDays) { days[stale] = nil }
    }

    /// The Diagnostics `diskWritesBySource` line: the newest days first, each as `<day> total=<n>MB <source>=<n>MB ...`
    /// with sources biggest first, and days joined by `; `. A day's figures are the app's own count of what it
    /// wrote that UTC day, and the line ends with the sources that are counted. `none_recorded` before the first write.
    public var summaryText: String { summaryText(asOf: nil) }

    /// The same line, leaving out days after `asOf`'s UTC day (a clock that was set ahead left them); they stay in the
    /// ledger. With no date every day is named.
    public func summaryText(asOf: Date?) -> String {
        let counted = "counted=" + Source.allCases.map(\.rawValue).joined(separator: ",")
        // Only days and source names of the shapes this type writes are printed, so whatever else a file holds can't leave the phone.
        let cutoff = asOf.map(Self.day(of:))
        let newest = days.keys.filter { key in Self.isDay(key) && (cutoff.map { key <= $0 } ?? true) }.sorted(by: >).prefix(Self.summaryDays)
        guard !newest.isEmpty else { return "none_recorded; " + counted }
        let lines = newest.map { day -> String in
            let bySource = (days[day] ?? [:]).filter { Self.isSourceName($0.key) }
            let total = bySource.values.reduce(0, +)
            let parts = bySource
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key)=\(Self.megabytes($0.value))MB" }
            return (["\(day) total=\(Self.megabytes(total))MB"] + parts).joined(separator: " ")
        }
        return (lines + [counted]).joined(separator: "; ")
    }

    /// Whole megabytes (10^6 bytes), rounded to nearest; a write of any size is at least 1.
    static func megabytes(_ bytes: Int64) -> Int64 {
        guard bytes > 0 else { return 0 }
        return max(1, (bytes + 500_000) / 1_000_000)
    }

    /// `yyyy-MM-dd`, digits only.
    static func isDay(_ text: String) -> Bool {
        let shape = text.map { $0.isASCII && $0.isNumber ? Character("9") : $0 }
        return String(shape) == "9999-99-99"
    }

    /// Lower-case letters and underscores, as every `Source` raw value is, and short.
    static func isSourceName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 24 && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") }
    }

    static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// A `DiskWriteLedger` kept in a file, so a heavy day that spans launches (or ends in the system killing the app)
/// is still in the next export. Safe to call from any thread. Each `record` rewrites a file of a few hundred
/// bytes, and the app calls it once per download or per chunk of speech, so the file costs far less than what it counts.
public final class DiskWriteLedgerStore: @unchecked Sendable {
    /// The app's one store, kept in `Application Support/disk-writes.json`. A renderer, a download and the Diagnostics
    /// export all use it, so they agree. In memory only where there is no such folder.
    public static let shared = DiskWriteLedgerStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("disk-writes.json") }
    )

    private let lock = NSLock()
    private var ledger: DiskWriteLedger
    private let fileURL: URL?
    private let now: @Sendable () -> Date

    /// - Parameter fileURL: where the ledger is kept; nil keeps it in memory only.
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(DiskWriteLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = DiskWriteLedger()
        }
    }

    public func record(bytes: Int64, source: DiskWriteLedger.Source) {
        lock.lock()
        defer { lock.unlock() }
        ledger.record(bytes: bytes, source: source, at: now())
        guard let fileURL, let data = try? JSONEncoder().encode(ledger) else { return }
        // Best effort: counting a write must never fail the write it counts.
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The size of the file at `url` as one write; a file that can't be sized counts nothing.
    public func record(fileAt url: URL, source: DiskWriteLedger.Source) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        record(bytes: Int64(size), source: source)
    }

    public var summaryText: String {
        lock.lock()
        defer { lock.unlock() }
        return ledger.summaryText(asOf: now())
    }
}
