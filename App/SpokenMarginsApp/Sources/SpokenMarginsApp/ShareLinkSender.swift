import Combine
import os
import SwiftUI
import SessionKit
import SessionKitSharing
import WebKit

// "Share link", the sender screen's main Share button in a build that makes links (#487, #3750). The rules, the
// sealing and the upload live in SessionKit (`ShareLinkClient`, `ShareLinkPreviewBuilder`, `ShareLinkSealing`); this
// file only gathers what they need, asks the share sheet to carry the link, and shows one line when no link could be
// made.
//
// Link creation exists only in a build made to have it (`SM_SHARE_LINK_CREATION`, project.yml): the owner's call is
// that a gated feature is switched on by a new build, never by a server or a device setting (2026-10-17). In every
// other build this file compiles to nothing. The server's `links` switch can only turn creation off.

#if SM_SHARE_LINK_CREATION

/// The one attested client of the app (#4137). A static, so every sender screen asks the same one; it holds no key until
/// the first attested request after the listener agreed, so creating it at first use makes nothing.
enum ShareLinkAttestation {
    static let client = AttestedServerClient(
        provider: AppAttestDeviceProvider(),
        consent: { ServerSendConsent.hasConsented(to: .shareLinks) },
        post: AttestedTransport.post
    )
}

@MainActor
final class ShareLinkSender: ObservableObject {
    enum State: Equatable {
        case idle
        case making
        /// The link to share. `companionFile` is the packet to put in the same message when the item has no web
        /// address, so the friend can import the item itself (owner, 2026-10-20). `packet` is the file the link was
        /// made from, for the share signal.
        case ready(URL, companionFile: URL?, packet: URL)
        /// The listener hasn't agreed to the upload yet (#2842). The screen asks; nothing has been sealed or sent.
        case needsConsent
        /// No link was made; the file share is still there. Holds why, which gives the one line to show and what "Share
        /// link" does afterwards (#4134).
        case useFile(ShareLinkFallback)
    }

    /// What "Share link" does while this screen shows its state (#4134): a refusal a retry won't pass disables it, and a
    /// build below the server's minimum hides it.
    var shareLinkAfterwards: ShareLinkButtonAfterFallback {
        if case .useFile(let fallback) = state { return fallback.shareLinkAfterwards }
        return .enabled
    }

    /// Refuse mode, from this build's Info.plist (#4134). The key is absent today, which is off; it is set in Release only,
    /// with the App Attest entitlement, so Debug and Simulator builds keep making links.
    private static let faultPolicy = ShareLinkFaultPolicy.fromInfoPlist(Bundle.main.infoDictionary)

    @Published private(set) var state: State = .idle
    /// Shown while the link is made and after, when the share will carry the file too.
    @Published private(set) var companionNote: String?
    /// What the background play check says about the link the screen shows (#4454), or nil when there is nothing to say.
    @Published private(set) var playCheckLine: ShareLinkPlayCheck.Line?
    /// A link this install made was taken down after a report (#2239). One line, no button, kept until a screen has
    /// shown it: the server marks it shown the moment it sends it.
    @Published private(set) var showsTakedownNotice: Bool
    private let bridge = BridgeService.makeStore()
    private let noticeStore = ShareLinkTakedownNoticeStore()
    private var noticeDrawn = false
    /// One App Attest identity per install, made only after the listener agreed (`AttestedServerClient`). The client is
    /// the app's, not this screen's: a second sender screen (iPad windows) or a tap right after `reset` shares its key
    /// and its send order (#4137).
    private let attested = ShareLinkAttestation.client
    /// Only the newest request's answer reaches the screen; `reset` voids the one in flight (#3751 audit).
    private var requests = ShareLinkRequests()
    private let playChecker = ShareLinkPlayChecker.shared
    private(set) var playCheckLinkID: String?
    private var playCheckObservation: AnyCancellable?
    /// A problem found while the share sheet was open is announced when the sheet closes, once.
    private var announcementWaitsForSheet = false
    private var announcedLinkID: String?
    /// The text the share sheet hands over (#5264): the sentence for this share, then the link. Kept current here, on
    /// the main actor, whenever it could change; the sheet's item source reads it at the moment a destination is
    /// picked, so a finished check reaches the send and nothing ever waits on the check.
    let messageBox = ShareLinkMessageBox()
    /// What the packet of the link being made says (kind, the Margins going, audio or page), and whether it is a Spoken Note.
    private var messageFacts: ShareLinkMessage.Facts?
    private var messageItem: ShareLinkMessage.SharedKind?
    /// The verdict of the screen's previous link, used while the newest link's own check reads as unknown. Only plays
    /// or cannot is carried; `reset()` clears it because the selection changed.
    private var carriedPlayability: ShareLinkMessage.Playability?
    private static let companionLine = "This has no public web page, so the file goes in the same message as the link."

