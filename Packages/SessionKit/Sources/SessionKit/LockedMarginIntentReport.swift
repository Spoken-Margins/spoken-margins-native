import Foundation

/// What one tap of the Lock Screen record button saw, for the locked-phone spike (#3086). The owner's phone test
/// reads this from Diagnostics: whether the Margin started, and the conditions iOS judged it under.
public struct LockedMarginIntentReport: Equatable, Sendable {
    public enum Action: String, Sendable {
        case begin
        case finish
    }

    public enum Outcome: String, Sendable {
        case started
        case alreadyRecording = "already_recording"
        case notStarted = "not_started"
        case finished
        case nothingToFinish = "nothing_to_finish"
        case notFinished = "not_finished"
    }

    public var action: Action
    /// `active`, `inactive` or `background`, read when the intent arrived.
    public var appState: String
    /// False while the phone is locked with a passcode: a hint, not proof, that the phone was locked.
    public var protectedDataAvailable: Bool
    /// How many of the app's Live Activities were active before and after. Apple stops an
    /// `AudioRecordingIntent` recording on iPhone when no Live Activity is up.
    public var liveActivitiesBefore: Int
    public var liveActivitiesAfter: Int
    public var audioCategoryBefore: String
    public var microphonePermission: String
    public var wasRecording: Bool
    public var isRecording: Bool
    /// The raw text of a failure this tap caused, if any.
    public var failure: String?

    public init(
        action: Action,
        appState: String,
        protectedDataAvailable: Bool,
        liveActivitiesBefore: Int,
        liveActivitiesAfter: Int,
        audioCategoryBefore: String,
        microphonePermission: String,
        wasRecording: Bool,
        isRecording: Bool,
        failure: String?
    ) {
        self.action = action
        self.appState = appState
        self.protectedDataAvailable = protectedDataAvailable
        self.liveActivitiesBefore = liveActivitiesBefore
        self.liveActivitiesAfter = liveActivitiesAfter
        self.audioCategoryBefore = audioCategoryBefore
        self.microphonePermission = microphonePermission
        self.wasRecording = wasRecording
        self.isRecording = isRecording
        self.failure = failure
    }

    public var outcome: Outcome {
        switch action {
        case .begin:
            if wasRecording { return .alreadyRecording }
            return isRecording ? .started : .notStarted
        case .finish:
            if !wasRecording { return .nothingToFinish }
            return isRecording ? .notFinished : .finished
        }
    }

    /// True when the tap did what it asked for, or found it already done.
    public var succeeded: Bool {
        switch outcome {
        case .started, .alreadyRecording, .finished, .nothingToFinish: return true
        case .notStarted, .notFinished: return false
        }
    }

    public var fields: [String: String] {
        var fields = [
            "action": action.rawValue,
            "outcome": outcome.rawValue,
            "appState": appState,
            "protectedData": protectedDataAvailable ? "available" : "unavailable_maybe_locked",
            "liveActivitiesBefore": String(liveActivitiesBefore),
            "liveActivitiesAfter": String(liveActivitiesAfter),
            "audioCategoryBefore": audioCategoryBefore,
            "microphone": microphonePermission,
        ]
        if let failure, !failure.isEmpty { fields["failure"] = failure }
        return fields
    }

    /// One line for the Diagnostics summary.
    public var summary: String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
