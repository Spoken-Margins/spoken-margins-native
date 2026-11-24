import Foundation

/// The sender's "Before your Margin" row in the share review (#4171, PR 4b of the Design): the menu of lengths, its words,
/// and what "Hear it as your friend will" plays. The app draws it and plays it; every rule about it lives here, so the
/// tests read one definition.
public enum SenderLeadInPreview {
    // MARK: The menu

    /// The seven lengths the menu offers (Design, Default taken 1 and 2). 20 sec is the default (#3059).
    public static let presetsMs = [5_000, 10_000, 20_000, 30_000, 45_000, 60_000, 120_000]

    /// What the menu lists: the presets, plus the Margin's current length when it is none of them (a length remembered
    /// from an older share, or one a later build offered), so the menu always shows the value the packet would carry.
    public static func choicesMs(current: Int) -> [Int] {
        let value = SenderLeadIn.clamped(current)
        return presetsMs.contains(value) ? presetsMs : (presetsMs + [value]).sorted()
    }

    /// "20 sec of the episode", "1 min of the episode", "1 min 30 sec of the episode".
    public static func choiceLabel(_ ms: Int) -> String {
        "\(lengthWords(ms)) of the episode"
    }

    static func lengthWords(_ ms: Int) -> String {
        let seconds = Int((Double(SenderLeadIn.clamped(ms)) / 1_000).rounded())
        let minutes = seconds / 60, rest = seconds % 60
        switch (minutes, rest) {
        case (0, _): return "\(rest) sec"
        case (_, 0): return "\(minutes) min"
        default: return "\(minutes) min \(rest) sec"
        }
    }

    // MARK: Words

    public static let rowLabel = "Before your Margin"
    public static let caption = "Your friend hears this much of the episode first, then your Margin."
    public static let previewButton = "Hear it as your friend will"
    public static let stopButton = "Stop"
    public static let momentPendingCaption = "Available once the exact moment is found."
    public static let failureCaption = "Couldn't play this part of the episode. It needs the episode downloaded, or a connection."

    /// What the sender's preview can't play for a Margin that goes as words: the friend's phone reads them, or the
    /// friend reads them. Nil for a voice, which the preview plays after the chime.
    public static func afterRunUpCaption(goesAsWords: Bool, readAloud: Bool) -> String? {
        guard goesAsWords else { return nil }
        return readAloud ? "Then their phone reads your words." : "Then they read your words."
    }

    // MARK: Whether the row shows, and whether its button works

    /// The row shows only for a Margin on an episode or audio file with a place in it: nothing else has a run-up.
    public static func showsRow(isNativeAudio: Bool, hasPlace: Bool, marginPositionMs: Int?) -> Bool {
        isNativeAudio && hasPlace && marginPositionMs != nil
    }

    /// The button is off while this Margin's moment is still being found (#3839): the preview would pause the episode
    /// and stop that sample.
    public static func previewIsAvailable(_ margin: ShareReviewSteps.Margin) -> Bool {
        !margin.waitsOnMoment
    }

    // MARK: What plays

    /// The stretch of the episode the preview plays before the chime: from where the friend's review starts it to the
    /// Margin. It is the friend's own rule (`ListeningMoment`, `reviewNewMargins`, the sender's length), with no
    /// previous-Margin clamp, because the review machinery applies none (Design, §2 and Default taken 5). Another
    /// Margin inside the run-up is played past, as the friend's plain moment would.
    public struct Plan: Equatable, Sendable {
        /// Episode time to start from, in ms.
        public let startMs: Int
        /// Episode time of the Margin, where the run-up ends and the chime plays.
        public let marginMs: Int
        /// True when the run-up reached the episode's start before its full length.
        public let reachedEpisodeStart: Bool

        public var runUpMs: Int { marginMs - startMs }

        public init(marginPositionMs: Int, leadInMs: Int) {
            let moment = ListeningMoment(
                use: .reviewNewMargins,
                margin: ListeningMoment.Margin(id: "preview", position: max(0, marginPositionMs), leadInMs: leadInMs),
                source: .media()
            )
            startMs = moment.sourceStartPosition
            marginMs = moment.margin.position
            reachedEpisodeStart = moment.leadInClamp == .sourceStart
        }
    }
}
