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
    private var storeProvider: (@MainActor () -> SQLiteSessionStore?)?
    private var task: Task<Void, Never>?
    private var isSending = false
    private var rejectedTokenDigest: String?
    private let session = URLSession(configuration: .ephemeral, delegate: ReadLaterSessionDelegate(), delegateQueue: nil)

    /// Called when the app becomes active. Starts the loop if sending is on.
    func start(store: @escaping @MainActor () -> SQLiteSessionStore?) {
        storeProvider = store
        guard enabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendPass()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    /// Called when the app leaves the foreground, and when sending is turned off.
    func stop() { task?.cancel(); task = nil }

    func enabledChanged() {
        UserDefaults.standard.set(enabled, forKey: "readwiseHighlightsEnabled")
        // Turning it back on retries a rejected token once, so the reason shows again under the toggle.
        if enabled, let storeProvider { rejectedTokenDigest = nil; start(store: storeProvider) }
        else { stop(); status = enabled ? "" : "Sending is off. Highlights already in Readwise stay there." }
    }

    func sendPass() async {
        guard enabled, !isSending, let store = storeProvider?() else { return }
        guard let token = KeychainStore.load(service: ReadLaterModel.credentialService, account: ReadLaterService.reader.rawValue),
              !token.isEmpty else {
            status = "Connect Readwise Reader above to send Margins."; return
        }
        let tokenDigest = ListeningEdition.digest(token)
        guard tokenDigest != rejectedTokenDigest else { return }
        isSending = true
        defer { isSending = false }
        do {
            let ledger = ReadwiseSentLedger(fileURL: try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SpokenMargins/ReadwiseSentLedger.json"))
            let client = ReadwiseHighlightClient { [session] request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ReadwiseHighlightError.httpStatus(0) }
                return (data, http)
            }
            let service = ReadLaterModel.credentialService, account = ReadLaterService.reader.rawValue
            let work = Task.detached(priority: .utility) {
                let highlights = try ReadwiseHighlightGatherer.highlights(
                    sessions: store.loadSessions(), repository: store, skipping: ledger.sentKeys()
                )
                // #642: Disconnect (or a new token) ends the pass before its next batch.
                return try await ReadwiseHighlightSyncPass.run(highlights, token: token, client: client, ledger: ledger) {
                    KeychainStore.load(service: service, account: account) == $0
                }
            }
            // stop() cancels the loop; this carries that into the detached pass so no further batch goes out.
            let sent = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            rejectedTokenDigest = nil
            status = "\(sent) new Margins sent. Last checked \(Date().formatted(date: .omitted, time: .shortened))."
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
}
