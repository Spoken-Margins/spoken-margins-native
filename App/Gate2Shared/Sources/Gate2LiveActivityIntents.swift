import AppIntents
import Foundation

/// These intents live in the shared app/widget source set so ActivityKit can
/// execute them in the containing app process. The widget only enqueues a small
/// command; the canonical app model remains the sole owner of audio playback.
struct Gate2CompactPlaybackIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Spoken Margins Playback"
    static let description = IntentDescription("Controls Spoken Margins playback from the Live Activity.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: String

    init() {
        command = "togglePlayPause"
    }

    init(command: String) {
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        try enqueue(command: command)
        return .result()
    }
}

struct Gate2SharedMarginActionIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Respond to Shared Margin"
    static let description = IntentDescription("Listens to or dismisses the pending Shared Margin.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: String

    init() {
        command = Gate2CompactApplicationCommand.listenToSharedMargin
    }

    init(command: String) {
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        guard command == Gate2CompactApplicationCommand.listenToSharedMargin
                || command == Gate2CompactApplicationCommand.dismissSharedMargin else {
            throw Gate2CompactPlaybackIntentError.unsupportedCommand
        }
        try enqueue(command: command)
        return .result()
    }
}

struct Gate2NextChapterIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Next Chapter"
    static let description = IntentDescription("Opens Spoken Margins and continues from the next chapter.")
    static let openAppWhenRun = true

    @Parameter(title: "Chapter")
    var chapterId: String

    init() {
        chapterId = ""
    }

    init(chapterId: String) {
        self.chapterId = chapterId
    }

    func perform() async throws -> some IntentResult {
        try enqueue(command: "jumpToChapter", targetID: chapterId)
        return .result()
    }
}

struct Gate2NextSharedMarginIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Open Next Shared Margin"
    static let description = IntentDescription("Moves to the next verified Shared Margin.")
    static let openAppWhenRun = false

    @Parameter(title: "Margin")
    var interjectionID: String

    init() {
        interjectionID = ""
    }

    init(interjectionID: String) {
        self.interjectionID = interjectionID
    }

    func perform() async throws -> some IntentResult {
        try enqueue(
            command: Gate2CompactApplicationCommand.jumpToSharedMargin,
            targetID: interjectionID
        )
        return .result()
    }
}

private func enqueue(command: String, targetID: String? = nil) throws {
    guard Gate2CompactCommandQueue.enqueue(command: command, chapterId: targetID) else {
        throw Gate2CompactPlaybackIntentError.appGroupUnavailable
    }
}

private enum Gate2CompactPlaybackIntentError: LocalizedError {
    case appGroupUnavailable
    case unsupportedCommand

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Spoken Margins controls are unavailable because the shared App Group is not configured."
        case .unsupportedCommand:
            "That Spoken Margins Live Activity action is unavailable."
        }
    }
}
