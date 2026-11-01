#if SM_LOCKED_MARGIN_SPIKE
import AppIntents
import Foundation

/// Spike #3086, path 1: the Live Activity's mic button as an intent that starts the microphone in the app
/// process, which is already running because it is playing, to learn whether iOS lets a Margin start with the
/// phone locked. Phone builds and Debug only (`SM_PHONE_BUILD`, project.yml); never in an upload (2026-10-17).
///
/// `AudioRecordingIntent` tells iOS the app records audio. On iPhone a Live Activity must be up for the whole
/// recording or iOS stops it; this button sits on that Live Activity, and recording keeps it published.
/// Unlike the other Live Activity intents it does not use the App Group queue: the app drains that queue up to
/// 400 ms later, after `perform()` has returned, and any leave iOS gives to record belongs to the intent's run.
struct Gate2RecordMarginIntent: LiveActivityIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record a Margin"
    static let description = IntentDescription("Starts or finishes a spoken Margin from the Live Activity.")
    static let openAppWhenRun = false
    static let isDiscoverable = false
    /// Run without Face ID, so the test shows what iOS itself allows on a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Finish")
    var finish: Bool

    init() {
        finish = false
    }

    init(finish: Bool) {
        self.finish = finish
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let handler = Gate2RecordMarginIntentBridge.handler {
            try await handler(finish)
        } else {
            // Run outside the app (the widget's process): the queue still gets the command to the app, and the
            // app's Diagnostics show it under the queue's origin rather than this intent's.
            guard Gate2CompactCommandQueue.enqueue(command: finish ? "finishInterjection" : "beginInterjection",
                                                   chapterId: nil) else {
                throw Gate2RecordMarginIntentError.appUnavailable
            }
        }
        return .result()
    }
}

/// Set by the app at launch, so the intent reaches the app model in the same run.
@MainActor
enum Gate2RecordMarginIntentBridge {
    /// `true` finishes the Margin being recorded, `false` starts one.
    static var handler: (@MainActor (Bool) async throws -> Void)?
}

enum Gate2RecordMarginIntentError: LocalizedError {
    case appUnavailable

    var errorDescription: String? {
        "Spoken Margins could not be reached to record a Margin."
    }
}
#endif
