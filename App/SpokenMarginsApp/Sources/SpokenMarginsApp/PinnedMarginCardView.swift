import SwiftUI
import SessionKit

/// The card for a friend's Margin (or a review of new Margins) that sits in a fixed slot above the title on the Now
/// screen (#3220). It is pinned in a safe-area inset, not a child of the scroll view, so it never scrolls away. Every
/// stage has the same three rows (headline, one line of explanation, buttons), so the slot keeps its height and the
/// title below never moves when a Margin starts or ends. The words are `PinnedMarginCard`; this only draws them.
struct PinnedMarginCardView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var playbackTick = 0 // bumped by each progress tick: the countdown follows the playhead (#2074)

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

    private func content(_ card: PinnedMarginCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(card))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text(card.headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .numericTextTransition()
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
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                .accessibilityIdentifier("marginCard.detail")
            // Always the same two rows, whichever stage the card is in, so its height never changes within a listen.
            HStack(spacing: 8) { actionButtons(card) }
                .frame(minHeight: 44)
            HStack(spacing: 8) { endButton(card) }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("marginCard")
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
    }

    private func icon(_ card: PinnedMarginCard) -> String {
        switch card.stage {
        case .speaking, .voicePaused, .loading: "waveform"
        case .failed: "exclamationmark.triangle"
        case .comingUp, .waitingForTap, .upNext: "text.bubble"
        }
    }

    /// The identifiers a review's UI tests already look for, kept on the same words.
    private func headlineIdentifier(_ card: PinnedMarginCard) -> String {
        guard isReview else { return "marginCard.headline" }
        if case .comingUp = card.stage { return "review.comingUp" }
        if card.stage == .speaking || card.stage == .voicePaused { return "review.playing" }
        return "marginCard.headline"
    }

    /// The one line under the headline: what is wrong with the Margin first (being placed, an approximate place), then
    /// what a reply answers, then what the stage means.
    private func detail(_ card: PinnedMarginCard) -> String {
        // A Margin waiting for a tap shows what it says, so the listener can choose.
        if card.stage == .waitingForTap, let said = model.pendingImportedCommentary?.interjection.approvedTranscript, !said.isEmpty {
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

    @ViewBuilder
    private func actionButtons(_ card: PinnedMarginCard) -> some View {
        switch card.stage {
        case .comingUp:
            Button(action: model.playMarginMomentNow) { wide("Play it now", "play.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("marginMoment.playNow")
        case .speaking, .voicePaused, .loading:
            Button(action: skip) { wide(skipTitle, "forward.end.fill") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("marginMoment.skip")
        case .waitingForTap:
            Button(action: model.listenToPendingImportedCommentary) { wide("Listen", "play.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("importedCommentary.listen")
        case .failed:
            Button(action: model.retryImportedCommentary) { wide("Retry", "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("importedCommentary.retry")
        case .upNext:
            EmptyView()
        }
        Button(action: model.goToNextMargin) { wide("Next Margin", "forward.end.alt.fill") }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.canGoToNextMargin)
            .accessibilityIdentifier("marginCard.next")
    }

    private func wide(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func endButton(_ card: PinnedMarginCard) -> some View {
        if card.stage == .waitingForTap {
            Button("Dismiss", action: model.dismissPendingImportedCommentary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minHeight: 44)
                .accessibilityIdentifier("importedCommentary.dismiss")
        } else if model.playingImportedCommentary == nil, let moment, isReview || !moment.isPlayingMargin {
            Button(isReview ? "Stop review" : (moment.phase == .leadIn ? "Cancel" : "Stop playing my Margins"), action: model.endMarginMoment)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minHeight: 44)
                .accessibilityIdentifier("marginMoment.end")
        }
    }

    /// "Skip Margin" in a review that has more to come, else "Skip to the item", as the old cards said.
    private var skipTitle: String {
        if let moment, moment.isReview, !moment.unplayed.isEmpty { return "Skip Margin" }
        return "Skip to the item"
    }

    private func skip() {
        if model.playingImportedCommentary != nil { model.returnToSourceFromImportedCommentary() } else { model.skipMarginMomentVoice() }
    }
}
