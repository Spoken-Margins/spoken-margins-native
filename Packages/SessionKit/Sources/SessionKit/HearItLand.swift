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
    /// hides a written Margin's card, which plays nothing.
    public struct Surroundings: Equatable, Sendable {
        public var appInForeground: Bool
        public var recordingAgain: Bool
        public var anotherSheetUp: Bool
        public var speechCardShowing: Bool

        public init(appInForeground: Bool = true, recordingAgain: Bool = false, anotherSheetUp: Bool = false, speechCardShowing: Bool = false) {
            self.appInForeground = appInForeground
            self.recordingAgain = recordingAgain
            self.anotherSheetUp = anotherSheetUp
            self.speechCardShowing = speechCardShowing
        }

        public static let clear = Surroundings()

        var allowsPlayback: Bool { appInForeground && !recordingAgain && !anotherSheetUp && !speechCardShowing }
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
