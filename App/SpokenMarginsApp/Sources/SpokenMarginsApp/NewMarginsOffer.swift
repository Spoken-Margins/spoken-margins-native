import SwiftUI
import SessionKit

/// Continue on an item with shared Margins the listener hasn't heard asks first (#474): hear them in place, or listen
/// without them. After an import, Continue used to land past them. The owner expected to hear them in the context of
/// the episode and then carry on from there.
private struct NewMarginsOffer: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var itemId: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "New Margins to hear",
            isPresented: Binding(get: { itemId != nil }, set: { if !$0 { itemId = nil } }),
            titleVisibility: .visible,
            presenting: itemId
        ) { id in
            Button("Hear new Margins first") { model.reviewNewMargins(itemId: id, thenContinue: true) }
                .accessibilityIdentifier("newMarginsOffer.review")
            Button("Listen without them") { model.continueWithoutNewMargins(itemId: id) }
                .accessibilityIdentifier("newMarginsOffer.skip")
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text(SharedMarginReview.offerMessage(for: model.newSharedMargins(itemId: id)))
        }
    }
}

extension View {
    /// Shows the offer while `itemId` is set; see `Gate1AppModel.continueListening(itemId:offer:)`.
    func newMarginsOffer(itemId: Binding<String?>) -> some View {
        modifier(NewMarginsOffer(itemId: itemId))
    }
}
