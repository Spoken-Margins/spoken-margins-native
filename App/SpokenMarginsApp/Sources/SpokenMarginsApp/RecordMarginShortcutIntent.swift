#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

/// Where "Record a Margin" sends the recording (#4923). The route is `RecordMarginRoute`'s; this applies it. A live
/// session's spoken Margin starts through the live-session link the Live Activity's "Speak a Margin" button uses, so
/// the session's own screen shows the recording. The player's item starts through the same compact command as the
/// on-screen Add a Margin, so the microphone prompt, the audio-session switch and the Live Activity follow it.
@MainActor
enum RecordMarginShortcutAction {
    static let origin = "record_margin_intent"

    @discardableResult
    static func perform(
        in model: Gate1AppModel, files: LiveSessionFileWorker = .shared, router: LiveSessionLinkRouter = .shared
    ) async -> RecordMarginRoute {
        let route = RecordMarginRoute.decide(.init(
            runningSession: await files.runningSession(),
            playerHasSession: model.hasActiveSession,
            alreadyRecording: model.snapshot.isRecording || LiveSessionSpokenMargins.isRecordingOnPhone
        ))
        switch route {
        case .alreadyRecording:
            break
        case .liveSession, .sessionStartCard:
            router.open(.speak)
        case .playerItem:
            model.dispatchGate2CompactCommand(.beginInterjection, origin: origin)
        }
        model.recordDeveloperDiagnostic("margin.record_intent", ["route": route.diagnosticName])
        return route
    }
}

/// Opens Spoken Margins and starts a spoken Margin at once, for when the screen is fine to look at (Back Tap, the
/// Action Button, the Home Screen). It is not the hands-free route: "Add a Margin" stays the dictated-text one
/// (`AddMarginToSpokenMarginsIntent`, owner's calls of 2026-11-09 and 2026-11-22). It opens the app because iOS lets
/// an app begin recording from the foreground; whether an intent may begin recording without opening the app, or on
/// a locked phone, is untested and not pursued (#3086, 2026-10-31). Locked, iOS asks to unlock before it opens.
///
/// It takes no parameter, so Siri and Shortcuts never ask anything before it opens the app.
struct RecordMarginShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Margin"
    static let description = IntentDescription(
        "Opens Spoken Margins and starts recording a spoken Margin: on your running live session if there is one, else on whatever is playing. Use Add Margin instead to dictate a text Margin without opening the app."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        await RecordMarginShortcutAction.perform(in: model)
        return .result()
    }
}
#endif
