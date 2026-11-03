import SwiftUI
import SessionKit
import SessionKitSharing

// "Share as link" on the sender's recipient preview (#487). The rules, the sealing and the upload live in SessionKit
// (`ShareLinkClient`, `ShareLinkPreviewBuilder`, `ShareLinkSealing`); this file only gathers what they need, asks
// the share sheet to carry the link, and shows one line when no link could be made.
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
        case ready(URL)
        /// The listener hasn't agreed to the upload yet (#2842). The screen asks; nothing has been sealed or sent.
        case needsConsent
        /// No link was made; the file share is still there. Holds the one line to show.
        case useFile(String)
    }

    @Published private(set) var state: State = .idle
    private let bridge = BridgeService.makeStore()

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
            case .success(let made): (packet, preview) = made
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
            case .link(let url, _): state = .ready(url)
            case .useFile(let fallback): state = .useFile(fallback.message)
            case .needsConsent: state = .needsConsent
            }
        }
    }

    func reset() { state = .idle }

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

/// The "Share as link" button beside "Share verified package", with its one-line fallback. Hidden while the cached
/// server config says links are off.
struct ShareLinkSendControl: View {
    let packageURL: URL?
    @StateObject private var sender = ShareLinkSender()
    @State private var isOffered = false

    var body: some View {
        // A real container, not a Group: `.task` and `.sheet` must stay attached while the button is hidden, or the
        // config is never asked for and the button never appears.
        VStack(alignment: .leading, spacing: 0) {
            if isOffered, let packageURL {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        sender.makeLink(packageURL: packageURL)
                    } label: {
                        if sender.state == .making {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Making link…")
                            }
                        } else {
                            Label("Share as link", systemImage: "link")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sender.state == .making)
                    .accessibilityHint("Uploads the verified package, sealed so only the link can open it, and opens the share sheet with the link")
                    .accessibilityIdentifier("build23.sender.share.link")

                    if case .useFile(let message) = sender.state {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("build23.sender.share.link.fallback")
                    }
                }
            }
        }
        .task { isOffered = await sender.isOffered() }
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
            if case .ready(let url) = sender.state {
                ShareLinkActivityView(link: url)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

#if canImport(UIKit)
private struct ShareLinkActivityView: UIViewControllerRepresentable {
    let link: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [link], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#endif
