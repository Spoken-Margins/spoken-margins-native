import Foundation
import SessionKit

/// Placeholder words for a voice Margin that has none of its own (#3027), in the web app's format (#3025).
///
/// Every packet reader back to Build 29 rejects an empty transcript (`SharedMarginTextRequirement`, #304), and a
/// voice Margin whose transcription failed, is still running, or never ran has no words. So it travels with these
/// instead, in the existing transcript field: what it is, where, and when. The packet gains no key.
/// Owner, 2026-10-30: "can it just be the title of the item they're listening to and the timestamp and the date?"
///
/// The words say plainly that they are a stand-in ("Voice Margin at …"), so a friend never reads them as the
/// sender's own. The web app writes the same text for the same Margin (`Web/src/shared/placeholder.ts`).
public enum SharedMarginPlaceholder {
    /// The longest item title the placeholder quotes, in characters (grapheme clusters), ellipsis included.
    public static let titleCharacterLimit = 80

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `Voice Margin at 12:34 in “Title”, recorded 30 Oct 2026`. Without a media time (an article) the "at" part is
    /// left out; without a title, the "in" part; without a date, the "recorded" part.
    public static func words(mediaTimeMs: Int?, itemTitle: String?, recordedAt: Date?, timeZone: TimeZone = .current) -> String {
        var text = "Voice Margin"
        if let mediaTimeMs { text += " at \(clock(milliseconds: mediaTimeMs))" }
        let title = title(itemTitle)
        if !title.isEmpty { text += " in “\(title)”" }
        if let recordedAt { text += ", recorded \(date(recordedAt, timeZone: timeZone))" }
        return text
    }

    /// The placeholder for this Margin, or `nil` when it needs none: it has words of its own (they always win), it
    /// is a written Margin, or it carries no voice (a Margin with neither words nor voice can't travel at all).
    public static func words(
        for interjection: Interjection,
        itemTitle: String?,
        hasVoice: Bool,
        timeZone: TimeZone = .current
    ) -> String? {
        guard hasVoice, interjection.captureKind != .written,
              !SharedMarginTextRequirement.hasReviewedText(SharedMarginTextRequirement.initialReviewedText(for: interjection))
        else { return nil }
        return words(
            mediaTimeMs: interjection.anchor.mediaTimeMs,
            itemTitle: itemTitle,
            recordedAt: interjection.createdAt,
            timeZone: timeZone
        )
    }

    /// The title on one line, in composed Unicode, cut at a whole character with "…" when longer than `limit`.
    public static func title(_ title: String?, limit: Int = titleCharacterLimit) -> String {
        let line = (title ?? "").precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard line.count > limit else { return line }
        let kept = String(line.prefix(max(0, limit - 1)))
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "30 Oct 2026": day, English month abbreviation and year, on the listener's calendar day. No numeric order to
    /// misread.
    public static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        return "\(parts.day ?? 1) \(months[((parts.month ?? 1) - 1 + 12) % 12]) \(parts.year ?? 0)"
    }

    /// The player clock: `m:ss`, or `h:mm:ss` from an hour. Partial seconds are dropped, as the player shows them.
    public static func clock(milliseconds: Int) -> String {
        let whole = max(0, milliseconds) / 1000
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let seconds = whole % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(seconds))" : "\(minutes):\(two(seconds))"
    }
}
