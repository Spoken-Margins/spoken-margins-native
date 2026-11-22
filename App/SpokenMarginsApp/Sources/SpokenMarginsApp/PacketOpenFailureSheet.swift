import SessionKit
import SwiftUI

/// The sheet over whatever is open when a friend's share link or `.spokenmargins` file fails to open (#3801): an icon,
/// the headline, one line, and one next step. The words are `PacketOpenFailureSheetContent`'s. The icon is orange and
/// shaped like a warning, so the words carry the meaning and colour never does alone.
struct PacketOpenFailureSheet: View {
    let content: PacketOpenFailureSheetContent
    let showsTryAgain: Bool
    let isRetrying: Bool
    let tryAgain: () -> Void
    let close: () -> Void

    @AccessibilityFocusState private var headlineHasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(AppColors.warningText)
                .accessibilityHidden(true)
            Text(content.headline)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headlineHasFocus)
                .accessibilityIdentifier("packetOpenFailure.headline")
            Text(content.line)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("packetOpenFailure.line")
            Spacer(minLength: 8)
            buttons
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.background)
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packetOpenFailure.sheet")
        .onAppear { headlineHasFocus = true }
        // A failure that replaces this one is read out again, from its headline.
        // The focus is dropped for a turn first: two writes in the same turn would be merged into none.
        .onChange(of: content.headline) {
            headlineHasFocus = false
            Task { @MainActor in
                await Task.yield()
                headlineHasFocus = true
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if showsTryAgain {
            Button(action: tryAgain) {
                HStack(spacing: 8) {
                    if isRetrying { ProgressView().accessibilityHidden(true) }
                    Text("Try Again")
                }
                .frame(maxWidth: .infinity)
            }
            .filledActionButton()
            .controlSize(.large)
            .disabled(isRetrying)
            .accessibilityIdentifier("packetOpenFailure.tryAgain")
            Button(action: close) {
                Text("Close").frame(maxWidth: .infinity).minimumTapTarget()
            }
            .controlSize(.large)
            .accessibilityIdentifier("packetOpenFailure.close")
        } else {
            Button(action: close) {
                Text("OK").frame(maxWidth: .infinity)
            }
            .filledActionButton()
            .controlSize(.large)
            .accessibilityIdentifier("packetOpenFailure.ok")
            if let id = content.reportLinkID, let url = ShareLinkReport.pageURL(forLinkId: id) {
                // The share page's own report form, in Safari, as the report link on the item screen does.
                Link(destination: url) {
                    Text("Report this link").frame(maxWidth: .infinity).minimumTapTarget()
                }
                .accessibilityIdentifier("packetOpenFailure.report")
            }
        }
    }
}

/// Hosts the failure sheet on the root view. When the listener closes it, the first-launch drawer a failed friend's
/// file withdrew comes back (`CatalogDrawerModel.friendFileFailed`), once the sheet is gone.
private struct PacketOpenFailureSheetModifier: ViewModifier {
    @ObservedObject var model: Gate1AppModel
    @ObservedObject var presenter: PacketOpenFailurePresenter
    @ObservedObject var drawer: CatalogDrawerModel

    func body(content: Content) -> some View {
        content.trackedSheet(
            item: Binding(get: { presenter.presented }, set: { if $0 == nil { presenter.close() } }),
            onDismiss: {
                if presenter.takeCloseNotice() { drawer.friendFileFailed(at: FirstLaunchWelcomeOrder.Place(model)) }
            },
            content: { presented in
                PacketOpenFailureSheet(
                    content: presented.content,
                    showsTryAgain: presented.showsTryAgain,
                    isRetrying: presenter.isRetrying,
                    tryAgain: presenter.tryAgain,
                    close: presenter.close
                )
            }
        )
    }
}

extension View {
    func packetOpenFailureSheet(model: Gate1AppModel, drawer: CatalogDrawerModel) -> some View {
        modifier(PacketOpenFailureSheetModifier(model: model, presenter: model.packetOpenFailures, drawer: drawer))
    }
}