    init() {
        showsTakedownNotice = noticeStore.isPending
        playCheckObservation = playChecker.$outcomes.sink { [weak self] outcomes in
            self?.playOutcomesChanged(outcomes)
        }
    }

    /// Whether to show the button at all. The cached config decides; with none, or a stale one, the sender's own
    /// screen asks the server once (our server, no one else's) so a fresh install can offer the button.
    func isOffered() async -> Bool {
        guard let bridge else { return false }
        var links = await bridge.state(of: ServerService.links)
        if links == .off(.noConfig) || links == .off(.staleConfig) {
            await bridge.refreshConfigOnly()
            links = await bridge.state(of: ServerService.links)
        }
        // Below the server's minimum build the button stays hidden, but the screen says to update instead of nothing
        // (#4134). Only an idle screen takes the line, so it never replaces a link or a line already on show.
        if case .off(.buildTooOld) = links, state == .idle { state = .useFile(.updateNeeded) }
        return links.isOn
    }

    /// Seals and uploads the packet at `packageURL`, the file the sender would otherwise share. `isSpokenNote` says
    /// whether the shared item is a Spoken Note, which the packet's item type alone can't tell (#5264).
    func makeLink(packageURL: URL, isSpokenNote: Bool) {
        guard state != .making, shareLinkAfterwards.allowsShareLink else { return }
        // Before anything is read, sealed or sent, and before any key is made: the first link asks (#2842).
        guard ServerSendConsent.hasConsented(to: .shareLinks) else {
            state = .needsConsent
            return
        }
        // Before the new link replaces it: the screen's current link's verdict carries over until the new one's own
        // check says plays or cannot (#5264).
        if let id = playCheckLinkID {
            let previous = ShareLinkMessage.Playability(playChecker.outcomes[id])
            if previous != .unknown { carriedPlayability = previous }
        }
        // The box keeps the previous link's text until the new link exists; nothing reads it while no sheet is open.
        messageLink = nil
        state = .making
        let ticket = requests.begin()
        let bridge = self.bridge
        Task {
            // The packet is read, sealed and posted off the main thread: it can be 20 MB.
            let prepared = await Task.detached(priority: .userInitiated) { () -> Result<(Data, ShareLinkPreview, ShareLinkMessage.Facts), ShareLinkFallback> in
                Self.prepare(packageURL: packageURL)
            }.value
            guard requests.accepts(ticket) else { return }
            let packet: Data
            let preview: ShareLinkPreview
            switch prepared {
            case .success(let made):
                let facts: ShareLinkMessage.Facts
                (packet, preview, facts) = made
                messageFacts = facts
                messageItem = ShareLinkMessage.SharedKind(itemType: facts.itemType, isSpokenNote: isSpokenNote)
                companionNote = preview.needsCompanionFile ? Self.companionLine : nil
            case .failure(let fallback):
                state = .useFile(fallback)
                return
            }
            var linksState = ServerFeatureState.off(.noConfig)
            if let bridge {
                // A fresh switch, not a cached one: the sender is waiting and the request is theirs.
                await bridge.refreshConfigOnly()
                linksState = await bridge.state(of: ServerService.links)
            }
            guard requests.accepts(ticket) else { return }
            let attested = self.attested
            let noticeStore = self.noticeStore
            let client = ShareLinkClient(
                consent: { ServerSendConsent.hasConsented(to: .shareLinks) },
                senderCheck: { await ShareLinkSenderCheck.check(using: attested) },
                takedownNotice: { [weak self] in
                    // Kept first, so a notice the screen never gets to show is not lost.
                    noticeStore.setPending()
                    guard let sender = self else { return }
                    Task { @MainActor in sender.showsTakedownNotice = true }
                },
                post: ShareLinkTransport.postWithHeaders
            )
            let result = await client.makeLink(packet: packet, preview: preview, linksState: linksState, faultPolicy: Self.faultPolicy)
            // The listener went back or changed the selection meanwhile: this link is for a packet the screen no
            // longer shows, so no sheet opens for it.
            guard requests.accepts(ticket) else { return }
            switch result {
            case .link(let url, _):
                // The check starts first so its id is known, then the text is written, all before the sheet opens:
                // the sheet never sees an empty or stale text. The check runs beside the sheet and never delays it (#4454).
                playCheckLinkID = playChecker.check(link: url, title: preview.source.title, packetBytes: packet.count)
                announcedLinkID = nil
                messageLink = url
                updateMessage()
                state = .ready(url, companionFile: preview.needsCompanionFile ? packageURL : nil, packet: packageURL)
                playOutcomesChanged(playChecker.outcomes)
            case .useFile(let fallback):
                // No link, so nothing goes with it: the file share beside the button is the way.
                companionNote = nil
                state = .useFile(fallback)
            case .needsConsent:
                companionNote = nil
                state = .needsConsent
            }
        }
    }

