import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the Read Later tokens live. The app passes the Keychain; tests pass an in-memory store so they never touch it.
/// `save` returns 0 for success, as `OSStatus` does, and an empty string removes the token.
public struct ReadLaterCredentials: Sendable {
    public var load: @Sendable (ReadLaterService) -> String?
    public var save: @Sendable (String, ReadLaterService) -> Int32

    public init(
        load: @escaping @Sendable (ReadLaterService) -> String?,
        save: @escaping @Sendable (String, ReadLaterService) -> Int32
    ) {
        self.load = load
        self.save = save
    }
}

/// The Read Later picker's state machine: which service, the token being typed, what the service listed, and the
/// line that says where the connection stands (#944, #621, #308).
///
/// It holds no UI framework. The app's `ReadLaterModel` is the `ObservableObject` around it: it forwards every
/// property and calls `onWillChange` the way `@Published` would, so SwiftUI redraws. The Keychain, the
/// `URLSession` and its redirect policy stay in the app (#318).
@MainActor
public final class ReadLaterPickerCore {
    /// Called just before any property changes, as `@Published` does.
    public var onWillChange: (@MainActor () -> Void)?

    public var service: ReadLaterService = .reader { willSet { onWillChange?() } }
    public var token = "" { willSet { onWillChange?() } }
    public private(set) var documents: [ReadLaterDocument] = [] { willSet { onWillChange?() } }
    public private(set) var status = "Connect a service to choose articles. Nothing is imported automatically." {
        willSet { onWillChange?() }
        didSet { statusIsFailure = false; statusSymbol = nil }
    }
    /// A failure is drawn with the failure icon, not as ordinary status (#308).
    public private(set) var statusIsFailure = false { willSet { onWillChange?() } }
    /// The icon for the stored-token line (#944): a key for saved, a check for verified.
    public private(set) var statusSymbol: ReadLaterConnectionPresentation.Symbol? { willSet { onWillChange?() } }
    public private(set) var isLoading = false { willSet { onWillChange?() } }
    public private(set) var nextCursor: String? { willSet { onWillChange?() } }
    public private(set) var loaded = false { willSet { onWillChange?() } }
    public private(set) var failure: String? { willSet { onWillChange?() } }

    private var generation = UUID()
    /// What this session knows about each service's stored token. It survives picker navigation.
    private var tracker = ReadLaterConnectionTracker()
    private var task: Task<Void, Never>?
    private let transport: ReadLaterClient.Transport
    private let credentials: ReadLaterCredentials

    public init(transport: @escaping ReadLaterClient.Transport, credentials: ReadLaterCredentials) {
        self.transport = transport
        self.credentials = credentials
        // A token left from an earlier launch is "saved", not "connected", the moment the screen opens.
        if connected { showStoredTokenStatus() }
    }

    /// A token is stored. That alone is not "connected" (#944); see `ReadLaterConnectionTracker`.
    public var connected: Bool { credentials.load(service) != nil }

    /// Why Choose Articles is empty, so it never shows a bare heading (#621).
    public var emptyArticlesLine: String? {
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

    public func selectService() {
        generation = UUID(); task?.cancel(); task = nil
        token = ""; documents = []; nextCursor = nil; isLoading = false; loaded = false; failure = nil
        showStoredTokenStatus()
    }

    public func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = "Enter an access token."; return }
        guard credentials.save(value, service) == 0 else {
            fail("The token could not be saved securely."); return
        }
        tracker.credentialChanged(for: service)
        token = ""; refresh()
    }

    /// Returns whether the token was removed.
    @discardableResult
    public func disconnect() -> Bool {
        guard credentials.save("", service) == 0 else {
            fail("The token could not be removed. Try again while the device is unlocked."); return false
        }
        tracker.credentialChanged(for: service)
        selectService(); status = "Disconnected. What you imported and your Margins remain in your Library."
        return true
    }

    public func refresh(more: Bool = false) {
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
