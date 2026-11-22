import Foundation

/// The one formatter for the times follow lists and rules show (#4046, reused by #4050): "today at 3:05 PM",
/// "yesterday at 9:12 AM", "Nov 13". A date in another year carries the year ("Nov 13, 2025"), so an old date
/// isn't taken for a recent one.
public enum ListStatusWords {
    public static func time(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        func shortTime() -> String {
            FollowingDateFormatters.shared.string(from: date, template: "jm", calendar: calendar, locale: locale)
        }
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(shortTime())" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(shortTime())"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return FollowingDateFormatters.shared.string(
            from: date, template: sameYear ? "MMMd" : "yMMMd", calendar: calendar, locale: locale
        )
    }
}
