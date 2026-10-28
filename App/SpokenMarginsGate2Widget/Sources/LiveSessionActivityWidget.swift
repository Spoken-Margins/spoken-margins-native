import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The live session's Lock Screen and Dynamic Island (#2481): the session clock, the number of Marks, and a
/// Mark button that notes this moment without opening the app.
struct LiveSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveSessionActivityAttributes.self) { context in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                    Text(markLabel(context.state.markCount))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 8)
                LiveSessionMarkButton()
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.clockOrigin ?? context.attributes.sessionStartedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(markLabel(context.state.markCount))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveSessionMarkButton()
                }
            } compactLeading: {
                Image(systemName: "bookmark")
            } compactTrailing: {
                Text("\(context.state.markCount)")
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "bookmark")
            }
        }
    }

    private func markLabel(_ count: Int) -> String {
        count == 1 ? "1 Mark" : "\(count) Marks"
    }
}

private struct LiveSessionMarkButton: View {
    var body: some View {
        Button(intent: LiveSessionMarkIntent()) {
            Label("Mark", systemImage: "bookmark.fill")
                .font(.headline)
                .frame(minWidth: 88, minHeight: 44)
        }
        .tint(.blue)
        .accessibilityLabel("Mark this moment")
    }
}
