import SwiftUI
import SessionKit
import SessionKitSharing

// "Share link", the sender screen's main Share button in a build that makes links (#487, #3750). The rules, the
// sealing and the upload live in SessionKit (`ShareLinkClient`, `ShareLinkPreviewBuilder`, `ShareLinkSealing`); this
// file only gathers what they need, asks the share sheet to carry the link, and shows one line when no link could be
// made.
//
// Link creation exists only in a build made to have it (`SM_SHARE_LINK_CREATION`, project.yml): the owner's call is
// that a gated feature is switched on by a new build, never by a server or a device setting (2026-10-17). In every
// other build this file compiles to nothing. The server's `links` switch can only turn creation off.

#if SM_SHARE_LINK_CREATION

@MainActor
final class ShareLinkSender: ObservableObject {
    enum State: Equatable {
        case idle
        case making
        /// The link to share. `companionFile` is the packet to put in the same message when the item has no web
        /// address, so the friend can import the item itself (owner, 2026-10-20).
        case ready(URL, companionFile: URL?)
        /// The listener hasn't agreed to the upload yet (#2842). The screen asks; nothing has been sealed or sent.
        case needsConsent
        /// No link was made; the file share is still there. Holds the one line to show.
        case useFile(String)
    }

    @Published private(set) var state: State = .idle
    /// Shown while the link is made and after, when the share will carry the file too.
    @Published private(set) var companionNote: String?
    private let bridge = BridgeService.makeStore()
    private static let companionLine = "This item has no public web page, so the file goes in the same message as the link."

    /// Whether to show the button at all. The cached config decides; with none, or a stale one, the sender's own
    /// screen asks the server once (our server, no one else's) so a fresh install can offer the button.
    func isOffered() async -> Bool {
        guard let bridge else { return false }
        switch await bridge.state(of: ServerService.links) {
        case .on: return true
        case .off(.noConfig), .off(.staleConfig):
            await bridge.refreshConfigOnly()
            return await bridge.state(of: ServerService.links).isOn
        case .off: return false
        }
    }

    /// Seals and uploads the packet at `packageURL`, the file the sender would otherwise share.
    func makeLink(packageURL: URL) {
        guard state != .making else { return }
        // Before anything is read, sealed or sent, and before any key is made: the first link asks (#2842).
        guard ServerSendConsent.hasConsented(to: .shareLinks) else {
            state = .needsConsent
            return
        }
        state = .making
        let bridge = self.bridge
        Task {
            // The packet is read, sealed and posted off the main thread: it can be 20 MB.
            let prepared = await Task.detached(priority: .userInitiated) { () -> Result<(Data, ShareLinkPreview), ShareLinkFallback> in
                Self.prepare(packageURL: packageURL)
            }.value
            let packet: Data
            let preview: ShareLinkPreview
            switch prepared {
            case .success(let made):
                (packet, preview) = made
                companionNote = preview.needsCompanionFile ? Self.companionLine : nil
            case .failure(let fallback):
                state = .useFile(fallback.message)
                return
            }
            var linksState = ServerFeatureState.off(.noConfig)
            if let bridge {
                // A fresh switch, not a cached one: the sender is waiting and the request is theirs.
                await bridge.refreshConfigOnly()
                linksState = await bridge.state(of: ServerService.links)
            }
            let client = ShareLinkClient(consent: { ServerSendConsent.hasConsented(to: .shareLinks) }, post: ShareLinkTransport.post)
            switch await client.makeLink(packet: packet, preview: preview, linksState: linksState) {
            case .link(let url, _): state = .ready(url, companionFile: preview.needsCompanionFile ? packageURL : nil)
            case .useFile(let fallback):
                // No link, so nothing goes with it: the file share beside the button is the way.
                companionNote = nil
                state = .useFile(fallback.message)
            case .needsConsent:
                companionNote = nil
                state = .needsConsent
            }
        }
    }

    func reset() {
        state = .idle
        companionNote = nil
    }

    /// The listener tapped the agreeing button on the consent alert: remember it, then make the link they asked for.
    func agreeAndMakeLink(packageURL: URL) {
        ServerSendConsent.record(.shareLinks)
        state = .idle
        makeLink(packageURL: packageURL)
    }

    /// The packet's bytes and the preview read from it. The audio the read extracts is only for the read, and goes.
    nonisolated private static func prepare(packageURL: URL) -> Result<(Data, ShareLinkPreview), ShareLinkFallback> {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let packet = try Data(contentsOf: packageURL)
            return .success((packet, try ShareLinkPacketPreview.preview(ofPackageAt: packageURL, scratch: scratch)))
        } catch ShareLinkPreviewBuilder.Failure.nothingToSay {
            return .failure(.nothingToSay)
        } catch {
            return .failure(.failed)
        }
    }
}

/// The consent alert and the link's share sheet, attached to the sender screen whose Share button makes the link
/// (#3750). They stay attached whatever stage the screen is on, so a link finished after the stage changed still opens.
struct ShareLinkPresentation: ViewModifier {
    @ObservedObject var sender: ShareLinkSender
    let packageURL: URL?

    func body(content: Content) -> some View {
        content
            .alert(ShareLinkConsentCopy.title, isPresented: Binding(
                get: { sender.state == .needsConsent },
                set: { if !$0, sender.state == .needsConsent { sender.reset() } }
            )) {
                Button(ShareLinkConsentCopy.accept) {
                    if let packageURL { sender.agreeAndMakeLink(packageURL: packageURL) } else { sender.reset() }
                }
                .accessibilityIdentifier("build23.sender.share.link.consent.agree")
                Button(ShareLinkConsentCopy.decline, role: .cancel) { sender.reset() }
                    .accessibilityIdentifier("build23.sender.share.link.consent.decline")
            } message: {
                Text(ShareLinkConsentCopy.message)
            }
            .sheet(isPresented: Binding(
                get: { if case .ready = sender.state { return true } else { return false } },
                set: { if !$0 { sender.reset() } }
            )) {
                if case .ready(let url, let file) = sender.state {
                    ShareLinkActivityView(link: url, companionFile: file)
                        .presentationDetents([.medium, .large])
                }
            }
    }
}

/// The lines under the Share button while and after a link is made: the companion-file note, or why no link was made
/// and the file is the way. Drawn from the sender's state alone, so a test can render each state (#487, #3750).
struct ShareLinkStatusLines: View {
    let state: ShareLinkSender.State
    let companionNote: String?

    /// Whether there is anything to draw, so the screen leaves no gap above its button when there isn't.
    var hasLines: Bool {
        if companionNote != nil { return true }
        if case .useFile = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let companionNote {
                Text(companionNote)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.share.link.companion")
            }
            if case .useFile(let message) = state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.share.link.fallback")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if canImport(UIKit)
private struct ShareLinkActivityView: UIViewControllerRepresentable {
    let link: URL
    /// The `.spokenmargins` file for an item with no web address: the same share, so one message holds both.
    let companionFile: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [link]
        if let companionFile { items.append(SpokenMarginsPackageActivityItem(packageURL: companionFile)) }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#endif
