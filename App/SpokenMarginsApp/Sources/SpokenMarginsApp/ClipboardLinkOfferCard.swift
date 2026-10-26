import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// What the Library knows about a copied link (#1379). It looks at the clipboard only through the change
/// count and iOS's pattern check for a web link, neither of which reads the copied text or shows the
/// "Allow Paste" alert, so the app never appears to read the clipboard. The link itself is read when the
/// listener taps a system Paste button on the card.
@MainActor
final class ClipboardLinkOfferModel: ObservableObject {
    private static let handledKey = "library.clipboardLinkOffer.handledChangeCount"

    @Published private(set) var offer: ClipboardLinkOffer
    /// The listener tapped a Paste button on the card, and the import hasn't succeeded yet.
    @Published private(set) var isAdding = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.handledKey) as? Int
        offer = ClipboardLinkOffer(handledChangeCount: stored)
    }

    /// The card shows while a copied link is on offer, and while this card's own import is running or failed.
    var showsCard: Bool { offer.isOffered || isAdding }

    func refresh() async {
        let check = await Self.checkClipboard()
        // Checks can overlap (appearing, returning to the app, a copy). A stale answer is dropped; the copy that outdated it triggers its own check.
        #if canImport(UIKit)
        guard UIPasteboard.general.changeCount == check.changeCount else { return }
        #endif
        offer.observe(changeCount: check.changeCount, signals: check.signals)
    }

    /// Reads the change count and asks iOS content-free questions about the clipboard. None reads the copied text.
    private nonisolated static func checkClipboard() async -> (changeCount: Int, signals: ClipboardLinkOffer.Signals) {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let probableLink: PartialKeyPath<UIPasteboard.DetectedValues> = \.probableWebURL
        let found = (try? await pasteboard.detectedPatterns(for: [probableLink])) ?? []
        let signals = ClipboardLinkOffer.Signals(
            probableWebURL: found.contains(probableLink), hasURLs: pasteboard.hasURLs,
            hasStrings: pasteboard.hasStrings, itemCount: pasteboard.numberOfItems,
            types: pasteboard.types)
        return (changeCount, signals)
        #else
        return (0, .init(probableWebURL: false, hasURLs: false, hasStrings: false, itemCount: 0))
        #endif
    }

    func beganAdding() { isAdding = true }

    /// Dismissed, added, or the Add sheet opened: this copy isn't offered again.
    func markHandled() {
        isAdding = false
        offer.markHandled()
        if let handled = offer.handledChangeCount { defaults.set(handled, forKey: Self.handledKey) }
    }
}

/// The Library's offer to add a copied link in one tap: "Add to Library" or "Add and play". The system
/// draws each Paste button's label, so the row names the action beside it, as the Add sheet's bar does.
struct ClipboardLinkOfferCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var clipboard: ClipboardLinkOfferModel
    @State private var message: String?
    @State private var interactions = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        ExperienceSurface(tint: AppColors.evergreen.opacity(0.5)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Label("Link copied", systemImage: "link")
                        .font(.headline)
                        .accessibilityIdentifier("library.clipboardLink.title")
                    Spacer(minLength: 8)
                    Button {
                        clipboard.markHandled()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss copied link")
                    .accessibilityIdentifier("library.clipboardLink.dismiss")
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.clipboardLink.message")
                } else if clipboard.isAdding {
                    SourceLinkImportStatusView()
                }
                if model.isResolvingSourceLink {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    action("Add to Library", play: false)
                    // With something already playing the import adds without interrupting it, so don't promise play.
                    if !model.hasActiveSession { action("Add and play", play: true) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.clipboardLink.card")
        .onCompatibleChange(of: clipboard.offer.changeCount) { _ in message = nil }
        // Any touch on the card restarts the wait (#2696).
        .simultaneousGesture(TapGesture().onEnded { interactions += 1 })
        .task(id: AutoDismissKey(changeCount: clipboard.offer.changeCount, interactions: interactions, busy: isBusy)) {
            guard !isBusy else { return }
            let delay = ClipboardLinkOffer.autoDismissDelay(voiceOverRunning: voiceOverEnabled)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isBusy else { return }
            clipboard.markHandled()
        }
    }

    private struct AutoDismissKey: Equatable {
        let changeCount: Int?
        let interactions: Int
        let busy: Bool
    }

    /// An import is running or an error shows, so the card must stay (#2696).
    private var isBusy: Bool {
        !ClipboardLinkOffer.mayAutoDismiss(
            isAdding: clipboard.isAdding, isResolvingSourceLink: model.isResolvingSourceLink, showsError: message != nil)
    }

    private func action(_ title: String, play: Bool) -> some View {
        // At accessibility sizes the Paste button stacks under its name; beside it the name is crushed (#1934).
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        let identifier = play ? "library.clipboardLink.addAndPlay" : "library.clipboardLink.add"
        return layout {
            Text(title)
                .font(.body)
                .accessibilityHidden(true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            PasteButton(supportedContentTypes: PastedClipboardContent.supportedTypes) { providers in
                Task { @MainActor in paste(await PastedClipboardContent.text(from: providers), play: play) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(AppColors.evergreen)
            .accessibilityLabel(play ? "Paste the link, add it and play" : "Paste the link and add it to the Library")
            .accessibilityIdentifier(identifier)
        }
    }

    /// Only a link is added from this card. If the clipboard changed to text since the check, nothing is created.
    private func paste(_ content: String?, play: Bool) {
        let outcome = ClipboardLinkOffer.pasteOutcome(for: content)
        guard outcome == .addLink else {
            // The text is never shown or added from here. The card stays with this note until the X or a new copy.
            message = outcome.message
            return
        }
        switch model.pasteAndGo(content, startSession: play) {
        case .resolvingLink:
            message = nil
            clipboard.beganAdding()
        case .addedText:
            clipboard.markHandled()
        case .notAdded(let reason):
            message = reason
        }
    }
}
