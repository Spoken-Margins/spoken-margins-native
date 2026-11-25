import SwiftUI
import SessionKit

/// Continue on an item with shared Margins the listener hasn't heard asks first (#474): hear them in place, or listen
/// without them. After an import, Continue used to land past them. The owner expected to hear them in the context of
/// the episode and then carry on from there.
private struct NewMarginsOffer: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var offer: NewMarginsOfferRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            offer?.catchUp?.offerTitle ?? "New Margins to hear",
            isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
            titleVisibility: .visible,
            presenting: offer
        ) { offer in
            if let catchUp = offer.catchUp {
                catchUpAnswers(offer, catchUp: catchUp)
            } else {
                answers(offer)
            }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(SharedMarginReview.offerMessage(for: offer.entries))
        }
    }

    /// A finished item with a reply to the listener (#4785): hear only the new ones and stop there, or play the item as
    /// today with the new ones left new.
    @ViewBuilder
    private func catchUpAnswers(_ offer: NewMarginsOfferRequest, catchUp: ConversationCatchUp) -> some View {
        Button(catchUp.offerFirstButton) {
            model.reviewNewMargins(itemId: offer.itemId, thenContinue: false, entries: offer.entries, catchUp: true)
        }
            .accessibilityIdentifier("newMarginsOffer.review")
        if offer.catchUpContinues {
            Button("Continue") { model.continueWithoutNewMargins(offer) }
                .accessibilityIdentifier("newMarginsOffer.skip")
        } else {
            Button("Play from the start") { model.startItemFromBeginning(itemId: offer.itemId, entries: offer.entries) }
                .accessibilityIdentifier("newMarginsOffer.skip")
        }
    }

    @ViewBuilder
    private func answers(_ offer: NewMarginsOfferRequest) -> some View {
        Button("Hear new Margins first") {
            model.reviewNewMargins(itemId: offer.itemId, thenContinue: true, entries: offer.entries)
        }
            .accessibilityIdentifier("newMarginsOffer.review")
        if offer.placeIsAtEnd {
            // Resuming at the very end would play the last seconds and finish; starting over is the way past (#4125).
            Button("Play from the start") { model.startItemFromBeginning(itemId: offer.itemId, entries: offer.entries) }
                .accessibilityIdentifier("newMarginsOffer.skip")
        } else {
            Button("Listen without them") { model.continueWithoutNewMargins(offer) }
                .accessibilityIdentifier("newMarginsOffer.skip")
        }
    }
}

extension View {
    /// Shows the offer while `offer` is set; see `Gate1AppModel.continueListening(itemId:offer:)`.
    func newMarginsOffer(_ offer: Binding<NewMarginsOfferRequest?>) -> some View {
        modifier(NewMarginsOffer(offer: offer))
    }
}
