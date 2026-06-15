import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct Gate2CompactCommandIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Spoken Margins Compact Command"
    static let description = IntentDescription("Opens Spoken Margins so the phone runtime can handle a compact control command.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: String

    init() {
        command = "togglePlayPause"
    }

    init(command: String) {
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(Gate2CompactCommandURL.url(command: command)))
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
                Spacer()
                Text(state.isRecording ? "REC" : state.status.uppercased())
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(state.isRecording ? .red : .white)
            }

            ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                .tint(.green)

            HStack(spacing: 12) {
                Button(intent: Gate2CompactCommandIntent(command: "skipBack")) {
                    Image(systemName: "gobackward.15")
                }
                Button(intent: Gate2CompactCommandIntent(command: "togglePlayPause")) {
                    Image(systemName: state.status == "playing" ? "pause.fill" : "play.fill")
                }
                Button(intent: Gate2CompactCommandIntent(command: "skipForward")) {
                    Image(systemName: "goforward.15")
                }
                Spacer()
                Button(intent: Gate2CompactCommandIntent(command: state.isRecording ? "finishInterjection" : "beginInterjection")) {
                    Image(systemName: state.isRecording ? "checkmark" : "mic.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding()
    }
}

@main
struct SpokenMarginsGate2WidgetBundle: WidgetBundle {
    var body: some Widget {
        Gate2LiveActivityWidget()
    }
}
