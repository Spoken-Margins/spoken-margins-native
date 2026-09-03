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
                    if let sender = context.state.sharedMarginSenderLabel {
                        VStack(spacing: 8) {
                            Text("Shared Margin from \(sender)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .privacySensitive()
                            Gate2SharedMarginButtons()
                        }
                    } else {
                        VStack(spacing: 3) {
                            Text(context.state.chapterTitle)
                                .font(.caption)
                                .lineLimit(1)
                            if let next = context.state.nextChapterTitle {
                                Text("Next: \(next)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.sharedMarginSenderLabel != nil
                    ? "text.bubble.fill"
                    : (context.state.isRecording ? "record.circle.fill" : "waveform"))
            } compactTrailing: {
                Text(context.state.sharedMarginSenderLabel != nil ? "NEW" : "\(context.state.progressPercent)%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.sharedMarginSenderLabel != nil
                    ? "text.bubble.fill"
                    : (context.state.isRecording ? "record.circle.fill" : "waveform"))
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
                    Text(state.sharedMarginSenderLabel.map { "Margin from \($0)" } ?? state.chapterTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .privacySensitive(state.sharedMarginSenderLabel != nil)
                }
            }

            if state.sharedMarginSenderLabel != nil {
                Gate2SharedMarginButtons(compact: true)
            } else {
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

            ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                .tint(.green)

            if let sender = state.sharedMarginSenderLabel {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Shared Margin from \(sender)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .privacySensitive()
                    Gate2SharedMarginButtons()
                }
            } else {
                transportControls
            }

            if state.sharedMarginSenderLabel == nil,
               state.canRun("generateInterjectionSummary") || state.canRun("submitFollowup") {
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

    private var transportControls: some View {
        HStack(spacing: 16) {
                if state.canRun("skimBackward") {
                    CompactRoundIntentButton(
                        command: "skimBackward",
                        systemImage: "backward.end.alt.fill",
                        size: 50,
                        accessibilityLabel: "Skim backward by scene summary"
                    )
                }
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
                if state.canRun("skimForward") {
                    CompactRoundIntentButton(
                        command: "skimForward",
                        systemImage: "forward.end.alt.fill",
                        size: 50,
                        accessibilityLabel: "Skim forward by scene summary"
                    )
                }
                if let nextChapterTitle = state.nextChapterTitle,
                   let nextChapterId = state.nextChapterId {
                    nextNavigationButton(title: nextChapterTitle, targetID: nextChapterId)
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
    }

    @ViewBuilder
    private func nextNavigationButton(title: String, targetID: String) -> some View {
        let label = state.nextNavigationKind == .sharedMargin ? "NEXT MARGIN" : "NEXT CHAPTER"
        if state.nextNavigationKind == .sharedMargin {
            Button(intent: Gate2NextSharedMarginIntent(interjectionID: targetID)) {
                nextNavigationLabel(label: label, title: title)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("Skip to next Shared Margin")
        } else {
            Button(intent: Gate2NextChapterIntent(chapterId: targetID)) {
                nextNavigationLabel(label: label, title: title)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("Skip to next chapter, \(title)")
        }
    }

    private func nextNavigationLabel(label: String, title: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.58))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Image(systemName: state.nextNavigationKind == .sharedMargin ? "text.bubble.fill" : "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct Gate2SharedMarginButtons: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Button(intent: Gate2SharedMarginActionIntent(command: Gate2CompactApplicationCommand.listenToSharedMargin)) {
                Label(compact ? "Play" : "Listen", systemImage: "play.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38)
                    .foregroundStyle(.white)
                    .background(Color.green.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            Button(intent: Gate2SharedMarginActionIntent(command: Gate2CompactApplicationCommand.dismissSharedMargin)) {
                Label(compact ? "Skip" : "Dismiss", systemImage: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .buttonStyle(.plain)
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
    var accessibilityLabel: String? = nil

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
        .accessibilityLabel(accessibilityLabel ?? command)
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

@main
struct SpokenMarginsGate2WidgetBundle: WidgetBundle {
    var body: some Widget {
        Gate2LiveActivityWidget()
    }
}