    /// The takedown line was drawn on the sender screen. Only then may it be cleared: a screen that never drew it
    /// (links not offered, or left before the switch was read) leaves it for the next one.
    func takedownNoticeWasDrawn() {
        noticeDrawn = true
    }

    /// The sender screen has gone. If it had the takedown line on show, the server won't say it again, so neither will we.
    func takedownNoticeWasShown() {
        guard showsTakedownNotice, noticeDrawn else { return }
        noticeDrawn = false
        noticeStore.clear()
        showsTakedownNotice = false
    }

    /// Back to idle, and a link still being made is dropped when it arrives. The screen's selection changed, so the
    /// check's line, which is about the link that was made, goes too.
    func reset() {
        requests.cancel()
        // The selection changed, so the previous link's verdict is about something else (#5264).
        carriedPlayability = nil
        // A line that took "Share link" away stays for as long as this sheet is open: going back to the selection
        // doesn't make a refusal pass (#4134). A new sheet is a new sender and tries once more.
        if !shareLinkAfterwards.allowsShareLink {
            companionNote = nil
            playCheckLinkID = nil
            playCheckLine = nil
            announcementWaitsForSheet = false
            return
        }
        state = .idle
        companionNote = nil
        playCheckLinkID = nil
        playCheckLine = nil
        announcementWaitsForSheet = false
    }

    /// The share sheet closed. The link stays the one the screen shows, so its check's line stays; only the sheet's own
    /// state goes, and a problem the check found meanwhile is announced now.
    func closeSheet() {
        requests.cancel()
        state = .idle
        companionNote = nil
        if announcementWaitsForSheet {
            announcementWaitsForSheet = false
            announceProblemIfNeeded()
        }
    }

    /// The link the box's text is for.
    private var messageLink: URL?

    /// Writes the box from what is known now. Called whenever the link or its check's outcome changes.
    private func updateMessage() {
        guard let link = messageLink, let facts = messageFacts, let item = messageItem else { return }
        let outcome = playCheckLinkID.flatMap { playChecker.outcomes[$0] }
        let playability = ShareLinkMessage.Playability.current(newest: outcome, carried: carriedPlayability)
        messageBox.text = ShareLinkMessage.text(
            for: link, item: item, notes: facts.notes, hasAudioOrPage: facts.hasAudioOrPage, playability: playability
        )
    }

    private func playOutcomesChanged(_ outcomes: [String: ShareLinkPlayCheck.Outcome]) {
        updateMessage()
        guard let id = playCheckLinkID, let outcome = outcomes[id] else {
            playCheckLine = nil
            return
        }
        playCheckLine = ShareLinkPlayCheck.line(for: outcome)
        guard playCheckLine?.isAnnounced == true, announcedLinkID != id else { return }
        if case .ready = state {
            announcementWaitsForSheet = true
        } else {
            announceProblemIfNeeded()
        }
    }

    /// Only a problem is announced, once, and only while the line is drawn: with none drawn, the banner says it.
    private func announceProblemIfNeeded() {
        guard let id = playCheckLinkID, announcedLinkID != id, let line = playCheckLine, line.isAnnounced,
              playChecker.isLineDrawn(for: id), !playChecker.bannerWasShown(for: id) else { return }
        announcedLinkID = id
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: line.accessibilityLabel)
        #endif
    }

    /// The listener tapped the agreeing button on the consent alert: remember it, then make the link they asked for.
    func agreeAndMakeLink(packageURL: URL, isSpokenNote: Bool) {
        ServerSendConsent.record(.shareLinks)
        state = .idle
        makeLink(packageURL: packageURL, isSpokenNote: isSpokenNote)
    }

    /// The packet's bytes, the preview read from it and the facts the sentence needs, from one read of the archive.
    /// The audio the read extracts is only for the read, and goes.
    nonisolated private static func prepare(packageURL: URL) -> Result<(Data, ShareLinkPreview, ShareLinkMessage.Facts), ShareLinkFallback> {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let packet = try Data(contentsOf: packageURL)
            let read = try ShareLinkPacketPreview.read(ofPackageAt: packageURL, scratch: scratch)
            return .success((packet, read.preview, read.facts))
        } catch ShareLinkPreviewBuilder.Failure.nothingToSay {
            return .failure(.nothingToSay)
        } catch {
            return .failure(.failed)
        }
    }
}

