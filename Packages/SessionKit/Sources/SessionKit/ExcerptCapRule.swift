import Foundation

/// How much source text travels around a shared Margin: one rule for the link packet's context fields ("Context
/// before", "Exact excerpt", "Context after") and for the share page's preview, so a packet and its preview built
/// from the same Margins carry the same text (#2237).
///
/// The numbers are the owner's D16 starting caps (2026-10-20, `docs/legal/attorney-questions.md`); the attorney
/// may mark them up, so they live here and nowhere else.
///
/// - After the Margin: at most `afterMaximum` characters.
/// - Before the Margin: three times the comment's length, at least `beforeMinimum` and at most `beforeMaximum`.
/// - The comment's length is its transcript's length, else about `charactersPerRecordedSecond` per second recorded.
///
/// Characters are Swift `Character`s (grapheme clusters). A trimmed excerpt also never holds more Unicode scalars
/// than its cap, so a server that counts code points (the share page's) agrees with the app.
public enum ExcerptCapRule {
    public static let afterMaximum = 120
    public static let beforeMinimum = 280
    public static let beforeMultiplier = 3
    /// The owner's ceiling for the "before" side.
    public static let beforeScaleMaximum = 800
    public static let charactersPerRecordedSecond = 15

    /// Builds 32 and 34 reject a packet whose prefix or suffix runs over `BoundedAnchorContext.maximumCharactersPerSide`
    /// (see `ShippedReaderGateTests`), and packets from a new build must import there. So the "before" side stops at
    /// that limit, not at `beforeScaleMaximum`, until those builds are retired; then this line is the one to change.
    public static let beforeMaximum = min(beforeScaleMaximum, BoundedAnchorContext.maximumCharactersPerSide)

    /// The comment's length for the cap: its transcript when it has one, else an estimate from the recording.
    public static func commentLength(transcript: String?, recordingSeconds: Double? = nil) -> Int {
        let words = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !words.isEmpty { return words.count }
        guard let seconds = recordingSeconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * Double(charactersPerRecordedSecond)).rounded())
    }

    public static func beforeCap(commentLength: Int) -> Int {
        let scaled = max(0, commentLength) * beforeMultiplier
        return min(beforeMaximum, max(beforeMinimum, scaled))
    }

    /// The source text either side of a Margin, whitespace collapsed, each side cut to its cap at a word boundary.
    public static func select(before: String, after: String, commentLength: Int) -> BoundedAnchorContext {
        BoundedAnchorContext(
            before: trimmedBefore(BoundedAnchorContext.normalizedWhitespace(before), cap: beforeCap(commentLength: commentLength)),
            after: trimmedAfter(BoundedAnchorContext.normalizedWhitespace(after), cap: afterMaximum)
        )
    }

    /// Keeps the end of `text` (the words nearest the Margin). A cut that lands inside a word drops that word's
    /// partial start, unless the whole cap is one long word.
    public static func trimmedBefore(_ text: String, cap: Int) -> String {
        let kept = hardLimit(text, cap: cap, keepingEnd: true)
        guard kept.count < text.count, let first = kept.first, !first.isWhitespace,
              let cutAfter = text.dropLast(kept.count).last, !cutAfter.isWhitespace,
              let space = kept.firstIndex(where: \.isWhitespace) else { return kept }
        return String(kept[kept.index(after: space)...])
    }

    /// Keeps the start of `text`; a cut inside a word drops that word's partial end.
    public static func trimmedAfter(_ text: String, cap: Int) -> String {
        let kept = hardLimit(text, cap: cap, keepingEnd: false)
        guard kept.count < text.count, let last = kept.last, !last.isWhitespace,
              let cutBefore = text.dropFirst(kept.count).first, !cutBefore.isWhitespace,
              let space = kept.lastIndex(where: \.isWhitespace) else { return kept }
        return String(kept[..<space])
    }

    /// The plain cut, no word handling: `cap` characters and no more than `cap` Unicode scalars. What a sender's own
    /// edit of the context is held to.
    public static func hardLimit(_ text: String, cap: Int, keepingEnd: Bool) -> String {
        var kept = Substring(keepingEnd ? text.suffix(max(0, cap)) : text.prefix(max(0, cap)))
        while kept.unicodeScalars.count > max(0, cap) {
            if keepingEnd { kept = kept.dropFirst() } else { kept = kept.dropLast() }
        }
        return String(kept)
    }
}
