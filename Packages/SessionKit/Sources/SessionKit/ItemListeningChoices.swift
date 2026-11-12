import Foundation

/// What the item screen offers for starting to listen, and what each control is called (#3219).
///
/// An item with Margins a friend sent that the listener hasn't heard used to offer four ways in: a button reading
/// "Continue" (or "Start listening", "Replay", "Listen now"), a "New Margins to hear" dialog behind it, and
/// "Review new Margins" and "Review Margins" side by side. A friend who had just imported a packet could not tell
/// which to tap (owner, 2026-11-02). With unheard friend Margins the screen now offers two choices whose words never
/// change: "Play", the episode with the Margins playing in place (the 2026-10-31 call, #3059), or
/// "Skip to Cole's Margins · 3 min", each Margin with its lead-in. The words are the ones the owner reviewed on the
/// #3247 screens; the length came from the blind test there, where newcomers asked how long the Margins take.
/// Everything else keeps today's single button and words.
public struct ItemListeningChoices: Equatable, Sendable {
    public static let playTitle = "Play"

    /// One unheard friend Margin, as much of it as the choices need.
    public struct WaitingMargin: Equatable, Sendable {
        /// The name the sender's packet carries; empty when it carries none.
        public let senderName: String
        /// The recording's length, or nil for a written Margin, which the on-device voice reads aloud.
        public let audioDurationMs: Int?
        /// The words a written Margin is read from.
        public let transcript: String

        public init(senderName: String, audioDurationMs: Int?, transcript: String) {
            self.senderName = senderName
            self.audioDurationMs = audioDurationMs
            self.transcript = transcript
        }
    }

    /// The big button's words.
    public let primaryTitle: String
    /// The second choice's words. Nil when the item has no unheard friend Margins, so there is nothing to choose.
    public let marginsOnlyTitle: String?
    /// What VoiceOver reads for the second choice: whose Margins, how many, and about how long.
    public let marginsOnlyAccessibilityLabel: String?

    /// - Parameters:
    ///   - unheardFriendMargins: the friend Margins on this item that the listener can hear and hasn't.
    ///   - hasFinishedSession: the item's session reached its end, so the plain button says "Replay".
    ///   - hasContinuationSession: the item has a session to carry on, so the plain button says "Continue".
    ///   - isPreparingAudio: the item's audio is still being made or fetched, so the plain button says "Listen now".
    public init(
        unheardFriendMargins: [WaitingMargin],
        hasFinishedSession: Bool,
        hasContinuationSession: Bool,
        isPreparingAudio: Bool
    ) {
        if !unheardFriendMargins.isEmpty {
            // The same words whether or not the episode was heard, started or is still being prepared: the two
            // choices describe what will play, not where the listener is in the item.
            let whose = Self.whoseMargins(unheardFriendMargins)
            let minutes = Self.marginsOnlyMinutes(unheardFriendMargins)
            let count = unheardFriendMargins.count
            primaryTitle = Self.playTitle
            marginsOnlyTitle = "Skip to \(whose) · \(minutes) min"
            marginsOnlyAccessibilityLabel = "Skip to \(whose), \(count) new Margin\(count == 1 ? "" : "s"), "
                + "about \(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            if isPreparingAudio {
                primaryTitle = "Listen now"
            } else if hasFinishedSession {
                primaryTitle = "Replay"
            } else {
                primaryTitle = hasContinuationSession ? "Continue" : "Start listening"
            }
            marginsOnlyTitle = nil
            marginsOnlyAccessibilityLabel = nil
        }
    }

    /// "Cole's Margins" when one named friend sent them all; "the Margins" for several friends or none named.
    static func whoseMargins(_ margins: [WaitingMargin]) -> String {
        let names = Set(margins.map { $0.senderName.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard names.count == 1, let name = names.first, !name.isEmpty else { return "the Margins" }
        return "\(name)'s Margins"
    }

    /// How long "Skip to …" takes, in whole minutes and never under one: each Margin, written ones at the on-device
    /// voice's pace, plus the review's lead-in before each.
    static func marginsOnlyMinutes(_ margins: [WaitingMargin]) -> Int {
        let leadInMs = ListeningMoment.rule(for: .reviewNewMargins).leadInMs
        let totalMs = margins.reduce(0) { sum, margin in
            sum + leadInMs + max(0, margin.audioDurationMs ?? spokenLengthMs(of: margin.transcript))
        }
        return max(1, Int((Double(totalMs) / 60_000).rounded()))
    }

    /// About 2.5 words a second, the on-device voice's ordinary pace.
    static func spokenLengthMs(of text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return words * 400
    }
}

extension SharedMarginReview.Entry {
    /// This Margin as the item screen's choices see it (#3219).
    public var waitingMargin: ItemListeningChoices.WaitingMargin {
        ItemListeningChoices.WaitingMargin(
            senderName: layer.displayLabel ?? "",
            audioDurationMs: interjection.audioDurationMs,
            transcript: interjection.approvedTranscript
        )
    }
}
