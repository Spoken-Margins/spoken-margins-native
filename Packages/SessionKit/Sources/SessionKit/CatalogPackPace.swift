import Foundation

/// How often a source publishes, counted on the phone from the publish dates the catalog carries (#4285).
/// Counting only: no feed is fetched, and the phone's own stored feed history is never mixed in (it keeps 25 entries
/// plus tombstones, which would make a daily show read low and make a card's number jump when a follow lands).
public enum CatalogPackPace {
    /// What was measured. `itemsPerWeek` is the rate over the window below; `newestIsStale` says the newest date is
    /// more than 90 days before the as-of moment.
    public struct Measure: Equatable, Sendable {
        public var itemsPerWeek: Double
        public var newestIsStale: Bool

        public init(itemsPerWeek: Double, newestIsStale: Bool) {
            self.itemsPerWeek = itemsPerWeek
            self.newestIsStale = newestIsStale
        }
    }

    static let day: TimeInterval = 86_400
    static let windowDays = 56.0
    static let minimumWindowDays = 7.0
    static let staleDays = 90.0

    /// The rate for one source, or nil when it can't be told: no usable as-of moment, or fewer than 2 dates on or
    /// before it.
    ///
    /// Window: dates on or before `asOf` are kept. The window starts at the later of `asOf` minus 56 days and the
    /// oldest kept date, and is at least 7 days long. The rate is the kept dates inside the window times 7, over
    /// the window's length in days.
    public static func measure(recentPublishedDates dates: [Date], asOf: Date?) -> Measure? {
        guard let asOf else { return nil }
        let kept = dates.filter { $0 <= asOf }
        guard kept.count >= 2, let oldest = kept.min(), let newest = kept.max() else { return nil }
        let start = max(asOf.addingTimeInterval(-windowDays * day), oldest)
        let lengthDays = max(minimumWindowDays, asOf.timeIntervalSince(start) / day)
        let inWindow = kept.filter { $0 >= start }.count
        return Measure(
            itemsPerWeek: Double(inWindow) * 7 / lengthDays,
            newestIsStale: asOf.timeIntervalSince(newest) > staleDays * day
        )
    }

    /// The rate for a catalog entry, as of the catalog's own `generatedAt`.
    public static func measure(for entry: SourceCatalogEntry, in catalog: SourceCatalog) -> Measure? {
        measure(recentPublishedDates: entry.recentPublishedDates, asOf: catalog.generatedAtDate)
    }

    /// A pack's rate: the sum over its visible sources whose rate is known, or nil when fewer than half of them
    /// are known. It is stale only when every known source is.
    public static func packMeasure(_ sources: [Measure?]) -> Measure? {
        let known = sources.compactMap { $0 }
        guard !sources.isEmpty, known.count * 2 >= sources.count, !known.isEmpty else { return nil }
        return Measure(itemsPerWeek: known.reduce(0) { $0 + $1.itemsPerWeek }, newestIsStale: known.allSatisfy(\.newestIsStale))
    }

    /// The words on a pack card: "About 2 new a day", "About one new a week", "Now and then", or
    /// "Pace not known yet".
    public static func packWords(_ measure: Measure?) -> String {
        guard let measure, measure.itemsPerWeek.isFinite else { return "Pace not known yet" }
        return words(measure, rowStyle: false) ?? "Pace not known yet"
    }

    /// The words on a source row: "About 3 a week". Nil when the pace is unknown, so the row leaves it out.
    public static func rowWords(_ measure: Measure?) -> String? {
        guard let measure, measure.itemsPerWeek.isFinite else { return nil }
        return words(measure, rowStyle: true)
    }

    private static func words(_ measure: Measure, rowStyle: Bool) -> String? {
        let rate = measure.itemsPerWeek
        let new = rowStyle ? "" : " new"
        if measure.newestIsStale || rate < 0.2 { return "Now and then" }
        switch rate {
        case 10.5...:
            return "About \(count(Int((rate / 7).rounded())))\(new) a day"
        case 6.5..<10.5:
            return "About one\(new) a day"
        case 1.5..<6.5:
            return "About \(count(Int(rate.rounded())))\(new) a week"
        case 0.75..<1.5:
            return "About one\(new) a week"
        default:
            return "About \(count(max(1, Int((rate * 52 / 12).rounded()))))\(new) a month"
        }
    }

    /// 1 reads "one".
    private static func count(_ number: Int) -> String { number == 1 ? "one" : String(number) }
}
