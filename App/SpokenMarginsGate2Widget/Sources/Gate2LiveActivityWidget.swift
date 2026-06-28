import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct Gate2LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Gate2LiveActivityAttributes.self) { context in
            Gate2LiveActivityView(state: context.state)
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
