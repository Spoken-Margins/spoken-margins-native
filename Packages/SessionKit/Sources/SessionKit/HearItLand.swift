import Foundation

/// Hear it land (#4713): right after a listener saves a Margin for the first time, the app plays it back in place (a few
/// seconds of the source, their voice, then the source carries on), or for a written Margin shows its card. This is the
/// one rule for whether that happens; the playback itself is the ordinary Margin moment (`ListeningMoment.Use.hearItLand`).
public enum HearItLand {
    public enum Plan: Equatable, Sendable {
        case none
        /// A spoken Margin: start the moment right after the save's own resume.
        case playBack
        /// A written Margin: nothing to play, so the pinned card shows for `PinnedMarginCard.answerSavedWindow`.
        case showWritten
    }

    /// What else owns the screen or the microphone when the save finishes. Any of these stops the playback; none of them
    /// hides a written Margin's card, which plays nothing. The speech-recognition card is not one of them: it waits for
    /// the playback (#4715), so the save that arms it is the very save that plays back (`order`).
    public struct Surroundings: Equatable, Sendable {
        public var appInForeground: Bool
        public var recordingAgain: Bool
        public var anotherSheetUp: Bool

        public init(appInForeground: Bool = true, recordingAgain: Bool = false, anotherSheetUp: Bool = false) {
            self.appInForeground = appInForeground
            self.recordingAgain = recordingAgain
            self.anotherSheetUp = anotherSheetUp
        }

        public static let clear = Surroundings()

        var allowsPlayback: Bool { appInForeground && !recordingAgain && !anotherSheetUp }
    }

    /// What runs first after a save and what waits (#4713 Design, then #4715's speech card): the playback first, then the ask.
    public struct Order: Equatable, Sendable {
        public var plan: Plan
        /// What the speech-recognition ask hears at the save. Nil for a written Margin (nothing to transcribe).
        public var speechAtSave: SpeechRecognitionAsk.Moment?
        /// What it hears when the playback's voice ends or the playback is cancelled. Nil when no playback runs.
        public var speechAtPlaybackEnd: SpeechRecognitionAsk.Moment?
    }

    /// The plan and the speech ask's two moments from one decision, taken before the speech ask hears of the save. The
    /// model used to arm the card first, which took the slot and left the playback with nothing to do.
    public static func order(
        kind: MarginHearing.Kind,
        heardFirstMargin: Bool,
        hadSavedMarginBefore: Bool,
        savedOverHeldVoice: Bool,
        sourcePlaysAfterSave: Bool,
        surroundings: Surroundings = .clear
    ) -> Order {
        let chosen = plan(
            kind: kind, heardFirstMargin: heardFirstMargin, hadSavedMarginBefore: hadSavedMarginBefore,
            savedOverHeldVoice: savedOverHeldVoice, sourcePlaysAfterSave: sourcePlaysAfterSave, surroundings: surroundings)
        let playsBack = chosen == .playBack
        return Order(
            plan: chosen,
            speechAtSave: SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: kind == .written, hearItLandWillRun: playsBack),
            speechAtPlaybackEnd: playsBack ? .hearItLandEnded : nil)
    }

    /// The Margin a spoken save made and where it sits, ready to play.
    public struct SavedPlayback: Equatable, Sendable {
        public let saved: Interjection
        public let target: MarginMomentAnchor
    }

    /// Finds the just-saved Margin among the session's Margins and places it on `clock`. Nil when it isn't there, isn't a
    /// spoken Margin with a recording, is older than `maxAge` seconds (an id left behind by an earlier save must not play an
    /// older Margin), or has no place on the clock.
    public static func savedPlayback(
        savedId: String,
        among interjections: [Interjection],
        now: Date,
        clock: MarginMomentClock,
        targetMediaTimeMs: Int?,
        textForItem: (String) -> String,
        maxAge: TimeInterval = 10
    ) -> SavedPlayback? {
        guard let saved = interjections.first(where: { $0.id == savedId }), saved.isSpokenItemMargin,
              abs(now.timeIntervalSince(saved.createdAt)) < maxAge, saved.audioPath != nil,
              let anchors = MarginMomentPlanner.anchors(
                played: saved, among: [], clock: clock, targetMediaTimeMs: targetMediaTimeMs,
                text: clock.isNarratedText ? textForItem(saved.itemId) : "") else { return nil }
        return SavedPlayback(saved: saved, target: anchors.target)
    }

    /// - Parameters:
    ///   - kind: how the Margin was made.
    ///   - heardFirstMargin: `OnboardingStep.heardFirstMargin` is marked (#4711). Every later Margin, and every upgrade.
    ///   - hadSavedMarginBefore: `OnboardingStep.firstInterjection` as it was before this save marked it. It does not
    ///     change the answer: a later Margin plays back too while the event hasn't fired (Default 1), so a skipped first
    ///     playback isn't the end of it. Kept so the call site says which case it is.
    ///   - savedOverHeldVoice: the Margin was recorded over a speaking Margin, which plays on as today (#1672).
    ///   - sourcePlaysAfterSave: the save resumed the source.
    public static func plan(
        kind: MarginHearing.Kind,
        heardFirstMargin: Bool,
        hadSavedMarginBefore: Bool,
        savedOverHeldVoice: Bool,
        sourcePlaysAfterSave: Bool,
        surroundings: Surroundings = .clear
    ) -> Plan {
        _ = hadSavedMarginBefore
        guard !heardFirstMargin else { return .none }
        switch kind {
        case .written:
            return .showWritten
        case .spoken:
            guard !savedOverHeldVoice, sourcePlaysAfterSave, surroundings.allowsPlayback else { return .none }
            return .playBack
        }
    }
}
