import Foundation

/// The words a listener reads when a Margin answers a friend's (#3890): who is being answered, how the Margin is
/// named when it has no words, and the two ends of the "stop replying" control.
///
/// Display only. A sender with no name is "Someone" in stored and encoded labels (`MarginLayerSynthesis.unnamedSenderLabel`),
/// and older drafts and data keep matching it; this turns it into "a friend" at the moment a screen shows it.
public enum MarginReplyWords {
    /// What a sender with no name is called on screen. The owner accepted it for the Lock Screen (2026-11-09).
    public static let unnamedSender = "a friend"
    public static let stopReplyingTitle = "Stop replying"
    public static let notAReply = "Not a reply"
    /// What the writing screen asks when the sender has no name to put in "What do you want to say to …?".
    public static let sayBackPrompt = "What do you want to say back?"

    /// The longest excerpt of the answered Margin's words a caption quotes, in characters.
    public static let excerptLimit = 90

    /// The sender's name as written, or nil when the label stands in for a missing name: blank, "Someone", "Unsigned
    /// sender" and "Imported collection", in any case, spacing or accents.
    public static func senderName(_ label: String?) -> String? {
        guard let name = SharedPacketArrival.senderName(label) else { return nil }
        let folded = fold(name)
        return folded == fold(MarginLayerSynthesis.unnamedSenderLabel) ? nil : name
    }

    /// "Sam", or "a friend" for a sender with no name. For the middle of a line.
    public static func name(_ label: String?) -> String { senderName(label) ?? unnamedSender }

    /// "Sam's", or "a friend's".
    public static func possessive(_ label: String?) -> String { senderName(label).map { "\($0)'s" } ?? "\(unnamedSender)'s" }

    /// "Sam", or "A friend". For a line that starts with it.
    public static func heading(_ label: String?) -> String { senderName(label) ?? "A friend" }

    /// The line over a Margin being recorded or written that answers a shared Margin whose words are `parentText`.
    ///
    /// With words: `Replying to Sam: “first words…”`. With none (a voice Margin sent without a transcript, whose words are
    /// the stand-in `SharedMarginPlaceholderWords` recognises): `Replying to Sam's Margin at 1:45`, or without the time when the
    /// sender's isn't known. Never the stand-in itself, and never a quote inside the quote.
    public static func replyingCaption(senderLabel: String?, parentText: String, parentTimeMs: Int?) -> String {
        guard let excerpt = excerpt(of: parentText) else {
            let time = parentTimeMs.map { " at \(clock(milliseconds: $0))" } ?? ""
            return "Replying to \(possessive(senderLabel)) Margin\(time)"
        }
        return "Replying to \(name(senderLabel)): \u{201C}\(excerpt)\u{201D}"
    }

    /// The words to quote on one line, or nil when there are none worth quoting: blank, or the stand-in for a voice
    /// Margin. Double quotes inside become single ones so the caption never nests them; cut at `excerptLimit`.
    public static func excerpt(of text: String) -> String? {
        // Invisible format characters (zero-width space, BOM) count as nothing, like whitespace.
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let line = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, !SharedMarginPlaceholderWords.matches(line) else { return nil }
        let flattened = String(line.map { character -> Character in
            switch character {
            case "\u{201C}": return "\u{2018}"
            case "\u{201D}": return "\u{2019}"
            case "\"": return "'"
            default: return character
            }
        })
        guard flattened.count > excerptLimit else { return flattened }
        let kept = String(flattened.prefix(excerptLimit)).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    /// The player clock the stand-in uses: `m:ss`, or `h:mm:ss` from an hour. Partial seconds are dropped.
    public static func clock(milliseconds: Int) -> String {
        let whole = max(0, milliseconds) / 1000
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let seconds = whole % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(seconds))" : "\(minutes):\(two(seconds))"
    }

    private static func fold(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
