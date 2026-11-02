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
            "New Margins to hear",
            isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
            titleVisibility: .visible,
            presenting: offer
        ) { offer in
            Button("Hear new Margins first") {
                model.reviewNewMargins(itemId: offer.itemId, thenContinue: true, entries: offer.entries)
            }
                .accessibilityIdentifier("newMarginsOffer.review")
            Button("Listen without them") { model.continueWithoutNewMargins(offer) }
                .accessibilityIdentifier("newMarginsOffer.skip")
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(SharedMarginReview.offerMessage(for: offer.entries))
        }
    }
}

extension View {
    /// Shows the offer while `offer` is set; see `Gate1AppModel.continueListening(itemId:offer:)`.
    func newMarginsOffer(_ offer: Binding<NewMarginsOfferRequest?>) -> some View {
        modifier(NewMarginsOffer(offer: offer))
    }
}