/// The consent alert and the link's share sheet, attached to the sender screen whose Share button makes the link
/// (#3750). The screen resets the sender when the listener goes back to the selection or the packet changes, so a
/// link opens only for the packet on screen (#3751 audit).
struct ShareLinkPresentation: ViewModifier {
    @ObservedObject var sender: ShareLinkSender
    let packageURL: URL?
    /// Whether the shared item is a Spoken Note, for the sentence beside the link (#5264).
    let isSpokenNote: Bool
    /// The link's share sheet sent it: the same share signal the file sheet records (#483).
    let onShared: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .alert(ShareLinkConsentCopy.title, isPresented: Binding(
                get: { sender.state == .needsConsent },
                set: { if !$0, sender.state == .needsConsent { sender.reset() } }
            )) {
                Button(ShareLinkConsentCopy.accept) {
                    if let packageURL { sender.agreeAndMakeLink(packageURL: packageURL, isSpokenNote: isSpokenNote) } else { sender.reset() }
                }
                .accessibilityIdentifier("build23.sender.share.link.consent.agree")
                Button(ShareLinkConsentCopy.decline, role: .cancel) { sender.reset() }
                    .accessibilityIdentifier("build23.sender.share.link.consent.decline")
            } message: {
                Text(ShareLinkConsentCopy.message)
            }
            .trackedSheet(isPresented: Binding(
                get: { if case .ready = sender.state { return true } else { return false } },
                set: { if !$0 { sender.closeSheet() } }
            )) {
                if case .ready(_, let file, let packet) = sender.state {
                    ShareLinkActivityView(message: sender.messageBox, companionFile: file) { onShared(packet) }
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
    /// A link this install made was taken down after a report (#2239): one line, never a button.
    var showsTakedownNotice = false
    /// Called when the takedown line appears on screen.
    var onTakedownNoticeDrawn: () -> Void = {}
    /// What the background play check says about the link (#4454). It goes last, below the lines about the link itself.
    var playCheckLine: ShareLinkPlayCheck.Line?
    /// The link that line is about, so the checker knows which link's line is on screen.
    var playCheckLinkID: String?

    /// Whether there is anything to draw, so the screen leaves no gap above its button when there isn't.
    var hasLines: Bool {
        if showsTakedownNotice { return true }
        if companionNote != nil { return true }
        if case .useFile = state { return true }
        return playCheckLine != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTakedownNotice {
                Text(ShareLinkTakedownNotice.text)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.share.link.takedown")
                    .onAppear(perform: onTakedownNoticeDrawn)
            }
            if let companionNote {
                Text(companionNote)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.share.link.companion")
            }
            if case .useFile(let fallback) = state {
                ShareLinkFallbackLine(message: fallback.message)
            }
            if let playCheckLine {
                ShareLinkPlayCheckLineView(line: playCheckLine, linkID: playCheckLinkID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Why no link was made, in the pinned bar above "Share link". From AX1 it keeps to two lines with "More", which opens
/// the whole message (#3839's rule for the pinned bar; #4134 adds lines long enough to need it).
struct ShareLinkFallbackLine: View {
    let message: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsFullText = false

    private var isLimited: Bool { typeSize >= .accessibility1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(isLimited ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("build23.sender.share.link.fallback")
            if isLimited {
                Button(ShareReviewCardWords.more) { showsFullText = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Shows the whole message")
                    .accessibilityIdentifier("build23.sender.share.link.fallback.more")
            }
        }
        .trackedSheet(isPresented: $showsFullText) {
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { showsFullText = false }
                    .filledActionButton()
                Spacer(minLength: 0)
            }
            .padding(24)
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - The background play check (#4454)
//
// After a link is made, the sender's phone loads that link in a hidden web view, with throwaway storage, and the web
// app answers "would this play in a browser?" with one message (`ShareLinkPlayCheck`). Nothing plays: the view never
// makes a media element, and the audio check is a 1 KB range read the app makes itself. The page cannot read a
// publisher (CORS) and our relay must never see the item's address, so the web app asks this view for the reads the
// owner agreed to, through `smPlayCheckRead`: one Substack post page and the first 1 KB of the audio (2026-11-17), and for
// an Apple Podcasts episode Apple's lookup and the one feed it names (2026-11-23, #4783). Once per link, with no cookies,
// never through our server.

/// The one check's hidden web view. It loads the link once, lets nothing else load, answers the page's reads, and
/// reports what happens as `ShareLinkPlayCheck.Event`s. `stop()` ends it for good.
@MainActor
final class ShareLinkPlayCheckRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static let probeHandlerName = "smPlayCheck"
    private static let readHandlerName = "smPlayCheckRead"

    private let link: URL
    private let onEvent: (ShareLinkPlayCheck.Event) -> Void
    private var webView: WKWebView?
    /// Asks the checker's per-link budget, so a check run again for the same link has no second page or audio read.
    private let allowRead: @MainActor (ShareLinkPlayCheck.ReadRequest) -> Bool
    /// Hands Apple's lookup answer to the same budget: the only feeds this link's check may then read are the ones it names.
    private let noteLookupAnswer: @MainActor (Data) -> Void
    private var isStopped = false
    private let probe = ShareLinkPlayCheckProbeHandler()

    init(
        link: URL,
        allowRead: @escaping @MainActor (ShareLinkPlayCheck.ReadRequest) -> Bool,
        noteLookupAnswer: @escaping @MainActor (Data) -> Void,
        onEvent: @escaping (ShareLinkPlayCheck.Event) -> Void
    ) {
        self.link = link
        self.allowRead = allowRead
        self.noteLookupAnswer = noteLookupAnswer
        self.onEvent = onEvent
        super.init()
        probe.onMessage = { [weak self] message in self?.probeMessage(message) }
    }

    func start() async {
        guard let host = link.host, ShareLinkURL.isOnShareHost(link) else {
            send(.message(.couldNotReach(offline: false)))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(probe, name: Self.probeHandlerName)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.readHandlerName)
        do {
            // Everything is blocked but the link's host, the web listener's (the page the link's page sends a browser to,
            // and its files) and the link servers' (the packet): `ShareLinkPlayCheck.pageHosts`.
            let hosts = ShareLinkPlayCheck.pageHosts(for: link)
            guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "spoken-margins-play-check.v2.\(host.lowercased())",
                encodedContentRuleList: Self.contentRules(hosts: hosts)
            ) else {
                send(.message(.couldNotReach(offline: false)))
                return
            }
            configuration.userContentController.add(rules)
        } catch {
            send(.message(.couldNotReach(offline: false)))
            return
        }
        // The check may have ended (a time limit, the background) while the rules compiled.
        guard !isStopped else {
            configuration.userContentController.removeAllScriptMessageHandlers()
            return
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    /// Ends the check: the page stops, and the handlers that hold this object go.
    func stop() {
        isStopped = true
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.probeHandlerName)
        controller.removeScriptMessageHandler(forName: Self.readHandlerName, contentWorld: .page)
        controller.removeAllContentRuleLists()
        self.webView = nil
    }

    private func send(_ event: ShareLinkPlayCheck.Event) {
        guard !isStopped else { return }
        onEvent(event)
    }

    /// Block everything, then allow each of `hosts`. A host is escaped as a regular expression.
    nonisolated static func contentRules(hosts: [String]) -> String {
        let allowed = hosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^https://\#(escaped)/"},"action":{"type":"ignore-previous-rules"}}"#
        }
        return "[" + ([#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#] + allowed).joined(separator: ",") + "]"
    }

    // MARK: Messages from the page

    private func probeMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isFromLink(message.frameInfo),
              let parsed = ShareLinkPlayCheck.Message(body: message.body) else { return }
        send(.message(parsed))
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard !isStopped, message.frameInfo.isMainFrame, isFromLink(message.frameInfo),
              let request = ShareLinkPlayCheck.ReadRequest(body: message.body),
              allowRead(request) else { return (nil, ShareLinkPlayCheck.readRefusedMessage) }
        do {
            switch request {
            case .page(let url):
                return (try await Self.readText(url, accept: "text/html, application/xhtml+xml").reply, nil)
            case .appleLookup(let url):
                let read = try await Self.readText(url, accept: "application/json, text/javascript;q=0.9")
                if let body = read.body { noteLookupAnswer(body) }
                return (read.reply, nil)
            case .feed(let url):
                return (try await Self.readText(url, accept: "application/rss+xml, application/xml;q=0.9, text/xml;q=0.8").reply, nil)
            case .audioStart(let url):
                return (try await Self.readAudioStart(url), nil)
            }
        } catch {
            // Any failure rejects the page's call: the web app says "couldn't check", never a warning about the link.
            return (nil, "The read failed.")
        }
    }

    /// A message from the link's page or from the web listener's page it sends the view on to.
    private func isFromLink(_ frame: WKFrameInfo) -> Bool {
        ShareLinkPlayCheck.isCheckPageHost(frame.securityOrigin.host, link: link)
    }

    // MARK: The reads: the app's own network stack, no cookies, no cache, a byte cap, https only

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    nonisolated private static func makeRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    /// A post's page, Apple's lookup answer or a show's feed, as `{ status, url, body }`, and the body's bytes. The body is
    /// for a 2xx only, and never over `maximumPageBytes`: a larger one answers `{ status, url, tooLarge: true }` with no body,
    /// which the page reads as its own size cap (`ReadTooLarge` in `Web/src/sources/read.ts`), so the sender's line says what
    /// a friend's browser, which stops at the same size, would say.
    nonisolated static func readText(_ url: URL, accept: String) async throws -> (reply: [String: Any], body: Data?) {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(
            for: makeRequest(url, accept: accept), delegate: HTTPSOnlyRedirects()
        )
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, finalURL.scheme?.lowercased() == "https" else {
            throw URLError(.badServerResponse)
        }
        var reply: [String: Any] = ["status": http.statusCode, "url": finalURL.absoluteString]
        guard (200..<300).contains(http.statusCode) else { return (reply, nil) }
        let tooLarge: (reply: [String: Any], body: Data?) = (reply.merging(["tooLarge": true]) { $1 }, nil)
        if http.expectedContentLength > Int64(ShareLinkPlayCheck.maximumPageBytes) { return tooLarge }
        var data = Data()
        var chunk = [UInt8]()
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16_384 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > ShareLinkPlayCheck.maximumPageBytes { return tooLarge }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= ShareLinkPlayCheck.maximumPageBytes else { return tooLarge }
        reply["body"] = String(decoding: data, as: UTF8.self)
        return (reply, data)
    }

    /// The start of an episode's audio, as `{ status, contentType }`: a range read of the first bytes, which are read and
    /// dropped. No audio ever reaches the page.
    nonisolated static func readAudioStart(_ url: URL) async throws -> [String: Any] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var request = makeRequest(url, accept: "audio/*, video/*;q=0.9, */*;q=0.5")
        request.setValue("bytes=0-\(ShareLinkPlayCheck.audioStartBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request, delegate: HTTPSOnlyRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var read = 0
        for try await _ in bytes {
            read += 1
            if read >= ShareLinkPlayCheck.audioStartBytes { break }
        }
        var reply: [String: Any] = ["status": http.statusCode]
        if let type = http.value(forHTTPHeaderField: "Content-Type") { reply["contentType"] = type }
        return reply
    }

    // MARK: Navigation: the link, once, and nothing else

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The link, and the one hop its page makes to the same link on the web listener's host (#4783: without the hop the
        // check never ran on a real link). A later address (a Report link, an outside link, a pop-up) is never followed.
        guard let url = navigationAction.request.url else { return .cancel }
        return ShareLinkPlayCheck.mayNavigate(to: url, from: link) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            switch http.statusCode {
            case 404, 410:
                send(.message(.linkDidNotOpen(.linkBroken)))
                return .cancel
            case 500...599:
                send(.message(.couldNotReach(offline: false)))
                return .cancel
            default:
                break
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// A load that failed for the network's reasons. One we cancelled ourselves (a policy decision) is not a failure.
    private func loadFailed(_ error: Error) {
        guard let urlError = error as? URLError, urlError.code != .cancelled else { return }
        send(.message(.couldNotReach(offline: urlError.code == .notConnectedToInternet)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        send(.processEnded)
    }
}

/// The probe's messages, kept apart from the runner so the web view's strong hold on its handler is not a hold on the check.
@MainActor
fileprivate final class ShareLinkPlayCheckProbeHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message)
    }
}

/// A read stays on https: a redirect to anything else is refused, so the read ends where the publisher's own answer does.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(ShareLinkPlayCheck.ReadRequest.isReadableAddress) == true ? request : nil)
    }
}

/// Runs the checks one at a time, in the order `ShareLinkPlayCheck.Queue` says, and keeps the results in memory for the
/// session. The app's own, so a check goes on after the sender screen has closed and a problem found then reaches the
/// banner. Nothing is stored: a restart forgets every result.
@MainActor
final class ShareLinkPlayChecker: ObservableObject {
    static let shared = ShareLinkPlayChecker()

    private struct Job {
        let link: URL
        let title: String
        let packetBytes: Int
    }

    /// The outcome for each link made this session, by `ShareLinkPlayCheck.linkID(for:)`.
    @Published private(set) var outcomes: [String: ShareLinkPlayCheck.Outcome] = [:]
    /// Where a problem found with no sender screen showing goes: the app's warning banner. The sharing coordinator sets it.
    var showWarning: @MainActor (String) -> Void = { _ in }
    /// Where the Diagnostics line goes. Codes and counts only, never a URL, id or title.
    var recordDiagnostic: @MainActor (String, [String: String]) -> Void = { _, _ in }

    /// The app's own network view once `connect(to:)` has joined it; until then, one of its own.
    fileprivate(set) var connectivity = ConnectivityMonitor()
    private var readBudgets: [String: ShareLinkPlayCheck.ReadBudget] = [:]
    private var drawnLines: [String: Int] = [:]
    private var bannered: Set<String> = []
    private var queue = ShareLinkPlayCheck.Queue()
    private var jobs: [String: Job] = [:]
    private var runner: ShareLinkPlayCheckRunner?
    private var startedAt: ContinuousClock.Instant?
    private var timeLimit: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    /// A sender screen drew the line for this link, or took it away. A problem found while no screen draws its line goes
    /// to the banner, so it is never lost; one found while the line is drawn is read there and announced.
    func lineDrawn(_ id: String?) {
        guard let id else { return }
        drawnLines[id, default: 0] += 1
    }

    func lineHidden(_ id: String?) {
        guard let id, let count = drawnLines[id] else { return }
        drawnLines[id] = count > 1 ? count - 1 : nil
    }

    func isLineDrawn(for id: String) -> Bool { drawnLines[id] != nil }

    /// Whether the banner already said this link's problem, so the line is not announced as well.
    func bannerWasShown(for id: String) -> Bool { bannered.contains(id) }

    /// Starts the check for a link just made, or asks for it to wait. Returns the link's key for its line. The phone's
    /// network state is read first: the monitor's first report can lag the first link by a moment, and a check must not
    /// start on a guess that the phone is online.
    @discardableResult
    func check(link: URL, title: String, packetBytes: Int) -> String? {
        guard let id = ShareLinkPlayCheck.linkID(for: link) else { return nil }
        startWatchingTheNetworkAndTheBackground()
        jobs[id] = Job(link: link, title: title, packetBytes: packetBytes)
        Task { [weak self] in
            await self?.waitForFirstNetworkReport()
            self?.admit(id)
        }
        return id
    }

    private func waitForFirstNetworkReport() async {
        var waited = 0
        while !connectivity.hasReported, waited < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    private func admit(_ id: String) {
        guard jobs[id] != nil else { return }
        let network = ShareLinkPlayCheck.Network(isOnline: !connectivity.isOffline, isLowDataMode: connectivity.isConstrained)
        switch queue.request(linkID: id, network: network) {
        case .start:
            begin(id)
        case .wait(let replaced):
            if let replaced { jobs[replaced] = nil }
        case .alreadyKnown:
            break
        }
        publish()
    }

    private func startWatchingTheNetworkAndTheBackground() {
        connectivity.start()
        guard backgroundObserver == nil else { return }
        #if canImport(UIKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        }
        #endif
    }

    private func publish() {
        outcomes = queue.sessions.mapValues(\.outcome)
    }

    private func begin(_ id: String) {
        guard let job = jobs[id] else { return }
        startedAt = .now
        // One of each read for each link, however many times its check runs.
        let runner = ShareLinkPlayCheckRunner(
            link: job.link,
            allowRead: { [weak self] request in self?.allowRead(request, for: id) ?? false },
            noteLookupAnswer: { [weak self] body in self?.readBudgets[id, default: ShareLinkPlayCheck.ReadBudget()].noteLookupAnswer(body) },
            onEvent: { [weak self] event in self?.handle(event, for: id) }
        )
        self.runner = runner
        timeLimit?.cancel()
        timeLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShareLinkPlayCheck.timeLimit))
            guard !Task.isCancelled else { return }
            self?.handle(.timedOut, for: id)
        }
        Task { await runner.start() }
    }

    private func allowRead(_ request: ShareLinkPlayCheck.ReadRequest, for id: String) -> Bool {
        readBudgets[id, default: ShareLinkPlayCheck.ReadBudget()].allow(request)
    }

    private func handle(_ event: ShareLinkPlayCheck.Event, for id: String) {
        guard queue.running == id else { return }
        let next = queue.apply(event, to: id)
        publish()
        guard queue.running != id else { return }
        finished(id)
        if let next { begin(next) }
    }

    /// The phone locked or the sender switched app: the check does no background work, so it ends here.
    private func enteredBackground() {
        let running = queue.running
        queue.enteredBackground()
        publish()
        if let running { finished(running) }
    }

    private func finished(_ id: String) {
        timeLimit?.cancel()
        timeLimit = nil
        runner?.stop()
        runner = nil
        guard let job = jobs[id], let outcome = queue.outcome(for: id) else { return }
        let milliseconds = startedAt.map { Int($0.duration(to: .now) / .milliseconds(1)) } ?? 0
        recordDiagnostic("share.playcheck", ShareLinkPlayCheck.diagnosticFields(for: outcome, milliseconds: milliseconds, packetBytes: job.packetBytes))
        if !isLineDrawn(for: id), let text = ShareLinkPlayCheck.bannerText(for: outcome, title: job.title) {
            bannered.insert(id)
            showWarning(text)
        }
    }
}

extension ShareLinkPlayChecker {
    /// Joins the checker to the app: a problem found with no sender screen showing becomes a warning banner, and every
    /// finished check leaves one Diagnostics line. The model is held weakly.
    func connect(to model: Gate1AppModel) {
        connectivity = model.connectivity
        showWarning = { [weak model] text in
            model?.presentFeedback(UserFeedbackEvent(kind: .warning, message: text))
        }
        recordDiagnostic = { [weak model] kind, fields in
            model?.recordDeveloperDiagnostic(kind, fields)
        }
    }
}

/// The check's line under Share link (#4454): one element for VoiceOver, wrapping text, an icon that is never the only
/// signal. A problem has a heading and a remedy; every other line has only a heading.
struct ShareLinkPlayCheckLineView: View {
    let line: ShareLinkPlayCheck.Line
    let linkID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(line.heading)
                    .font(line.kind == .warning ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(line.kind == .warning ? AppColors.warningText : AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let remedy = line.remedy {
                    Text(remedy)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
        .accessibilityIdentifier("build23.sender.share.link.playcheck")
        // The checker needs to know which link's line a screen is drawing, to send a problem to the banner when none is.
        .onAppear { ShareLinkPlayChecker.shared.lineDrawn(linkID) }
        .onChange(of: linkID) { old, new in
            ShareLinkPlayChecker.shared.lineHidden(old)
            ShareLinkPlayChecker.shared.lineDrawn(new)
        }
        .onDisappear { ShareLinkPlayChecker.shared.lineHidden(linkID) }
    }

    @ViewBuilder
    private var icon: some View {
        switch line.kind {
        case .checking:
            ProgressView().controlSize(.small)
        case .checked:
            Image(systemName: "checkmark.circle").foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColors.warningText).accessibilityHidden(true)
        case .notChecked:
            EmptyView()
        }
    }
}

/// The share text, readable from any thread (#5264). The sender writes it on the main actor; the share sheet's item
/// source reads it when iOS asks, and reading waits on nothing but the lock.
final class ShareLinkMessageBox: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: "")

    init(text: String = "") {
        storage.withLock { $0 = text }
    }

    var text: String {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

#if canImport(UIKit)
/// The share sheet's text item. It hands over the box's current text both as the placeholder and for whichever
/// destination is picked, so the sentence chosen from a check that finished while the sheet was open reaches the send.
final class ShareLinkMessageItemSource: NSObject, UIActivityItemSource {
    let box: ShareLinkMessageBox

    init(box: ShareLinkMessageBox) {
        self.box = box
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        box.text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        box.text
    }
}

struct ShareLinkActivityView: UIViewControllerRepresentable {
    let message: ShareLinkMessageBox
    /// The `.spokenmargins` file for an item with no web address: the same share, so one message holds both.
    let companionFile: URL?
    var onShared: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        makeController()
    }

    /// The sheet itself, apart from SwiftUI's context so a test can check what it carries and what it reports.
    func makeController() -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: Self.activityItems(message: message, companionFile: companionFile), applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { onShared() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// What the sheet carries (#3787): one text holding the sentence and the link, served by an item source that reads
    /// the sender's box when asked (#5264), then the companion file if there is one. A test reads this;
    /// `UIActivityViewController` doesn't give its items back.
    static func activityItems(message: ShareLinkMessageBox, companionFile: URL?) -> [Any] {
        var items: [Any] = [ShareLinkMessageItemSource(box: message)]
        if let companionFile { items.append(SpokenMarginsPackageActivityItem(packageURL: companionFile)) }
        return items
    }
}
#endif

#endif
