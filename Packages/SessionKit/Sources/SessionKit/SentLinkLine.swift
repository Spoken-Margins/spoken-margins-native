import Foundation

/// The line under an item's heading on the sender's Margins tab (#5275, Screen A): "Link sent today", and
/// "Link sent today · Opened" once a friend opened it. It never says "not opened": a silent line can't read as
/// a nudge to the friend.
public struct SentLinkLine: Equatable, Sendable {
    /// What the line shows. With `showsOpenedIcon`, the app draws an open envelope before the part after " · ".
    public let text: String
    public let accessibilityLabel: String
    public let showsOpenedIcon: Bool

    /// The line for one item's records, or nil when none is live. With the switch off, "Opened" is never shown,
    /// even for a record already seen opened.
    public static func make(records: [SentShareLink], receiptsOn: Bool, now: Date,
                            calendar: Calendar = .current, locale: Locale = .current) -> SentLinkLine? {
        let live = records.filter { $0.isLive(at: now) }
        guard let newest = live.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let opened = receiptsOn ? live.filter(\.opened).count : 0
        if live.count == 1 {
            let (shown, spoken) = sentWords(newest.createdAt, now: now, calendar: calendar, locale: locale)
            if opened == 1 {
                return SentLinkLine(text: "Link sent \(shown) · Opened", accessibilityLabel: "Link sent \(spoken). Opened.", showsOpenedIcon: true)
            }
            return SentLinkLine(text: "Link sent \(shown)", accessibilityLabel: "Link sent \(spoken).", showsOpenedIcon: false)
        }
        let sent = "\(live.count) links sent"
        switch opened {
        case 0:
            return SentLinkLine(text: sent, accessibilityLabel: "\(sent).", showsOpenedIcon: false)
        case live.count:
            return SentLinkLine(text: "\(sent) · all opened", accessibilityLabel: "\(sent), all opened.", showsOpenedIcon: true)
        default:
            return SentLinkLine(text: "\(sent) · \(opened) opened", accessibilityLabel: "\(sent), \(opened) opened.", showsOpenedIcon: true)
        }
    }

    /// "today", "yesterday", "Nov 24", or "Nov 24, 2025" when not this year; spoken with the month in full.
    static func sentWords(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> (shown: String, spoken: String) {
        if calendar.isDate(date, inSameDayAs: now) { return ("today", "today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return ("yesterday", "yesterday")
        }
        let thisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        return thisYear ? (format("MMMd"), format("MMMMd")) : (format("MMMdy"), format("MMMMdy"))
    }
}
