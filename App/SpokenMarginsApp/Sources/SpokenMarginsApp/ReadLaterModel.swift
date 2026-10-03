import Foundation
import SessionKit

/// Credentials never follow a service redirect or enter a shared browser cache.
final class ReadLaterSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@MainActor
final class ReadLaterModel: ObservableObject {
    @Published var service: ReadLaterService = .reader
    @Published var token = ""
    @Published private(set) var documents: [ReadLaterDocument] = []
    @Published private(set) var status = "Connect a service to choose articles. Nothing is imported automatically." {
        didSet { statusIsFailure = false }
    }
    /// A failure is drawn with the failure icon, not as ordinary status (#308).
    @Published private(set) var statusIsFailure = false
    @Published private(set) var isLoading = false
    @Published private(set) var nextCursor: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral, delegate: ReadLaterSessionDelegate(), delegateQueue: nil)
    static let credentialService = "com.spokenmargins.read-later"
    var connected: Bool { KeychainStore.load(service: Self.credentialService, account: service.rawValue) != nil }

    private func fail(_ message: String) {
        status = message
        statusIsFailure = true
    }

    func selectService() {
        generation = UUID(); task?.cancel(); task = nil
        token = ""; documents = []; nextCursor = nil; isLoading = false
        status = connected ? "Connected. Refresh to choose articles." : "Enter an access token to connect."
    }
    func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = "Enter an access token."; return }
        guard KeychainStore.save(value, service: Self.credentialService, account: service.rawValue) == 0 else {
            fail("The token could not be saved securely."); return
        }
        token = ""; refresh()
    }
    func disconnect() {
        guard KeychainStore.save("", service: Self.credentialService, account: service.rawValue) == 0 else {
            fail("The token could not be removed. Try again while the device is unlocked."); return
        }
        selectService(); status = "Disconnected. Imported items and Margins remain in your Library."
    }
    func refresh(more: Bool = false) {
        guard !isLoading, let secret = KeychainStore.load(service: Self.credentialService, account: service.rawValue) else { return }
        let requestedService = service; let requestGeneration = generation
        let cursor = more ? nextCursor : nil
        guard !more || cursor != nil else { return }
        isLoading = true; status = "Fetching articles…"
        task = Task {
            do {
                let client = ReadLaterClient { [session] request in
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw EditionError.invalid("Invalid service response.") }
                    return (data, http)
                }
                let page = try await client.page(service: requestedService, token: secret, cursor: cursor)
                guard generation == requestGeneration else { return }
                if !more { documents = [] }
                var known = Set(documents.map(\.id))
                documents += page.documents.filter { known.insert($0.id).inserted }
                nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
                status = "\(documents.count) articles. Choose Add to import a copy; the service is not changed."
            } catch {
                guard generation == requestGeneration else { return }
                fail((error as? EditionError)?.localizedDescription ?? "Could not load articles. Check the connection and try again.")
            }
            if generation == requestGeneration { isLoading = false }
        }
    }
}
