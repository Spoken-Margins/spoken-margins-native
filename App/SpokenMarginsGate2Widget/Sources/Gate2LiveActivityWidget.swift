import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct Gate2LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Gate2LiveActivityAttributes.self) { context in
            Gate2LiveActivityContent(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.tapURL(isStale: context.isStale))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.offersResume(isStale: context.isStale) ? "Paused" : context.state.statusLabel)
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
                                .adaptiveLineLimit()
                                .privacySensitive()
                            Gate2SharedMarginButtons()
                        }
                    } else {
                        VStack(spacing: 3) {
                            Text(context.state.offersResume(isStale: context.isStale)
                                ? Gate2LiveActivityCopy.pausedPrompt
                                : context.state.chapterTitle)
                                .font(.caption)
                                .adaptiveLineLimit()
                            if let next = context.state.nextChapterTitle {
                                Text("Next: \(next)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .adaptiveLineLimit()
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.sharedMarginSenderLabel != nil
                    ? "text.bubble.fill"
                    : context.state.surfaceSymbol(isStale: context.isStale))
                    .accessibilityLabel(context.state.stateAccessibilityLabel(isStale: context.isStale))
            } compactTrailing: {
                Text(context.state.sharedMarginSenderLabel != nil ? "NEW" : "\(context.state.progressPercent)%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.sharedMarginSenderLabel != nil
                    ? "text.bubble.fill"
                    : context.state.surfaceSymbol(isStale: context.isStale))
                    .accessibilityLabel(context.state.stateAccessibilityLabel(isStale: context.isStale))
            }
            .widgetURL(context.state.tapURL(isStale: context.isStale))
        }
        .supplementalActivityFamilies([.small])
    }
}

enum Gate2LiveActivityCopy {
    static let pausedPrompt = "Paused — tap to resume"
}

extension Gate2LiveActivityAttributes.ContentState {
    /// The card says REC only while the microphone is really taking in sound (#937). The words and the
    /// symbol change with it, not only the colour.
    var recordingWord: String {
        switch microphone {
        case .capturing: "REC"
        case .starting: "MIC…"
        case .stopped: "NOT REC"
        }
    }

    var recordingSymbol: String {
        switch microphone {
        case .capturing: "record.circle.fill"
        case .starting: "mic.badge.plus"
        case .stopped: "exclamationmark.triangle.fill"
        }
    }

    var recordingTint: Color { microphone == .capturing ? .red : .orange }

    /// Progress and the idle glyph are sky blue, never green: red and green sit side by side on this card when a
    /// Margin records, and the pair cannot be told apart by a red-green colourblind listener (#1924). Sky blue is the
    /// Okabe-Ito colour that stays distinct from both red and orange.
    static let progressTint = Color(red: 0.34, green: 0.71, blue: 0.91)

    /// The status in words. A Margin whose microphone is not capturing never reads "Recording".
    var statusLabel: String {
        guard isRecording else { return isLoadingAudio ? "Loading…" : status.capitalized }
        switch microphone {
        case .capturing: return status.capitalized
        case .starting: return "Starting mic"
        case .stopped: return "Mic stopped"
        }
    }

    func surfaceSymbol(isStale: Bool) -> String {
        if isRecording { return recordingSymbol }
        if offersResume(isStale: isStale) { return "pause.fill" }
        // Accepted but not yet heard: an hourglass, not a waveform that claims sound (#943).
        return isLoadingAudio ? "hourglass" : "waveform"
    }

    /// The one-word state on the card: "LOADING" until audio is confirmed, never "STARTING" or "PLAY".
    var headlineWord: String {
        if isRecording { return recordingWord }
        return isLoadingAudio ? "LOADING" : status.uppercased()
    }
}

private struct Gate2LiveActivityContent: View {
    @Environment(\.activityFamily) private var activityFamily
    let state: Gate2LiveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch activityFamily {
        case .small:
            Gate2LiveActivitySmallView(state: state, isStale: isStale)
        case .medium:
            Gate2LiveActivityView(state: state, isStale: isStale)
        @unknown default:
            Gate2LiveActivityView(state: state, isStale: isStale)
        }
    }
}

