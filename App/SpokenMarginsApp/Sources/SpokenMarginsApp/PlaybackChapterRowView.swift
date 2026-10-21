import SwiftUI
import SessionKit

struct PlaybackChapterRowView: View {
    let title: String?
    let sourceTitle: String
    /// Left and right of the title (#1666). Skim sits here, not under the transport, and keeps its place when the
    /// listener crosses a chapter: the right side is Skim forward, else Next chapter, else a dimmed Skim.
    var backward: NextChapterSummaryRule.ChapterRowControl = .hidden
    var forward: NextChapterSummaryRule.ChapterRowControl = .hidden
    var skimBackwardTitle = ""
    var skimForwardTitle = ""
    /// Why forward Skim can't be pressed, said by the Next chapter that stands in for it (#2185).
    var skimForwardUnavailable: SkimUnavailableReason?
    /// A recording locks Skim, as it did when the arrows sat in the transport.
    var skimLocked = false
    /// What the silence is while playback starts. It takes the title's place in this fixed-height row, so the
    /// dock never changes height while the listener scrubs or starts a source (#357, #430).
    var waitingText: String?
    let showItem: () -> Void
    let nextChapter: () -> Void
    var skimBackward: () -> Void = {}
    var skimForward: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let skimBackwardSymbol = "backward.end.alt.fill"
    static let skimForwardSymbol = "forward.end.alt.fill"
    static let nextChapterSymbol = "forward.end"
    /// An arrow to a line, unlike Skim's filled triangle and bar, so the plain jump never passes for Skim (#2185).
    static let nextChapterInSkimSlotSymbol = "arrow.right.to.line"
    static func nextChapterInSkimSlotLabel(_ reason: SkimUnavailableReason?) -> String {
        "Next chapter. " + (reason ?? .noSceneSummary).message
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes this row is the only place the chapter title shows, so the title gets the
                // full width and the skim controls sit under it instead of squeezing it between them (#1933).
                // The control line is always laid out, with its 44 pt slot, so the row keeps one height whether
                // Skim, Next chapter or neither is showing (#357, #430).
                VStack(spacing: 4) {
                    titleView
                    HStack(spacing: 8) {
                        backwardControl
                        Spacer(minLength: 0)
                        forwardControl
                    }
                    .frame(minHeight: 44)
                }
            } else {
                HStack(spacing: 8) {
                    backwardControl
                    titleView
                    forwardControl
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// One line at default sizes; up to two at accessibility sizes, where a one-line title showed a few characters.
    private var titleLineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    /// Two lines are reserved at accessibility sizes, so a short title, a long one and the waiting text all take the
    /// same height and the dock does not move when the listener starts a source or crosses a chapter (#357, #430).
    private var reservesTitleSpace: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private var titleView: some View {
        if let waitingText {
            Text(waitingText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.watchSecondary)
                .lineLimit(titleLineLimit, reservesSpace: reservesTitleSpace)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("playback.starting.label")
        } else {
            Button(action: showItem) {
                Text(PlaybackSourceLabels.chapterTitle(title, sourceTitle: sourceTitle))
                    .lineLimit(titleLineLimit, reservesSpace: reservesTitleSpace)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    // A plain button takes taps only on what it draws: a short title left most of the row dead (#430).
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("playback.dock.chapter.button")
        }
    }

    @ViewBuilder private var backwardControl: some View {
        if backward != .hidden {
            skimButton(backward: true, enabled: backward == .skim)
        }
    }

    @ViewBuilder private var forwardControl: some View {
        switch forward {
        case .skim, .skimDisabled:
            skimButton(backward: false, enabled: forward == .skim)
        case .nextChapter:
            Button(action: nextChapter) {
                Image(systemName: Self.nextChapterSymbol)
                    .minimumTapTarget()
            }
            .accessibilityLabel("Next chapter")
            .accessibilityIdentifier("playback.nextChapter.button")
        case .nextChapterInSkimSlot:
            // Skim can't be pressed here, so this is a plain chapter jump: its own arrow, never Skim's (#2185).
            Button(action: nextChapter) {
                Image(systemName: Self.nextChapterInSkimSlotSymbol)
                    .minimumTapTarget()
            }
            .accessibilityLabel(Self.nextChapterInSkimSlotLabel(skimForwardUnavailable))
            .accessibilityIdentifier("playback.nextChapter.button")
        case .hidden:
            EmptyView()
        }
    }

    /// A compact Skim arrow. It says where it goes ("Skim to 36:11") for VoiceOver; a dimmed one reads as unavailable.
    private func skimButton(backward isBackward: Bool, enabled: Bool) -> some View {
        Button(action: isBackward ? skimBackward : skimForward) {
            Image(systemName: isBackward ? Self.skimBackwardSymbol : Self.skimForwardSymbol)
                .minimumTapTarget()
        }
        .disabled(!enabled || skimLocked)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel((isBackward ? skimBackwardTitle : skimForwardTitle) + " by scene summary")
        .accessibilityIdentifier(isBackward ? "playback.skim.backward.button" : "playback.skim.forward.button")
    }
}
