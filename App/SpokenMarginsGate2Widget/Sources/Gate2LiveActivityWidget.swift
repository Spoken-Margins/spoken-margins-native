import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct Gate2LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Gate2LiveActivityAttributes.self) { context in
            Gate2LiveActivityContent(state: context.state)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.status.capitalized)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.progressPercent)%")
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.chapterTitle)
                        .font(.caption)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.isRecording ? "record.circle.fill" : "waveform")
            } compactTrailing: {
                Text("\(context.state.progressPercent)%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.isRecording ? "record.circle.fill" : "waveform")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct Gate2LiveActivityContent: View {
    @Environment(\.activityFamily) private var activityFamily
    let state: Gate2LiveActivityAttributes.ContentState

    var body: some View {
        switch activityFamily {
        case .small:
            Gate2LiveActivitySmallView(state: state)
        case .medium:
            Gate2LiveActivityView(state: state)
        @unknown default:
            Gate2LiveActivityView(state: state)
        }
    }
}

private struct Gate2LiveActivitySmallView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let state: Gate2LiveActivityAttributes.ContentState

    private var isPlaying: Bool {
        state.status == "playing" || state.status == "starting"
    }

    private var stateText: String {
        if state.isRecording { return "REC" }
        if isPlaying { return "PLAY" }
        return state.status.uppercased()
    }

    private var stateImage: String {
        if state.isRecording { return "record.circle.fill" }
        return isPlaying ? "waveform" : "pause.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: stateImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.isRecording ? .red : .green)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text(state.chapterTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(stateText)
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(state.isRecording ? .red : .white.opacity(0.84))
                Spacer(minLength: 4)
                Text("\(max(0, min(100, state.progressPercent)))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }

            ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                .tint(isLuminanceReduced ? .white.opacity(0.72) : .green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct Gate2LiveActivityView: View {
    let state: Gate2LiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(state.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Text(state.isRecording ? "REC" : state.status.uppercased())
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(state.isRecording ? .red : .white)
            }

            if let sender = state.commentarySenderLabel,
               let index = state.commentaryIndex,
               let count = state.commentaryCount {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sender)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Interjection \(index) of \(count)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    if state.isPlayingImportedCommentary {
                        CompactActionIntentButton(
                            command: Gate2CompactApplicationCommand.stopImportedInterjection,
                            title: "Return to Source",
                            systemImage: "arrow.uturn.backward"
                        )
                    } else {
                        CompactActionIntentButton(
                            command: Gate2CompactApplicationCommand.playImportedInterjection,
                            title: "Listen",
                            systemImage: "ear"
                        )
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                .tint(.green)

            HStack(spacing: 16) {
                if state.canRun("skipBack") {
                    CompactRoundIntentButton(command: "skipBack", systemImage: "gobackward.15", size: 56)
                }
                if state.canRun("togglePlayPause") {
                    CompactPlayPauseButton(
                        command: "togglePlayPause",
                        isPlaying: state.status == "playing" || state.status == "starting"
                    )
                }
                if state.canRun("skipForward") {
                    CompactRoundIntentButton(command: "skipForward", systemImage: "goforward.15", size: 56)
                }
                if let nextChapterTitle = state.nextChapterTitle,
                   let nextChapterId = state.nextChapterId {
                    Button(intent: Gate2NextChapterIntent(chapterId: nextChapterId)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("NEXT CHAPTER")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.58))
                                Text(nextChapterTitle)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Skip to next chapter, \(nextChapterTitle)")
                }
                Spacer()
                if state.canRun("beginInterjection") || state.canRun("finishInterjection") {
                    Link(destination: Gate2CompactCommandURL.url(command: state.isRecording ? "finishInterjection" : "beginInterjection")) {
                        Image(systemName: state.isRecording ? "checkmark" : "mic.fill")
                            .font(.title2.weight(.semibold))
                            .frame(width: 56, height: 56)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(state.isRecording ? "Finish interjection" : "Interject")
                }
            }
            .buttonStyle(.plain)

            if state.canRun("generateInterjectionSummary") || state.canRun("submitFollowup") {
                HStack(spacing: 10) {
                    if state.canRun("generateInterjectionSummary") {
                        CompactActionIntentButton(
                            command: Gate2CompactApplicationCommand.summarizeInterjections,
                            title: "Summary",
                            systemImage: "sparkles"
                        )
                    }

                    if state.canRun("submitFollowup") {
                        CompactActionIntentButton(
                            command: Gate2CompactApplicationCommand.discussInterjections,
                            title: "Discuss",
                            systemImage: "text.bubble.fill"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private extension Gate2LiveActivityAttributes.ContentState {
    func canRun(_ command: String) -> Bool {
        availableCommands.contains(command)
    }
}

private struct CompactRoundIntentButton: View {
    let command: String
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Button(intent: Gate2CompactPlaybackIntent(command: command)) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: size, height: size)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.16))
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

private struct CompactPlayPauseButton: View {
    let command: String
    let isPlaying: Bool

    var body: some View {
        Button(intent: Gate2CompactPlaybackIntent(command: command)) {
            playPauseLabel
        }
        .frame(width: 60, height: 60)
        .contentShape(Circle())
    }

    private var playPauseLabel: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.title.weight(.bold))
            .frame(width: 60, height: 60)
            .foregroundStyle(.white)
            .padding(.leading, isPlaying ? 0 : 3)
            .background(Color(red: 0.27, green: 0.78, blue: 0.43).opacity(0.28))
            .clipShape(Circle())
    }
}

private struct CompactActionIntentButton: View {
    let command: String
    let title: String
    let systemImage: String

    var body: some View {
        Button(intent: Gate2CompactPlaybackIntent(command: command)) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

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
        guard Gate2CompactCommandQueue.enqueue(command: command) else {
            throw Gate2CompactPlaybackIntentError.appGroupUnavailable
        }
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
        guard Gate2CompactCommandQueue.enqueue(command: "jumpToChapter", chapterId: chapterId) else {
            throw Gate2CompactPlaybackIntentError.appGroupUnavailable
        }
        return .result()
    }
}

private enum Gate2CompactPlaybackIntentError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "Spoken Margins controls are unavailable because the shared App Group is not configured."
    }
}

@main
struct SpokenMarginsGate2WidgetBundle: WidgetBundle {
    var body: some Widget {
        Gate2LiveActivityWidget()
    }
}
