import Foundation

/// The top of an item's screen while a friend's Margins wait to be heard (#3219, slice 1 of #3247): who sent them,
/// how many and how long, and the one line that says what a Margin is.
///
/// A friend arriving from Cole's file has never seen the app. The #3247 screens the owner reviewed open with
/// "From Cole", then the title, then "3 Margins · about 2 min" and the explanation. The explanation has two versions
/// (owner, 2026-11-02, "Two versions"): "voice note" when every Margin is spoken, and a plain "note" when any is
/// written, because the on-device voice reads written ones and "voice note" would suggest Cole's own voice.
public struct FriendMarginsIntro: Equatable, Sendable {
    /// "From Cole", or "From a friend" when the packet carries no single name.
    public let senderLine: String
    /// "3 Margins · about 2 min": the Margins alone, without the lead-ins "Skip to …" adds.
    public let countLine: String
    /// What a Margin is, once, in the version that fits these Margins.
    public let explanation: String

    /// Nil when no friend Margins wait, so the screen shows nothing new.
    public init?(unheardFriendMargins margins: [ItemListeningChoices.WaitingMargin]) {
        guard !margins.isEmpty else { return nil }
        let name = Self.singleName(margins)
        senderLine = "From \(name ?? "a friend")"

        let totalMs = margins.reduce(0) { sum, margin in
            sum + max(0, margin.audioDurationMs ?? ItemListeningChoices.spokenLengthMs(of: margin.transcript))
        }
        let minutes = max(1, Int((Double(totalMs) / 60_000).rounded()))
        countLine = "\(margins.count) Margin\(margins.count == 1 ? "" : "s") · about \(minutes) min"

        let who = name ?? "your friend"
        let anyWritten = margins.contains { $0.audioDurationMs == nil }
        explanation = anyWritten
            ? "A Margin is a note \(who) left at a moment in this episode. You'll hear each one there."
            : "A Margin is a voice note \(who) left at a moment in this episode."
    }

    /// The one sender's name, or nil for several senders or none named.
    static func singleName(_ margins: [ItemListeningChoices.WaitingMargin]) -> String? {
        let names = Set(margins.map { $0.senderName.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard names.count == 1, let name = names.first, !name.isEmpty else { return nil }
        return name
    }
}
