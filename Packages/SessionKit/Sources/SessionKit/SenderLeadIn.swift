import Foundation

/// The sender's choice of how much of the episode a friend hears before a Margin (#4171). The packet carries it as an
/// optional `leadInMs` on the Margin's record. Everything about that field's rules lives here, so the writer, the reader
/// and the tests read one definition.
public enum SenderLeadIn {
    /// The receiving lead-in when the sender chose nothing (20 s, owner's call 2026-10-31, #3059). A sender who picks
    /// this length writes nothing, so a packet that changes nothing stays byte for byte what older builds write.
    public static let defaultMs = 20_000

    /// What a reader accepts: 0 to 5 minutes. The sender's menu will offer 5 s to 2 min; the writer itself passes on
    /// anything a reader would accept.
    public static let range: ClosedRange<Int> = 0...300_000

    public static func clamped(_ ms: Int) -> Int {
        min(max(ms, range.lowerBound), range.upperBound)
    }

    /// The length the sender's share sheet starts a Margin at: the length its newest share wrote, else the default. A stored
    /// length is clamped to what a reader accepts, so a hand-edited or future value can't start the sheet outside it.
    public static func startingMs(lastSent: Int?) -> Int {
        lastSent.map(clamped) ?? defaultMs
    }

    /// The value to write on a Margin's record, or nil to write no key.
    ///
    /// - A length other than the default is written.
    /// - The default is written out loud only when an earlier share of this Margin used another length: a missing key
    ///   can't tell the friend's held copy to come back to 20 s, so the sender taking a length back has to say it.
    /// - Otherwise nothing is written.
    ///
    /// `chosen` nil means the sender chose nothing (the default); `previous` nil means this Margin was never shared with
    /// a length. Both are clamped first, so the rule compares what a reader would see.
    public static func valueToWrite(chosen: Int?, previous: Int?) -> Int? {
        let now = chosen.map(clamped) ?? defaultMs
        if now != defaultMs { return now }
        if let previous, clamped(previous) != defaultMs { return defaultMs }
        return nil
    }
}
