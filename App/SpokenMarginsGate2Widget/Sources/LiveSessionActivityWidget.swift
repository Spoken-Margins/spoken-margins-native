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
            LiveSessionActivityCard(
                state: context.state, sessionStartedAt: context.attributes.sessionStartedAt, isStale: context.isStale
            )
            .widgetURL(LiveSessionDeepLink.url())
            .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let stopped = context.state.endedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle")
                                .accessibilityLabel(context.state.stateAccessibilityLabel)
                            Text(stopped, style: .time)
                        }
                        .font(.caption.monospacedDigit())
                    } else {
                        Text(context.state.clockOrigin ?? context.attributes.sessionStartedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.hasEnded ? "Ended" : context.state.isRecordingNow ? "Recording" : markLabel(context.state.markCount))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.hasEnded {
                        LiveSessionResumeButton(sessionId: context.state.sessionId, isStale: context.isStale)
                    } else if context.state.isRecordingNow {
                        LiveSessionFinishButton()
                    } else {
                        VStack(spacing: 8) {
                            LiveSessionMarkButton()
                            LiveSessionMarginLinks()
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.hasEnded ? "stop.circle" : context.state.isRecordingNow ? "waveform" : "bookmark")
                    .accessibilityLabel(context.state.stateAccessibilityLabel)
            } compactTrailing: {
                if context.state.hasEnded {
                    Text("Ended")
                        .font(.caption)
                } else if context.state.isRecordingNow {
                    Text("Rec")
                        .font(.caption)
                } else {
                    Text("\(context.state.markCount)")
                        .font(.caption.monospacedDigit())
                }
            } minimal: {
                Image(systemName: context.state.hasEnded ? "stop.circle" : context.state.isRecordingNow ? "waveform" : "bookmark")
                    .accessibilityLabel(context.state.stateAccessibilityLabel)
            }
            .widgetURL(LiveSessionDeepLink.url())
        }
    }

    private func markLabel(_ count: Int) -> String { liveSessionMarkLabel(count) }
}

private func liveSessionMarkLabel(_ count: Int) -> String {
    count == 1 ? "1 Mark" : "\(count) Marks"
}

/// How the Lock Screen card behaves as text grows (#3722). The system may cut off a Live Activity taller than 160 pt, so
/// the card stops growing at `textCeiling` (the largest standard size, so an accessibility size reads the same as
/// that) and drops the Write and Speak links once the clock, the state line and the Mark button no longer leave them
/// room. Tapping the card still opens the live session, where both are one tap away. `LiveSessionCardLayoutTests` lays
/// the card out at every size and holds it to 160 pt.
enum LiveSessionCardLayout {
    static let textCeiling: DynamicTypeSize = .xxxLarge
    static let marginLinksCeiling: DynamicTypeSize = .xLarge

    static func showsMarginLinks(at size: DynamicTypeSize) -> Bool { size <= marginLinksCeiling }
}

/// The Lock Screen card, as its own view so `LiveSessionCardLayoutTests` can render it at real text sizes.
struct LiveSessionActivityCard: View {
    let state: LiveSessionActivityAttributes.ContentState
    let sessionStartedAt: Date
    let isStale: Bool
    /// The size the listener chose, read before the ceiling below clamps it for the card's own content.
    @Environment(\.dynamicTypeSize) private var chosenTextSize

    var body: some View {
        Group {
            if let stopped = state.endedAt {
                endedCard(stopped: stopped)
            } else {
                runningCard
            }
        }
        .dynamicTypeSize(...LiveSessionCardLayout.textCeiling)
        .padding(16)
    }

    private var runningCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.clockTitle ?? "Live session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Text(state.clockOrigin ?? sessionStartedAt, style: .timer)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if state.isRecordingNow {
                        Label("Recording a Margin", systemImage: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(liveSessionMarkLabel(state.markCount))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if state.isRecordingNow {
                    LiveSessionFinishButton()
                } else {
                    LiveSessionMarkButton()
                }
            }
            if !state.isRecordingNow, LiveSessionCardLayout.showsMarginLinks(at: chosenTextSize) {
                LiveSessionMarginLinks()
            }
        }
    }

    /// "Ended 14:05 · Resume": when the session stopped, not when End was tapped, and the one button that undoes it.
    /// The Marks and Margin links go while it is ended; the session screen still takes a Margin, and Resume brings
    /// them back.
    private func endedCard(stopped: Date) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.clockTitle ?? "Live session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text("Ended \(stopped, style: .time)")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(liveSessionMarkLabel(state.markCount))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            LiveSessionResumeButton(sessionId: state.sessionId, isStale: isStale)
        }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minWidth: 88, minHeight: 44)
            }
            .tint(LiveSessionActivityStyle.buttonTint)
            .accessibilityLabel("Resume the session")
        }
    }
}

private struct LiveSessionMarkButton: View {
    var body: some View {
        Button(intent: LiveSessionMarkIntent()) {
            Label("Mark", systemImage: "bookmark.fill")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 88, minHeight: 44)
        }
        .tint(LiveSessionActivityStyle.buttonTint)
        .accessibilityLabel("Mark this moment")
    }
}

/// Finish, while a spoken Margin records (#3499): stops and saves it without opening the app.
private struct LiveSessionFinishButton: View {
    var body: some View {
        Button(intent: LiveSessionFinishMarginIntent()) {
            Label("Finish Margin", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 88, minHeight: 44)
        }
        .tint(LiveSessionActivityStyle.buttonTint)
        .accessibilityLabel("Finish and save the spoken Margin")
    }
}

/// Write a Margin and Speak a Margin: each opens Spoken Margins on the live session, with the written field ready
/// or the spoken Margin already recording (#2833).
///
/// At the larger text sizes the row is dropped (`LiveSessionCardLayout`). This check is the one the Dynamic Island
/// relies on; the Lock Screen card makes the same check first, so its stack leaves no gap where the row was.
private struct LiveSessionMarginLinks: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if LiveSessionCardLayout.showsMarginLinks(at: dynamicTypeSize) {
            HStack(spacing: 10) {
                link("Write a Margin", systemImage: "square.and.pencil", action: .write)
                link("Speak a Margin", systemImage: "mic.fill", action: .speak)
            }
        }
    }

    private func link(_ title: String, systemImage: String, action: LiveSessionDeepLink.Action) -> some View {
        Link(destination: LiveSessionDeepLink.url(action)) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
    }
}

/// The live session card's button tint. A fixed sky blue, the same literal as the progress mark on the shared-Margin card
/// (`Gate2LiveActivityWidget`), not `.blue`: the widget sets no colour scheme, and the system blue measures 4.46:1 on the
/// plate when it resolves to its light value (#3739). `AppColorContrastAudit.liveActivityPairs` measures this colour.
private enum LiveSessionActivityStyle {
    static let buttonTint = Color(red: 0.34, green: 0.71, blue: 0.91)
}
