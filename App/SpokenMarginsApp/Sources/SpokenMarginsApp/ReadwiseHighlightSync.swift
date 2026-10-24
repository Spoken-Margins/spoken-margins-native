import Foundation
import SessionKit
import SessionKitPersistence

/// "Send Margins to Readwise" (#172): one pass when it's turned on, then one a minute while the app is active.
///
/// Margins are gathered and sent off the main actor, the same way the notes-folder delivery gathers them (#161).
/// The sent-ledger is a file in Application Support, so the database is untouched. A rejected token stops the
/// passes until the listener saves a different token.
@MainActor
final class ReadwiseHighlightSync: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "readwiseHighlightsEnabled")
    @Published private(set) var status = "" {
        didSet { statusIsFailure = false }
    }
    /// A failure is drawn with the failure icon, not as ordinary status (#308).
    @Published private(set) var statusIsFailure = false
    /// Each item's page on readwise.io, for "Open in Readwise" on the item page (#623).
    @Published private(set) var links: [String: URL] = [:]
    /// What the last pass that sent anything sent, kept so a quiet pass doesn't erase it.
    private var lastSummary: String?
    private var lastSentAt: String?
    private var storeProvider: (@MainActor () -> SQLiteSessionStore?)?
    private var task: Task<Void, Never>?
    private var isSending = false
    private var rejectedTokenDigest: String?
    /// Bumped when the connection ends, so a pass that finishes after Disconnect doesn't write its summary (#1467).
    private var connectionEpoch = 0
    private static let resetOwedKey = "readwiseDestinationResetOwed"
    private let session = URLSession(configuration: .ephemeral, delegate: ReadLaterSessionDelegate(), delegateQueue: nil)

    /// Called when the app becomes active. Starts the loop if sending is on.
    func start(store: @escaping @MainActor () -> SQLiteSessionStore?) {
        storeProvider = store
        loadLinks()
        guard enabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendPass()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    /// The ledger is a file that grows with every item sent, so it is read off the main actor (#2510).
    private func loadLinks() {
        let epoch = connectionEpoch
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { try? Self.ledger().links() }.value
            // A pass or a Disconnect that finished first has the newer answer.
            if let self, let loaded, self.links.isEmpty, epoch == self.connectionEpoch { self.links = loaded }
        }
    }

    /// Called when the app leaves the foreground, and when sending is turned off.
    func stop() { task?.cancel(); task = nil }

    func enabledChanged() {
        UserDefaults.standard.set(enabled, forKey: "readwiseHighlightsEnabled")
        // Turning it back on retries a rejected token once, so the reason shows again under the toggle.
        // A reset that failed at Disconnect is retried before anything is sent; sending stays off until it works.
        if enabled, UserDefaults.standard.bool(forKey: Self.resetOwedKey) {
            do { try Self.ledger().startNewDestination(); UserDefaults.standard.set(false, forKey: Self.resetOwedKey); links = [:] }
            catch {
                enabled = false; UserDefaults.standard.set(false, forKey: "readwiseHighlightsEnabled")
                status = "Sending can't start yet: the history of what was sent to the last account could not be reset (\(error.localizedDescription))."
                statusIsFailure = true
                return
            }
        }
        if enabled, let storeProvider { rejectedTokenDigest = nil; start(store: storeProvider) }
        else { stop(); if enabled || !statusIsFailure { status = enabled ? "" : "Sending is off. Highlights already in Readwise stay there." } }
    }

    /// The Readwise connection was removed (#1467). Whatever connects next is a new destination: sending is
    /// off until the listener chooses it again, and nothing counts as already sent to it. Saving a new token
    /// without disconnecting is the same account and keeps both.
    func destinationDisconnected() {
        stop()
        enabled = false
        UserDefaults.standard.set(false, forKey: "readwiseHighlightsEnabled")
        rejectedTokenDigest = nil
        lastSummary = nil; lastSentAt = nil
        connectionEpoch += 1
        do {
            try Self.ledger().startNewDestination()
            UserDefaults.standard.set(false, forKey: Self.resetOwedKey)
            links = [:]
            status = "Sending is off. Highlights already in Readwise stay there."
        } catch {
            // Retried when sending is next turned on; the section is hidden until then.
            UserDefaults.standard.set(true, forKey: Self.resetOwedKey)
            status = "Sending is off, but the history of what was sent could not be reset: \(error.localizedDescription)"
            statusIsFailure = true
        }
    }

    func sendPass() async {
        guard enabled, !isSending, let store = storeProvider?() else { return }
        // Set before the first suspension, so a second pass can't start while this one reads the token (#2510).
        isSending = true
        defer { isSending = false }
        let epoch = connectionEpoch
        let service = ReadLaterModel.credentialService, account = ReadLaterService.reader.rawValue
        // The Keychain and the ledger file are read off the main actor (#2510); the hash is a SHA-256 of the token.
        let credential = await Task.detached(priority: .utility) { () -> (token: String, digest: String)? in
            guard let token = KeychainStore.load(service: service, account: account), !token.isEmpty else { return nil }
            return (token, ListeningEdition.digest(token))
        }.value
        guard epoch == connectionEpoch, enabled else { return }
        guard let (token, tokenDigest) = credential else {
            status = "Connect Readwise Reader above to send Margins."; return
        }
        guard tokenDigest != rejectedTokenDigest else { return }
        do {
            let ledger = try Self.ledger()
            let client = ReadwiseHighlightClient { [session] request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ReadwiseHighlightError.httpStatus(0) }
                return (data, http)
            }
            let work = Task.detached(priority: .utility) {
                let highlights = try ReadwiseHighlightGatherer.highlights(
                    sessions: store.loadSessions(), repository: store, skipping: ledger.sentKeys()
                )
                // #642: Disconnect (or a new token) ends the pass before its next batch.
                let report = try await ReadwiseHighlightSyncPass.run(highlights, token: token, client: client, ledger: ledger) {
                    KeychainStore.load(service: service, account: account) == $0
                }
                return (report: report, links: try? ledger.links())
            }
            // stop() cancels the loop; this carries that into the detached pass so no further batch goes out.
            let done = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard epoch == connectionEpoch else { return }
            rejectedTokenDigest = nil
            let now = Date().formatted(date: .omitted, time: .shortened)
            if let summary = done.report.summary { lastSummary = summary; lastSentAt = now }
            status = ReadwiseSyncReport.statusLine(lastSummary: lastSummary, sentAt: lastSentAt, checkedAt: now)
            links = done.links ?? links
        } catch is CancellationError {
            return
        } catch ReadwiseHighlightError.tokenRejected {
            rejectedTokenDigest = tokenDigest
            status = ReadwiseHighlightError.tokenRejected.errorDescription ?? ""
            statusIsFailure = true
        } catch {
            status = "Sending needs attention: \(error.localizedDescription)"
            statusIsFailure = true
        }
    }

    private nonisolated static func ledger() throws -> ReadwiseSentLedger {
        ReadwiseSentLedger(fileURL: try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenMargins/ReadwiseSentLedger.json"))
    }
}
