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

/// The Library's offer to add a copied link, on one compact line (#2835). iOS reads the clipboard without
/// the "Allow Paste" alert only for the system Paste button, so there is one of them: "Link detected" with
/// Paste. That tap is the permission to read the clipboard, so a link is added to the Library at once, with no
/// second step (owner, 2026-10-29, #2944); the listener deletes the item if they didn't want it. Every tap shows
/// something: a reading spinner, the import's progress, the new item in the Library or a message. Text that is
/// not a link is never added from here.
struct ClipboardLinkOfferCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var clipboard: ClipboardLinkOfferModel
    @State private var stage = Stage.offered
    @State private var message: String?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private enum Stage: Equatable {
        case offered
        /// The Paste tap landed and the clipboard is being read.
        case reading
    }

    var body: some View {
        ExperienceSurface(tint: AppColors.evergreen.opacity(0.5), padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                line
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.clipboardLink.message")
                } else if clipboard.isAdding {
                    SourceLinkImportStatusView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.clipboardLink.card")
        .onCompatibleChange(of: clipboard.offer.changeCount) { _ in
            message = nil
            stage = .offered
        }
        .task(id: AutoDismissKey(changeCount: clipboard.offer.changeCount, stage: stage, busy: isBusy)) {
            guard !isBusy else { return }
            let delay = ClipboardLinkOffer.autoDismissDelay(voiceOverRunning: voiceOverEnabled)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isBusy else { return }
            clipboard.markHandled()
        }
    }

    private struct AutoDismissKey: Equatable {
        let changeCount: Int?
        let stage: Stage
        let busy: Bool
    }

    /// The listener has started something (a paste is being read or was read, an import runs) or an error shows,
    /// so the card must stay until they finish or tap the X (#2696).
    private var isBusy: Bool {
        !ClipboardLinkOffer.mayAutoDismiss(
            isAdding: clipboard.isAdding || stage != .offered,
            isResolvingSourceLink: model.isResolvingSourceLink, showsError: message != nil)
    }

    @ViewBuilder
    private var line: some View {
        if model.isResolvingSourceLink {
            HStack(spacing: 10) {
                ProgressView()
                Text("Adding the link…")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer(minLength: 8)
                dismissButton
            }
            .frame(minHeight: TapTarget.minimum)
        } else {
            switch stage {
            case .offered:
                // At accessibility sizes the Paste button drops under its name; beside it the name is crushed (#1934).
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 10))
                HStack(alignment: .center, spacing: 4) {
                    layout {
                        Label("Link detected", systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("library.clipboardLink.title")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        pasteButton
                    }
                    dismissButton
                }
            case .reading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the copied link…")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Spacer(minLength: 8)
                    dismissButton
                }
                .frame(minHeight: TapTarget.minimum)
            }
        }
    }

    /// The only system Paste button on the card: its tap is the permission to read the clipboard.
    private var pasteButton: some View {
        PasteButton(supportedContentTypes: PastedClipboardContent.supportedTypes) { providers in
            // The closure runs on the tap, on the main thread: show something at once, before the clipboard
            // has been read, so the auto-dismiss wait can't end while the paste is in flight.
            let changeCount = clipboard.offer.changeCount
            stage = .reading
            message = nil
            announce("Reading the copied link")
            Task { @MainActor in
                let content = await PastedClipboardContent.text(from: providers)
                // A newer copy replaced the offer while this was read: its result is stale.
                guard clipboard.offer.changeCount == changeCount else { return }
                // The add runs on the main actor; the label lets the hang probe name it, as for Paste & go.
                model.hangTelemetry.labels.scoped("clipboardLinkPaste") { pasted(content) }
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(AppColors.evergreen)
        .accessibilityLabel("Paste the copied link")
        .accessibilityIdentifier("library.clipboardLink.paste")
    }

    private var dismissButton: some View {
        Button {
            clipboard.markHandled()
        } label: {
            Image(systemName: "xmark")
                .frame(width: TapTarget.minimum, height: TapTarget.minimum)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss copied link")
        .accessibilityIdentifier("library.clipboardLink.dismiss")
    }

    /// Only a link is added from this card, at once and without starting playback. If the clipboard changed to text
    /// since the check, nothing is created and the card says so; the text is never shown or added from here.
    private func pasted(_ content: String?) {
        switch ClipboardLinkOffer.pasteResult(for: content) {
        case .link(let url):
            add(url)
        case let result:
            // The card stays with this note until the X or a new copy.
            stage = .offered
            message = result.message
            if let note = result.message { announce(note) }
        }
    }

    private func add(_ url: URL) {
        // Back to the Paste line: the import's progress or error shows above it, and a failed add is retried with another Paste.
        stage = .offered
        switch model.pasteAndGo(url.absoluteString) {
        case .resolvingLink:
            message = nil
            clipboard.beganAdding()
            announce("Adding \(ClipboardLinkOffer.displayHost(of: url)) to the Library")
        case .addedText:
            clipboard.markHandled()
        case .notAdded(let reason):
            message = reason
            announce(reason)
        }
    }

    /// Moves between the card's stages replace the focused control, so VoiceOver is told what happened.
    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
