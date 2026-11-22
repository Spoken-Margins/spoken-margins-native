import Foundation

/// Whether the listener's copy of a podcast episode is a different length from the sender's, and by how much
/// (#4175, #4614). A podcast with dynamic ads is a different file on each request, and a Margin that carries only the
/// sender's clock time lands that far from its words in a copy that differs. This is the app's half of one rule: the
/// web has the same rule in `Web/src/app/logic/copy-length.ts`, and both read their cases from
/// `Contracts/fixtures/copy-length-note/cases.json`, so the two never disagree on one packet. Whole milliseconds and
/// integer arithmetic only, so no float lands on the wrong side of a boundary.
///
/// This only warns. It never moves a Margin: placement discards the lengths on purpose, because equal lengths can
/// conceal offsetting insertions and deletions (`PodcastAnchorEvidence.swift`).
public struct CopyLengthDifference: Equatable, Sendable {
    public enum Direction: String, Sendable { case shorter, longer }

    /// Whether the listener's copy is shorter or longer than the sender's.
    public let direction: Direction
    /// More than 20% of the longer copy apart: a number of minutes would promise an offset that isn't there.
    public let farApart: Bool
    /// "about 35 seconds" or "about 3 minutes".
    public let amount: String

    /// A length difference under this is not worth a word: it leaves room for how two players measure one file.
    static let minimumDifferenceMs = 10_000
    /// A length above this (about 31 years) is no episode: a packet carries any integer, and the arithmetic below
    /// would trap on one near `Int.max`. No note is better than a crash on opening a Margin.
    static let ceilingMs = 1_000_000_000_000
    /// Below this many seconds the amount is said in seconds, rounded to 5; from here, in whole minutes.
    static let minutesFromSeconds = 120

    /// Nil for no note: either length missing, not above zero or absurdly long, or the copies within 10 s of each other.
    public init?(senderMs: Int?, listenerMs: Int?) {
        guard let sender = senderMs, sender > 0, sender <= Self.ceilingMs,
              let listener = listenerMs, listener > 0, listener <= Self.ceilingMs else { return nil }
        let apart = abs(listener - sender)
        guard apart >= Self.minimumDifferenceMs else { return nil }
        direction = listener < sender ? .shorter : .longer
        // More than 20% of the longer copy: the app's own "same episode" test (`SharedEpisodeFeedMatcher`).
        farApart = 5 * apart > max(sender, listener)
        let seconds = max(10, ((apart + 2_500) / 5_000) * 5)
        amount = seconds < Self.minutesFromSeconds
            ? "about \(seconds) seconds"
            : "about \((apart + 30_000) / 60_000) minutes"
    }
}
