import Foundation

/// When the Share sheet asks "Clean selected Margins automatically?" (#3792, Design 2026-11-10, piece 4).
///
/// The question is a first-run one, so it asks only while it can be true and useful: no decision is recorded, the sheet is
/// an ordinary share (the reply sheet is a receipt, and the "Clean selected automatically" toggle on the selection step
/// stays the way to turn cleanup on from there), and at least one included Margin could be cleaned. A friend who never
/// records with speech recognition, so whose Margins have no word-level timing, is never asked about something that
/// could do nothing for them.
public enum ShareAutoCleanQuestion {
    public static func asks(hasRecordedDecision: Bool, isReplyBack: Bool, anyIncludedCanBeCleaned: Bool) -> Bool {
        !hasRecordedDecision && !isReplyBack && anyIncludedCanBeCleaned
    }
}
