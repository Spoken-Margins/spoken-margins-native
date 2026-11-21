import SessionKit
import SwiftUI

/// The Tidy version card on a Margin's details screen (#4339): a tidy version of what the author said, offered once the
/// transcript is ready. Nothing changes until they choose; the transcript and the recording are never replaced.
///
/// What the card shows comes from `MarginTidyCardState` (SessionKit): no card for a written Margin, a transcript that isn't
/// ready, or a Margin answered with "Keep mine"; a proposal for one not yet answered; one line for an approved tidy.
/// An optional suggestion never shows an error: if the model can't tidy, the filler-only version is offered, and if that
/// is the same words nothing shows.
/// A proposal and the transcript it was made from, which `useTidy` checks before it saves anything.
struct MarginTidyOffer: Equatable {
    let proposal: MarginTidyProposal
    let basedOn: String
}

/// What the card has to show for one Margin. The details screen owns it, so it knows whether the card has a row at all
/// (a list row with nothing in it is still a blank row) and so one request is made per open, not one per redraw.
@MainActor
final class MarginTidyCardModel: ObservableObject {
    @Published private(set) var offer: MarginTidyOffer?
    @Published private(set) var isTidying = false

    /// What a request is for: another Margin, other words or another answer starts a new request and drops the old one.
    struct RequestKey: Equatable {
        let marginId: String
        let state: MarginTidyCardState
    }

    static func key(for margin: Interjection) -> RequestKey {
        RequestKey(marginId: margin.id, state: MarginTidyCardState.state(for: margin))
    }

    /// Whether the card has anything to draw for `margin` right now.
    func showsCard(for margin: Interjection) -> Bool {
        switch MarginTidyCardState.state(for: margin) {
        case .hidden: return false
        case .used: return true
        case .candidate(let transcript): return isTidying || offer?.basedOn == transcript
        }
    }

    func refresh(for margin: Interjection, using model: Gate1AppModel) async {
        guard case .candidate(let transcript) = MarginTidyCardState.state(for: margin) else {
            offer = nil
            isTidying = false
            return
        }
        offer = nil
        // Only the on-device model takes a moment; the filler-only version is ready at once.
        isTidying = model.localFoundationModelAvailable
        let proposal = await model.marginTidyProposal(for: margin, transcript: transcript)
        guard !Task.isCancelled else { return }
        offer = proposal.map { MarginTidyOffer(proposal: $0, basedOn: transcript) }
        isTidying = false
    }
}

struct MarginTidyCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The Margin as it is stored now.
    let margin: Interjection
    let card: MarginTidyCardModel

    var body: some View {
        switch MarginTidyCardState.state(for: margin) {
        case .hidden:
            EmptyView()
        case .used:
            usedLine
        case .candidate(let transcript):
            if let offer = card.offer, offer.basedOn == transcript {
                proposalCard(offer)
            } else if card.isTidying {
                tidyingLine
            }
        }
    }

    private var tidyingLine: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Tidying on this iPhone…")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("marginDetail.tidy.tidying")
    }

    private func proposalCard(_ offer: MarginTidyOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidy version")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                Text(offer.proposal.text)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MarginTidyCardState.caption(for: offer.proposal.source))
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tidy version: \(offer.proposal.text)")
            .accessibilityIdentifier("marginDetail.tidy.proposal")
            actions(offer)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("marginDetail.tidy.card")
    }

    @ViewBuilder private func actions(_ offer: MarginTidyOffer) -> some View {
        let use = Button("Use tidy version") {
            model.useTidyVersion(margin, proposal: offer.proposal, basedOn: offer.basedOn)
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("marginDetail.tidy.use.button")
        let keep = Button("Keep mine") { model.keepMarginAsSpoken(margin) }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("marginDetail.tidy.keep.button")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                use.frame(maxWidth: .infinity)
                keep.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 8) {
                use.frame(maxWidth: .infinity)
                keep.frame(maxWidth: .infinity)
            }
        }
    }

    private var usedLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Showing your tidy version.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("marginDetail.tidy.used.label")
            Button("Use my original words", systemImage: "arrow.uturn.backward") {
                model.useOriginalWords(of: margin)
            }
            .accessibilityIdentifier("marginDetail.tidy.original.button")
        }
    }
}
