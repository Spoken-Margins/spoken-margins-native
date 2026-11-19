import Foundation

/// What the sender's share review says while a Margin is still waiting on something (#3839): its words, or the exact
/// moment in the episode. A step is a wait the sender may act on, so it sits on the Margin's card and, above the Share
/// button, in the pinned bar. Share is never blocked by one: the Margin still places by its words.
///
/// The rule works from the stored Margin and whether the sheet's episode is playing, nothing else, so it can be
/// tested as a table. The sheet reads the stored Margin each time the model publishes it, never the copy the draft took
/// when the sheet opened, so a step clears by itself when its wait ends.
public enum ShareReviewSteps {
    /// One Margin as the review sees it.
    public struct Margin: Equatable, Sendable {
        /// An episode or an audio file: the only items whose Margins wait on a sample of the audio.
        public var isNativeAudio: Bool
        /// The Margin already carries anchor evidence, whatever its status.
        public var hasEvidence: Bool
        public var evidenceStatus: PodcastAnchorEvidenceCaptureStatus?
        /// "pending", "failed", or a finished status.
        public var transcriptionStatus: String
        /// The sheet's item is the one playing, and playback is active.
        public var playingThisItem: Bool

        public init(
            isNativeAudio: Bool, hasEvidence: Bool, evidenceStatus: PodcastAnchorEvidenceCaptureStatus?,
            transcriptionStatus: String, playingThisItem: Bool
        ) {
            self.isNativeAudio = isNativeAudio
            self.hasEvidence = hasEvidence
            self.evidenceStatus = evidenceStatus
            self.transcriptionStatus = transcriptionStatus
            self.playingThisItem = playingThisItem
        }

        /// One stored Margin as the review sees it. `includesWordsWait` is false until the draft is rebuilt when the words
        /// arrive (#3839, PR 3): a "waiting for words" step that nothing clears would stay on the card, so until then
        /// today's no-transcript line and badge stand and the Margin reports its words as done.
        public init(_ interjection: Interjection, isNativeAudio: Bool, playingThisItem: Bool, includesWordsWait: Bool = false) {
            self.init(
                isNativeAudio: isNativeAudio,
                hasEvidence: !(interjection.podcastAnchorEvidence ?? []).isEmpty,
                evidenceStatus: interjection.podcastAnchorEvidenceCaptureStatus,
                transcriptionStatus: includesWordsWait ? interjection.transcriptionStatus : "done",
                playingThisItem: playingThisItem
            )
        }

        /// The Margin's moment is still being found.
        var waitsOnMoment: Bool {
            isNativeAudio && !hasEvidence && evidenceStatus == .pendingPostResumeSample
        }

        var waitsOnWords: Bool { transcriptionStatus == "pending" }
    }

    public enum Icon: Equatable, Sendable {
        /// Neutral, so colour carries no meaning.
        case clock
        case words
    }

    public struct Step: Equatable, Sendable {
        public var icon: Icon
        public var text: String
    }

    // MARK: Card

    /// The steps at the top of a Margin's card: its words first, then its moment.
    public static func cardSteps(_ margin: Margin) -> [Step] {
        var steps: [Step] = []
        if margin.waitsOnWords {
            steps.append(Step(icon: .words, text: "Getting this Margin's words ready. It's added when they're ready."))
        }
        if margin.waitsOnMoment {
            steps.append(Step(icon: .clock, text: margin.playingThisItem
                ? "Finding the exact moment for this Margin. Keep the episode playing a few more seconds."
                : "Play the episode for about 12 seconds so your friend hears this Margin at the exact moment. Sharing now may put it a few seconds off."))
        }
        return steps
    }

    /// The quiet placement note under a card: only for a Margin on an episode or audio file with no evidence.
    public static func cardNote(_ margin: Margin) -> String? {
        guard margin.isNativeAudio, !margin.hasEvidence else { return nil }
        switch margin.evidenceStatus {
        case .pendingExactLocalCapture: return "Getting the exact moment ready for this Margin."
        case .unavailable, nil: return "Your friend's copy will find this Margin by its words, so it may land a few seconds off."
        case .pendingPostResumeSample, .ready: return nil // the step says it, or there is nothing to say
        }
    }

    public static let failedTranscriptLine = "No transcript yet, so this Margin can't be shared. Retry its transcription in Margin detail."

    /// A badge for a Margin that can't go yet: waiting for words, or left out because they failed. nil otherwise.
    public static func badge(_ margin: Margin) -> String? {
        if margin.waitsOnWords { return "Waiting for words" }
        if margin.transcriptionStatus == "failed" { return "Left out: no transcript yet" }
        return nil
    }

    // MARK: Pinned bar

    /// The one line above "Share link". Words come first and are the only line when both waits are on.
    public static func pinnedLine(_ margins: [Margin]) -> String? {
        let words = margins.filter(\.waitsOnWords).count
        if words > 0 {
            let who = words == 1 ? "your new Margin" : "\(words) of these Margins"
            return "Getting the words ready for \(who). A few seconds."
        }
        let waiting = margins.filter(\.waitsOnMoment)
        guard !waiting.isEmpty else { return nil }
        let one = waiting.count == 1
        let who = one ? "your new Margin" : "\(waiting.count) of these Margins"
        if waiting.allSatisfy(\.playingThisItem) {
            return "Finding the exact moment for \(who). Keep the episode playing a few more seconds."
        }
        return "Play the episode for about 12 seconds so your friend hears \(who) at the exact moment. Sharing now may put \(one ? "it" : "them") a few seconds off."
    }

    /// The pinned line with the icon of the wait it names: words when any Margin waits on its words, else the clock.
    public static func pinnedStep(_ margins: [Margin]) -> Step? {
        pinnedLine(margins).map { Step(icon: margins.contains(where: \.waitsOnWords) ? .words : .clock, text: $0) }
    }
}
