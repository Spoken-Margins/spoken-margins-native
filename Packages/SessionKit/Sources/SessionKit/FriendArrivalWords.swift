import Foundation

/// The words a friend reads on the screens that show a file's Margins after it arrived (#3247, step 5 of the rebuild).
///
/// The owner reviewed these lines on the step 5 words page: Cole's name leads ("From Cole", "your friend" when no name
/// is known), "Margin" is the one word for what Cole left, and "layer", "package", "source", "integrity" and
/// "cryptographically" never reach a friend. What passes silently stays silent; what is honest ("the name isn't
/// proven") moves under "About this file". The words live here so the host can test them and the views only draw them.
public enum FriendArrivalWords {
    /// "From Cole", or "From a friend" when the file names nobody (the item screen's sender line says the same).
    public static func fromLine(senderLabel: String?) -> String {
        "From \(SharedPacketArrival.name(senderLabel) ?? "a friend")"
    }

    /// One title for a list of friends' Margins: "From Cole" when one friend sent them, "From friends" otherwise.
    public static func sectionTitle(senderLabels: [String]) -> String {
        let named = Set(senderLabels.compactMap { SharedPacketArrival.name($0) })
        let unnamed = senderLabels.contains { SharedPacketArrival.name($0) == nil }
        if named.count == 1, !unnamed, let name = named.first { return "From \(name)" }
        return senderLabels.count > 1 ? "From friends" : "From a friend"
    }

    /// The Lock Screen's artist line while a friend's Margin plays: the name, or "A friend". The prompt carries the
    /// stored stand-in "Unsigned sender" for a file that named nobody, which must never reach the Lock Screen (#3247).
    public static func nowPlayingArtist(senderLabel: String?) -> String {
        SharedPacketArrival.name(senderLabel) ?? "A friend"
    }

    /// "Shared Margin from Cole" on the Live Activity, which says "a friend" when the file named nobody (#3247).
    public static func liveActivitySender(senderLabel: String?) -> String {
        SharedPacketArrival.name(senderLabel) ?? "a friend"
    }

    /// Possessive for control names: "Cole's Margins", "Your friend's Margins".
    public static func possessiveMargins(senderLabel: String?) -> String {
        "\(SharedPacketArrival.name(senderLabel).map { "\($0)'s" } ?? "Your friend's") Margins"
    }

    /// The honest note, shown only under "About this file": the file is unchanged, the name isn't proven.
    /// What "Hide this sender" tells the listener before it hides (#2846). It says where it applies and that nothing is lost.
    public static let hideSenderMessage =
        "Their Margins will disappear from every list and from playback on this phone. Nothing is deleted, and you can show them again in Settings."

    /// What "Hide this Margin" tells the listener before it hides one Margin (#2846): the same promise, for one.
    public static let hideMarginMessage =
        "This Margin will disappear from every list and from playback on this phone. Nothing is deleted, and you can show it again in Settings."

    /// The Settings row for a Margin hidden on its own: its first words, or that it had none to show.
    public static func hiddenMarginName(_ margin: HiddenSenders.HiddenMargin) -> String {
        margin.snippet.isEmpty ? "A Margin with no words" : "\u{201C}\(margin.snippet)\u{201D}"
    }

    /// Who the hidden Margin was from, under its words.
    public static func hiddenMarginSender(_ margin: HiddenSenders.HiddenMargin) -> String {
        "From \(hiddenSenderName(margin.senderLabel))"
    }

    /// The Settings row for a hidden sender: who it was, or that the sender never gave a name.
    public static func hiddenSenderName(_ displayLabel: String?) -> String {
        SharedPacketArrival.name(displayLabel) ?? "A sender who gave no name"
    }

    public static let aboutTitle = SharedPacketArrival.aboutTitle
    public static let aboutNote = SharedPacketArrival.aboutIntegrity

    /// How a friend's Margins reach the listener. The two named states are the reviewed words for the auto-play
    /// switch ("Play Margins from friends as you reach them", "Off: a tone marks each one"). `fresh` has no reviewed
    /// words: the episode never offers its Margins, so it reads "Only when you ask" (a stand-in until the owner picks).
    public static func playModeLabel(_ mode: ImportedCommentaryRevealMode) -> String {
        switch mode {
        case .guided: "Play as you reach them"
        case .companion: "A tone marks each one"
        case .fresh: "Only when you ask"
        }
    }

    /// The name of the control that picks the play mode.
    public static let playModeTitle = "When Margins play"

    /// A plain sentence for the one placement problem a listener can act on: the file isn't this episode or article.
    /// Every other state says nothing here; each Margin's own row says where it plays (#3789).
    public static func placementProblem(_ status: ImportedSourceResolutionStatus) -> String? {
        switch status {
        case .wrongSource: "This may not be the same episode or article these Margins were made on."
        case .resolved, .pending, .contextOnly, .ambiguous, .unavailable: nil
        }
    }

    /// What VoiceOver says for one friend's layer, in the friend's words and without a passing integrity check.
    public static func layerAccessibilityLabel(
        senderLabel: String, isEnabled: Bool, isMuted: Bool, mode: ImportedCommentaryRevealMode,
        placementProblem: String?
    ) -> String {
        var parts = [
            fromLine(senderLabel: senderLabel),
            isEnabled ? "\(possessiveMargins(senderLabel: senderLabel)) are on" : "\(possessiveMargins(senderLabel: senderLabel)) are off",
            isMuted ? "Muted" : "Not muted",
            "\(playModeTitle): \(playModeLabel(mode))"
        ]
        if let placementProblem { parts.append(placementProblem) }
        return parts.joined(separator: ". ")
    }
}
