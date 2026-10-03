import Foundation

extension Interjection {
    /// Before #624, spoken Margins stored a counter as their date: one second after 1970 for the
    /// session's first Margin, two for the second, and so on. Anything earlier than this is one of those.
    public static let placeholderDateCutoff = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01

    /// When the Margin was recorded, for anything that shows or sends the date. A stored counter is read
    /// as the session's start plus that many seconds, which lands on the right day and keeps the
    /// session's Margins in order, without rewriting the stored record.
    public func recordedAt(in session: Session?) -> Date {
        guard createdAt < Self.placeholderDateCutoff, let start = session?.createdAt else { return createdAt }
        return start.addingTimeInterval(createdAt.timeIntervalSince1970)
    }
}