private struct Gate2LiveActivitySmallView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// The state glyph and its frame follow the text size, never below the default (#1940).
    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var glyphFrame: CGFloat = 22
    let state: Gate2LiveActivityAttributes.ContentState
    let isStale: Bool

    private var isPlaying: Bool {
        !isStale && state.isAudioRunning
    }

    private var stateText: String {
        if state.isRecording { return state.recordingWord }
        if state.offersResume(isStale: isStale) { return "TAP TO RESUME" }
        if isPlaying { return "PLAY" }
        return state.headlineWord
    }

    private var stateImage: String {
        if state.isRecording { return state.recordingSymbol }
        if state.isLoadingAudio { return "hourglass" }
        return isPlaying ? "waveform" : "pause.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: stateImage)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(state.isRecording ? state.recordingTint : Gate2LiveActivityAttributes.ContentState.progressTint)
                    .frame(width: glyphFrame, height: glyphFrame)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .adaptiveLineLimit()
                        .minimumScaleFactor(0.76)
                    Text(state.sharedMarginSenderLabel.map { "Margin from \($0)" } ?? state.chapterTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.74))
                        .adaptiveLineLimit()
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
                        .foregroundStyle(state.isRecording ? state.recordingTint : .white.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(state.stateAccessibilityLabel(isStale: isStale))
                    Spacer(minLength: 4)
                    Text("\(max(0, min(100, state.progressPercent)))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }

                ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                    .tint(isLuminanceReduced ? .white.opacity(0.72) : Gate2LiveActivityAttributes.ContentState.progressTint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// The Lock Screen card. Internal, and compiled into the app as well as the widget, so an app-hosted test can lay it
/// out at real text sizes (#1940, LiveActivityLayoutTests).
struct Gate2LiveActivityView: View {
    let state: Gate2LiveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .adaptiveLineLimit()
                        .minimumScaleFactor(0.82)
                    Text(state.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .adaptiveLineLimit()
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                // The next-chapter action sits under the state word, in the header's free corner, so it adds no
                // height to the card and no tappable area over the titles (#1940).
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.headlineWord)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(state.isRecording ? state.recordingTint : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if state.sharedMarginSenderLabel == nil {
                        nextNavigation
                    }
                }
            }

            ProgressView(value: Double(max(0, min(100, state.progressPercent))), total: 100)
                .tint(state.offersResume(isStale: isStale) ? .white.opacity(0.45) : Gate2LiveActivityAttributes.ContentState.progressTint)

            if state.offersResume(isStale: isStale) {
                Label(Gate2LiveActivityCopy.pausedPrompt, systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

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

    /// The five circles and the mic always share one row, so the card keeps its height (#1940). At the default size
    /// they total about 308 pt against the Lock Screen's roughly 327 pt of content, and the circles are fixed-size
    /// controls (all at least 44 pt), not text. The next-chapter action sits in the header instead of this row,
    /// because a second row would push the card past the 160 pt the Lock Screen allows.
    private var transportControls: some View {
        HStack(spacing: Gate2ControlSize.rowSpacing) {
            playbackCircles
            Spacer(minLength: 0)
            recordButton
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var playbackCircles: some View {
        if state.canRun("skimBackward") {
            CompactRoundIntentButton(
                command: "skimBackward",
                systemImage: "backward.end.alt.fill",
                size: Gate2ControlSize.skim,
                accessibilityLabel: SkimDestinationLabel.accessibilityLabel(
                    destinationMs: state.skimBackwardDestinationMs, backward: true
                ),
                caption: state.skimBackwardDestinationMs.map(SkimDestinationLabel.time)
            )
        }
        if state.canRun("skipBack") {
            CompactRoundIntentButton(
                command: "skipBack",
                systemImage: "gobackward.15",
                size: Gate2ControlSize.skip,
                accessibilityLabel: Gate2LiveActivityAccessibility.label(forCommand: "skipBack")
            )
        }
        if state.canRun("togglePlayPause") {
            CompactPlayPauseButton(
                command: "togglePlayPause",
                isPlaying: state.status == "playing" || state.status == "starting"
            )
        }
        if state.canRun("skipForward") {
            CompactRoundIntentButton(
                command: "skipForward",
                systemImage: "goforward.15",
                size: Gate2ControlSize.skip,
                accessibilityLabel: Gate2LiveActivityAccessibility.label(forCommand: "skipForward")
            )
        }
        if state.canRun("skimForward") {
            CompactRoundIntentButton(
                command: "skimForward",
                systemImage: "forward.end.alt.fill",
                size: Gate2ControlSize.skim,
                accessibilityLabel: SkimDestinationLabel.accessibilityLabel(
                    destinationMs: state.skimForwardDestinationMs, backward: false
                ),
                caption: state.skimForwardDestinationMs.map(SkimDestinationLabel.time)
            )
        }
    }

    /// Skips to the next chapter or Shared Margin: a small "Next" chip in the header's trailing corner, under the state
    /// word. The listener hears the next title through its VoiceOver label. The chip is 24 pt tall and its tap area
    /// grows to 44 pt toward the progress bar, which is not tappable, and never over the titles or the transport row.
    @ViewBuilder
    private var nextNavigation: some View {
        if let nextChapterTitle = state.nextChapterTitle,
           let nextChapterId = state.nextChapterId {
            nextNavigationButton(title: nextChapterTitle, targetID: nextChapterId)
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if state.canRun("beginInterjection") || state.canRun("finishInterjection") {
            #if SM_LOCKED_MARGIN_SPIKE
            // Phone builds only: record in place, without opening the app (#3086).
            Button(intent: Gate2RecordMarginIntent(finish: state.isRecording)) {
                marginButtonImage
            }
            .accessibilityLabel(state.isRecording ? "Finish Margin" : "Add a Margin")
            #else
            Link(destination: Gate2CompactCommandURL.url(command: state.isRecording ? "finishInterjection" : "beginInterjection")) {
                marginButtonImage
            }
            .accessibilityLabel(state.isRecording ? "Finish Margin" : "Add a Margin")
            #endif
        }
    }

    private var marginButtonImage: some View {
        let diameter = Gate2ControlSize.record
        return Image(systemName: state.isRecording ? "checkmark" : "mic.fill")
            .font(.title2.weight(.semibold))
            .dynamicTypeSize(...Gate2ControlSize.glyphCeiling)
            .frame(width: diameter, height: diameter)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.16))
            .clipShape(Circle())
    }

    @ViewBuilder
    private func nextNavigationButton(title: String, targetID: String) -> some View {
        if state.nextNavigationKind == .sharedMargin {
            Button(intent: Gate2NextSharedMarginIntent(interjectionID: targetID)) {
                nextNavigationLabel(label: "Next Margin")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip to next Shared Margin")
        } else {
            Button(intent: Gate2NextChapterIntent(chapterId: targetID)) {
                nextNavigationLabel(label: "Next")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip to next chapter, \(title)")
        }
    }

    private func nextNavigationLabel(label: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Image(systemName: state.nextNavigationKind == .sharedMargin ? "text.bubble.fill" : "chevron.forward")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 8)
        .frame(minHeight: Gate2ControlSize.nextChipHeight)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
        .expandedHitArea(top: 4, bottom: 16)
    }
}

private struct Gate2SharedMarginButtons: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Button(intent: Gate2SharedMarginActionIntent(command: Gate2CompactApplicationCommand.listenToSharedMargin)) {
                Label(compact ? "Play" : "Listen", systemImage: "play.fill")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38)
                    .foregroundStyle(.white)
                    .background(Color.green.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .expandedHitArea(vertical: compact ? 7 : 3)
            }
            .accessibilityLabel(compact
                ? Gate2LiveActivityAccessibility.playSharedMargin
                : Gate2LiveActivityAccessibility.listenToSharedMargin)
            Button(intent: Gate2SharedMarginActionIntent(command: Gate2CompactApplicationCommand.dismissSharedMargin)) {
                Label(compact ? "Skip" : "Dismiss", systemImage: "xmark")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .expandedHitArea(vertical: compact ? 7 : 3)
            }
            .accessibilityLabel(compact
                ? Gate2LiveActivityAccessibility.skipSharedMargin
                : Gate2LiveActivityAccessibility.dismissSharedMargin)
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
    /// Skim's destination time, drawn under the icon inside the circle so the row keeps its height (#115).
    var caption: String? = nil

    var body: some View {
        Button(intent: Gate2CompactPlaybackIntent(command: command)) {
            Group {
                if let caption {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.body.weight(.semibold))
                        Text(caption)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                    }
                } else {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                }
            }
            .dynamicTypeSize(...(caption == nil ? Gate2ControlSize.glyphCeiling : Gate2ControlSize.captionedGlyphCeiling))
            .frame(width: size, height: size)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.16))
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel ?? Gate2LiveActivityAccessibility.label(forCommand: command))
    }
}

private struct CompactPlayPauseButton: View {
    let command: String
    let isPlaying: Bool

    private var size: CGFloat { Gate2ControlSize.play }

    var body: some View {
        Button(intent: Gate2CompactPlaybackIntent(command: command)) {
            playPauseLabel
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .accessibilityLabel(Gate2LiveActivityAccessibility.playPauseLabel(isPlaying: isPlaying))
    }

    private var playPauseLabel: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.title.weight(.bold))
            .dynamicTypeSize(...Gate2ControlSize.glyphCeiling)
            .frame(width: size, height: size)
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
                .adaptiveLineLimit()
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .expandedHitArea(vertical: 3)
        }
        .buttonStyle(.plain)
    }
}

