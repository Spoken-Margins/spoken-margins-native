import Foundation
import SessionKit

/// Credentials never follow a service redirect or enter a shared browser cache.
final class ReadLaterSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
/// Where the Read Later tokens live. Tests pass an in-memory one so they never touch the Keychain.
struct ReadLaterCredentials: Sendable {
    var load: @Sendable (ReadLaterService) -> String?
    var save: @Sendable (String, ReadLaterService) -> OSStatus

    static let keychain = ReadLaterCredentials(
        load: { KeychainStore.load(service: ReadLaterModel.credentialService, account: $0.rawValue) },
        save: { KeychainStore.save($0, service: ReadLaterModel.credentialService, account: $1.rawValue) }
    )
}

@MainActor
final class ReadLaterModel: ObservableObject {
    @Published var service: ReadLaterService = .reader
    @Published var token = ""
    @Published private(set) var documents: [ReadLaterDocument] = []
    @Published private(set) var status = "Connect a service to choose articles. Nothing is imported automatically." {
        didSet { statusIsFailure = false; statusSymbol = nil }
    }
    /// A failure is drawn with the failure icon, not as ordinary status (#308).
    @Published private(set) var statusIsFailure = false
    /// The icon for the stored-token line (#944): a key for saved, a check for verified.
    @Published private(set) var statusSymbol: ReadLaterConnectionPresentation.Symbol?
    @Published private(set) var isLoading = false
    @Published private(set) var nextCursor: String?
    @Published private(set) var loaded = false
    @Published private(set) var failure: String?
    private var generation = UUID()
    /// What this session knows about each service's stored token. It survives picker navigation.
    private var tracker = ReadLaterConnectionTracker()
    private var task: Task<Void, Never>?
    private let transport: ReadLaterClient.Transport
    private let credentials: ReadLaterCredentials
    nonisolated static let credentialService = "com.spokenmargins.read-later"

    init(transport: ReadLaterClient.Transport? = nil, credentials: ReadLaterCredentials = .keychain) {
        self.credentials = credentials
        if let transport {
            self.transport = transport
        } else {
            let session = URLSession(configuration: .ephemeral, delegate: ReadLaterSessionDelegate(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EditionError.invalid("Invalid service response.") }
                return (data, http)
            }
        }
        // A token left from an earlier launch is "saved", not "connected", the moment the screen opens.
        if connected { showStoredTokenStatus() }
    }
    /// A token is stored. That alone is not "connected" (#944); see `ReadLaterConnectionTracker`.
    var connected: Bool { credentials.load(service) != nil }
    /// Why Choose Articles is empty, so it never shows a bare heading (#621).
    var emptyArticlesLine: String? {
        ReadLaterClient.emptyArticlesLine(service: service, connected: connected, isLoading: isLoading, loaded: loaded, failure: failure, documentCount: documents.count)
    }

    private func fail(_ message: String) {
        status = message
        statusIsFailure = true
    }

    /// The line for a stored token: saved, connected or rejected, never "connected" on storage alone.
    private func showStoredTokenStatus() {
        guard let line = tracker.presentation(for: service, hasToken: connected) else {
            status = "Enter an access token to connect."; return
        }
        status = line.text
        statusIsFailure = line.isFailure
        statusSymbol = line.isFailure ? nil : line.symbol
    }

    func selectService() {
        generation = UUID(); task?.cancel(); task = nil
        token = ""; documents = []; nextCursor = nil; isLoading = false; loaded = false; failure = nil
        showStoredTokenStatus()
    }
    func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = "Enter an access token."; return }
        guard credentials.save(value, service) == 0 else {
            fail("The token could not be saved securely."); return
        }
        tracker.credentialChanged(for: service)
        token = ""; refresh()
    }
    func disconnect() {
        guard credentials.save("", service) == 0 else {
            fail("The token could not be removed. Try again while the device is unlocked."); return
        }
        tracker.credentialChanged(for: service)
        selectService(); status = "Disconnected. Imported items and Margins remain in your Library."
    }
    func refresh(more: Bool = false) {
        guard !isLoading, let secret = credentials.load(service) else { return }
        let requestedService = service; let requestGeneration = generation
        let credentialGeneration = tracker.generation(for: requestedService)
        let cursor = more ? nextCursor : nil
        guard !more || cursor != nil else { return }
        isLoading = true; status = "Fetching articles…"
        task = Task {
            do {
                let client = ReadLaterClient(transport: transport)
                let page = try await client.page(service: requestedService, token: secret, cursor: cursor)
                // The service accepted this token, even if the listener has since left this service.
                tracker.record(.succeeded, for: requestedService, generation: credentialGeneration)
                guard generation == requestGeneration else { return }
                if !more { documents = [] }
                var known = Set(documents.map(\.id))
                documents += page.documents.filter { known.insert($0.id).inserted }
                nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
                loaded = true; failure = nil
                status = "\(documents.count) articles. Choose Add to import a copy; the service is not changed."
            } catch {
                let message = (error as? EditionError)?.localizedDescription
                tracker.record(ReadLaterConnectionTracker.outcome(forFailureMessage: message), for: requestedService, generation: credentialGeneration)
                guard generation == requestGeneration else { return }
                fail(message ?? "Could not load articles. Check the connection and try again.")
                failure = status
            }
            if generation == requestGeneration { isLoading = false }
        }
    }
}
