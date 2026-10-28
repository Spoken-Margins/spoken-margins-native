import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The live session's Lock Screen and Dynamic Island (#2481): the session clock, the number of Marks, a Mark button
/// that notes this moment without opening the app, and Write a Margin and Speak a Margin, which open the live
/// session (#2833). Tapping anywhere else opens it too.
struct LiveSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveSessionActivityAttributes.self) { context in
            VStack(spacing: 10) {
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
                LiveSessionMarginLinks()
            }
            .widgetURL(LiveSessionDeepLink.url())
            .padding(16)
            .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(markLabel(context.state.markCount))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        LiveSessionMarkButton()
                        LiveSessionMarginLinks()
                    }
                }
            } compactLeading: {
                Image(systemName: "bookmark")
            } compactTrailing: {
                Text("\(context.state.markCount)")
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "bookmark")
            }
            .widgetURL(LiveSessionDeepLink.url())
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

/// Write a Margin and Speak a Margin: each opens Spoken Margins on the live session, with the written field ready
/// or the spoken Margin already recording (#2833).
private struct LiveSessionMarginLinks: View {
    var body: some View {
        HStack(spacing: 10) {
            link("Write a Margin", systemImage: "square.and.pencil", action: .write)
            link("Speak a Margin", systemImage: "mic.fill", action: .speak)
        }
    }

    private func link(_ title: String, systemImage: String, action: LiveSessionDeepLink.Action) -> some View {
        Link(destination: LiveSessionDeepLink.url(action)) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
    }
}
