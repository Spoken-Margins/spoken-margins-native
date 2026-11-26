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

/// Hosts the failure sheet on the root view while no first-launch drawer is up. When the listener closes it, the drawer
/// a failed friend's file withdrew comes back (`CatalogDrawerModel.friendFileFailed`), once the sheet is gone. With the
/// drawer up the drawer hosts it instead (`PacketOpenFailureDrawerSheetModifier`): a root sheet cannot present over it.
private struct PacketOpenFailureSheetModifier: ViewModifier {
    @ObservedObject var model: Gate1AppModel
    @ObservedObject var presenter: PacketOpenFailurePresenter
    @ObservedObject var drawer: CatalogDrawerModel

    private var hosts: Bool { PacketOpenFailureHost.hosting(drawerIsPresented: drawer.isPresented) == .root }

    func body(content: Content) -> some View {
        content.trackedSheet(
            item: Binding(
                get: { hosts ? presenter.presented : nil },
                set: { if $0 == nil, hosts { presenter.close() } }
            ),
            onDismiss: { presenter.sheetDismissed() },
            content: { presented in PacketOpenFailureSheet(presenter: presenter, presented: presented) }
        )
    }
}

/// Hosts the failure sheet from inside the first-launch drawer, which a paste with picks leaves up: the sheet cannot
/// present from the root over it, so the failure would never show and the drawer would never be told (#3782).
private struct PacketOpenFailureDrawerSheetModifier: ViewModifier {
    @ObservedObject var presenter: PacketOpenFailurePresenter
    @ObservedObject var drawer: CatalogDrawerModel

    private var hosts: Bool { PacketOpenFailureHost.hosting(drawerIsPresented: drawer.isPresented) == .drawer }

    func body(content: Content) -> some View {
        content.trackedSheet(
            item: Binding(
                get: { hosts ? presenter.presented : nil },
                set: { if $0 == nil, hosts { presenter.close() } }
            ),
            // The drawer is up, so it was never withdrawn: `onCloseNotice` only tells it no friend's item is coming.
            onDismiss: { presenter.sheetDismissed() },
            content: { presented in PacketOpenFailureSheet(presenter: presenter, presented: presented) }
        )
    }
}

extension PacketOpenFailureSheet {
    fileprivate init(presenter: PacketOpenFailurePresenter, presented: PacketOpenFailurePresenter.Presented) {
        self.init(
            content: presented.content,
            showsTryAgain: presented.showsTryAgain,
            isRetrying: presenter.isRetrying,
            tryAgain: presenter.tryAgain,
            close: presenter.close
        )
    }
}

extension View {
    func packetOpenFailureSheet(model: Gate1AppModel, drawer: CatalogDrawerModel) -> some View {
        modifier(PacketOpenFailureSheetModifier(model: model, presenter: model.packetOpenFailures, drawer: drawer))
    }

    /// For the first-launch drawer's own view; see `PacketOpenFailureDrawerSheetModifier`.
    func packetOpenFailureSheet(presenter: PacketOpenFailurePresenter, drawer: CatalogDrawerModel) -> some View {
        modifier(PacketOpenFailureDrawerSheetModifier(presenter: presenter, drawer: drawer))
    }
}
