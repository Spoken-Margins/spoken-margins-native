import SwiftUI
import SessionKit

/// The card for a friend's Margin (or a review of new Margins) that sits in a fixed slot above the title on the Now
/// screen (#3220). It is pinned in a safe-area inset, not a child of the scroll view, so it never scrolls away. Every
/// stage has the same three parts (headline, one line of explanation, one row of buttons), and the card is as tall as
/// its words: no blank row (#3597). The words and the buttons are `PinnedMarginCard`; this only draws them.
struct PinnedMarginCardView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playbackTick = 0 // bumped by each progress tick: the countdown follows the playhead (#2074)
    @AccessibilityFocusState private var focusedPart: Part?

    /// The parts VoiceOver or Switch Control can focus, so the tone-only card's timer waits while one has focus (#3720).
    private enum Part: Hashable {
        case headline, detail
        case button(PinnedMarginCard.Action.Job)
    }

    private var moment: MarginMomentSequence? { model.marginMoment }
    private var isReview: Bool { moment?.isReview == true }

    /// Nothing while the slot is free: the card exists for the whole of a friend's listen, and only then.
    var body: some View {
        let _ = playbackTick
        Group {
            // The voice's own clock runs while the episode is paused, so no playback tick moves this: refresh twice a second.
            if model.pinnedMarginCard != nil {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if let card = model.pinnedMarginCard { content(card) }
                }
            }
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    /// At the accessibility text sizes the headline and the buttons wrap and stack instead of clipping (#1933).
    private var isLargeText: Bool { dynamicTypeSize >= .xLarge }

    private func content(_ card: PinnedMarginCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(card))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text(card.headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    // One line at regular sizes, shrunk before it is cut, so a long name does not make the card taller
                    // when a lead-in becomes a voice. It wraps at the larger sizes (#3597).
                    .lineLimit(isLargeText ? nil : 1)
                    .minimumScaleFactor(isLargeText ? 1 : 0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .numericTextTransition()
                    .accessibilityFocused($focusedPart, equals: .headline)
                    .accessibilityIdentifier(headlineIdentifier(card))
                Spacer(minLength: 8)
                if let position = card.position {
                    Text(position)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .accessibilityIdentifier(isReview ? "review.progress" : "marginCard.position")
                }
            }
            Text(detail(card))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                // The transcript of a Margin waiting for a tap is capped at every size, so Listen and Dismiss stay on the screen.
                .lineLimit(card.stage == .waitingForTap ? (isLargeText ? 4 : 2) : (isLargeText ? nil : 2))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityFocused($focusedPart, equals: .detail)
                .accessibilityIdentifier("marginCard.detail")
            buttons(card)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("marginCard")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in FeedbackBannerHold.marginCard.setTouched(true) }
                .onEnded { _ in FeedbackBannerHold.marginCard.setTouched(false) }
        )
        .onChange(of: focusedPart) { _, part in FeedbackBannerHold.marginCard.setFocused(part != nil) }
        .onDisappear { FeedbackBannerHold.marginCard.reset() }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
    }

    private func icon(_ card: PinnedMarginCard) -> String {
        switch card.stage {
        case .speaking, .reading, .voicePaused, .loading: "waveform"
        case .failed: "exclamationmark.triangle"
        case .comingUp, .waitingForTap, .upNext: "text.bubble"
        case .answerSaved: "checkmark.circle"
        case .lastMargin: "text.bubble"
        }
    }

    /// The identifiers a review's UI tests already look for, kept on the same words.
    private func headlineIdentifier(_ card: PinnedMarginCard) -> String {
        guard isReview else { return "marginCard.headline" }
        if case .comingUp = card.stage { return "review.comingUp" }
        if card.stage == .speaking || card.stage == .reading || card.stage == .voicePaused { return "review.playing" }
        return "marginCard.headline"
    }

    /// The one line under the headline: what is wrong with the Margin first (being placed, an approximate place), then
    /// what a reply answers, then what the stage means.
    private func detail(_ card: PinnedMarginCard) -> String {
        // A Margin waiting for a tap shows what it says, so the listener can choose. One that plays by itself after a beat
        // keeps the card's own line: it would change the card's height for 420 ms.
        if card.stage == .waitingForTap, let pending = model.pendingImportedCommentary,
           let said = PinnedMarginCard.waitingTranscript(
               pending.interjection.approvedTranscript, playsByItself: pending.layer.revealMode == .guided) {
            return said
        }
        guard let moment, model.playingImportedCommentary == nil, model.pendingImportedCommentary == nil else { return card.detail }
        let current = moment.playing ?? moment.target
        if let placing = model.sharedMarginRows.first(where: { $0.id == current.marginId })?.placementStatus.positionDescription {
            return placing
        }
        if let caption = current.caption { return caption }
        if !moment.isPlayingMargin, current.isApproximate || model.marginMomentPositionIsApproximate {
            return "Approximate position: ads can differ between copies."
        }
        return card.detail
    }

    /// One row, one button per job; a stage with nowhere to go draws no row at all.
    @ViewBuilder
    private func buttons(_ card: PinnedMarginCard) -> some View {
        let actions = card.actions
        if !actions.isEmpty {
            let row = isLargeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            row { ForEach(actions, id: \.job) { button($0) } }
        }
    }

    private func button(_ action: PinnedMarginCard.Action) -> some View {
        // Held for a moment while a Margin is being recorded: dimmed, not hidden, and `SecondaryButtonStyle` has no disabled look.
        let held = action.job.followsNavigationLock && model.recordingNavigationIsLocked
        // The identifier goes on the button itself, not on a container around the switch (#2898).
        return styledButton(action)
            .disabled(held)
            .opacity(held ? 0.45 : 1)
            .accessibilityFocused($focusedPart, equals: .button(action.job))
            .accessibilityHint(action.hint)
            .accessibilityIdentifier(identifier(action.job))
    }

    @ViewBuilder
    private func styledButton(_ action: PinnedMarginCard.Action) -> some View {
        switch action.prominence {
        case .primary:
            Button { perform(action.job) } label: { wide(action.title, symbol(action.job), shares: action.job != .retry) }
                .buttonStyle(PrimaryButtonStyle())
        case .secondary:
            Button { perform(action.job) } label: { wide(action.title, symbol(action.job), shares: action.job != .retry) }
                .buttonStyle(SecondaryButtonStyle())
        case .quiet:
            Button { perform(action.job) } label: { Text(action.title).minimumTapTarget() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    /// Retry keeps the room its word needs; the other button takes the rest of the row, so "Skip this Margin" fits.
    private func wide(_ title: String, _ systemImage: String, shares: Bool = true) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(isLargeText ? nil : 1)
            .minimumScaleFactor(isLargeText ? 1 : 0.8)
            .frame(maxWidth: shares ? .infinity : nil)
            .layoutPriority(shares ? 0 : 1)
    }

    private func perform(_ job: PinnedMarginCard.Action.Job) {
        switch job {
        case .goToNextMargin: model.goToNextMargin()
        case .skipThisMargin: skip()
        case .retry: model.retryImportedCommentary()
        case .playMomentNow: model.playMarginMomentNow()
        case .keepListening, .stopReview, .stopPlayingMine: model.endMarginMoment()
        case .listen: model.listenToPendingImportedCommentary()
        case .dismiss: model.dismissPendingImportedCommentary()
        }
    }

    /// The identifiers the UI tests already look for, kept on the same jobs.
    private func identifier(_ job: PinnedMarginCard.Action.Job) -> String {
        switch job {
        case .goToNextMargin: "marginCard.next"
        case .skipThisMargin: "marginMoment.skip"
        case .retry: "importedCommentary.retry"
        case .playMomentNow: "marginMoment.playNow"
        case .keepListening, .stopReview, .stopPlayingMine: "marginMoment.end"
        case .listen: "importedCommentary.listen"
        case .dismiss: "importedCommentary.dismiss"
        }
    }

    private func symbol(_ job: PinnedMarginCard.Action.Job) -> String {
        switch job {
        case .goToNextMargin: "forward.end.alt.fill"
        case .skipThisMargin: "forward.end.fill"
        case .retry: "arrow.clockwise"
        case .playMomentNow, .listen: "play.fill"
        case .keepListening, .stopReview, .stopPlayingMine, .dismiss: "xmark"
        }
    }

    private func skip() {
        if model.playingImportedCommentary != nil { model.returnToSourceFromImportedCommentary() } else { model.skipMarginMomentVoice() }
    }
}