/// Sizes of the round controls (#1940). They are fixed-size controls, every one at least the 44 pt touch target. At
/// the default text size the five transport circles and the mic total 284 pt, plus six 4 pt gaps (the spacer before
/// the mic takes one on each side), so they share one row of the Lock Screen's roughly 327 pt of content (311 pt on a
/// 375 pt-wide phone). Text inside a circle follows the text size up to a ceiling, because the circle does not grow.
enum Gate2ControlSize {
    static let skim: CGFloat = 44
    static let skip: CGFloat = 48
    static let play: CGFloat = 56
    static let record: CGFloat = 44
    static let rowSpacing: CGFloat = 4
    /// 24 pt, not 28: under the state word (about 16 pt) it keeps the header column no taller than the titles (22 + 2 +
    /// 16 pt), which keeps a paused card with a next chapter under 160 pt (LiveActivityLayoutTests).
    static let nextChipHeight: CGFloat = 24
    /// A glyph inside a circle stops growing at this size.
    static let glyphCeiling: DynamicTypeSize = .accessibility1
    /// A skim circle also holds its destination time under the icon, so its contents stop sooner.
    static let captionedGlyphCeiling: DynamicTypeSize = .xLarge
}

private struct AdaptiveLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }
}

private extension View {
    /// One line at ordinary text sizes, two at accessibility sizes, so a long title wraps instead of shrinking to
    /// nothing (#1940).
    func adaptiveLineLimit() -> some View {
        modifier(AdaptiveLineLimit())
    }

    /// Grows the hit area by different amounts above and below, for a control with something tappable or readable on
    /// one side only (#1940).
    func expandedHitArea(top: CGFloat, bottom: CGFloat) -> some View {
        padding(.top, top).padding(.bottom, bottom)
            .contentShape(Rectangle())
            .padding(.top, -top).padding(.bottom, -bottom)
    }

    /// Grows the hit area to 44 pt without moving anything: the layout keeps its size (#1929).
    func expandedHitArea(vertical: CGFloat) -> some View {
        padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.vertical, -vertical)
    }
}
