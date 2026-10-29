import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The live session's Lock Screen and Dynamic Island (#2481): the session clock, the number of Marks, a Mark button
/// that notes this moment without opening the app, and Write a Margin and Speak a Margin, which open the live
/// session (#2833). Tapping anywhere else opens it too.
///
/// After End the same card stays for the Resume window as "Ended 14:05 · Resume" (#2883): the time it stopped, and a
/// Resume button that reopens the session. When the window closes the system marks the card stale and the button goes.
struct LiveSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveSessionActivityAttributes.self) { context in
            Group {
                if let stopped = context.state.endedAt {
                    endedCard(stopped: stopped, context: context)
                } else {
                    runningCard(context)
                }
            }
            .widgetURL(LiveSessionDeepLink.url())
            .padding(16)
            .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let stopped = context.state.endedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle")
                            Text(stopped, style: .time)
                        }
                        .font(.caption.monospacedDigit())
                    } else {
                        Text(context.state.clockOrigin ?? context.attributes.sessionStartedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.hasEnded ? "Ended" : markLabel(context.state.markCount))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.hasEnded {
                        LiveSessionResumeButton(sessionId: context.state.sessionId, isStale: context.isStale)
                    } else {
                        VStack(spacing: 8) {
                            LiveSessionMarkButton()
                            LiveSessionMarginLinks()
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.hasEnded ? "stop.circle" : "bookmark")
            } compactTrailing: {
                if context.state.hasEnded {
                    Text("Ended")
                        .font(.caption)
                } else {
                    Text("\(context.state.markCount)")
                        .font(.caption.monospacedDigit())
                }
            } minimal: {
                Image(systemName: context.state.hasEnded ? "stop.circle" : "bookmark")
            }
            .widgetURL(LiveSessionDeepLink.url())
        }
    }

    private func runningCard(_ context: ActivityViewContext<LiveSessionActivityAttributes>) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.clockTitle ?? "Live session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(context.state.clockOrigin ?? context.attributes.sessionStartedAt, style: .timer)
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
    }

    /// "Ended 14:05 · Resume": when the session stopped, not when End was tapped, and the one button that undoes it.
    /// The Marks and Margin links go while it is ended; the session screen still takes a Margin, and Resume brings
    /// them back.
    private func endedCard(stopped: Date, context: ActivityViewContext<LiveSessionActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.clockTitle ?? "Live session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Ended \(stopped, style: .time)")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                Text(markLabel(context.state.markCount))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 8)
            LiveSessionResumeButton(sessionId: context.state.sessionId, isStale: context.isStale)
        }
    }

    private func markLabel(_ count: Int) -> String {
        count == 1 ? "1 Mark" : "\(count) Marks"
    }
}

/// Resume, for the window after End. Once the card is stale (the window closed) there is nothing to tap.
private struct LiveSessionResumeButton: View {
    let sessionId: String?
    let isStale: Bool

    var body: some View {
        if let sessionId, !isStale {
            Button(intent: LiveSessionResumeIntent(sessionId: sessionId)) {
                Label("Resume", systemImage: "play.fill")
                    .font(.headline)
                    .frame(minWidth: 88, minHeight: 44)
            }
            .tint(.blue)
            .accessibilityLabel("Resume the session")
        }
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
