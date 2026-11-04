import SessionKit
import SwiftUI

/// The shared-packet sheet, shown only for a file the listener has a choice to make on (#3291). A friend's file that
/// opens directly (`SpokenMarginsPackageImportReview.opensDirectly`) is imported as it comes up instead, and its item's
/// screen opens, once no Margin is being recorded or written. If that import fails, the coordinator turns the flag off and the sheet comes up with the error, also once no Margin is being recorded or written.
struct SharedPacketImportSheet<Sheet: View>: ViewModifier {
    @ObservedObject var model: Gate1AppModel
    @ViewBuilder let sheet: () -> Sheet

    private var sheetReview: Binding<SpokenMarginsPackageImportReview?> {
        Binding(
            get: { model.packageImportSheetReview },
            set: { newValue in
                // The sheet going away because a review that opens directly came up, or because a Margin was started
                // (from the Lock Screen, say), is not the listener's Cancel.
                if newValue == nil, model.packageImportSheetReview == nil { return }
                model.spokenMarginsPackageImportReview = newValue
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetReview) { _ in sheet() }
            .onChange(of: model.spokenMarginsPackageImportReview?.id, initial: true) {
                model.openSharedPacketDirectlyIfReady()
            }
            .onChange(of: model.recordingNavigationIsLocked) {
                model.openSharedPacketDirectlyIfReady()
                model.openDeferredImportedItemIfReady()
            }
    }
}
