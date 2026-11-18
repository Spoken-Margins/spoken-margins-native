import Foundation
import SessionKit

/// Credentials never follow a service redirect or enter a shared browser cache.
final class ReadLaterSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
extension ReadLaterCredentials {
    /// The Keychain. Tests pass an in-memory store instead so they never touch it.
    static let keychain = ReadLaterCredentials(
        load: { KeychainStore.load(service: ReadLaterModel.credentialService, account: $0.rawValue) },
        save: { KeychainStore.save($0, service: ReadLaterModel.credentialService, account: $1.rawValue) }
    )
}

/// The Read Later screen's `ObservableObject`. The state machine is `ReadLaterPickerCore` in SessionKit, where it is
/// tested on the host (#318); this shell forwards to it, redraws SwiftUI before each change as `@Published` did, and
/// owns what only the app has: the Keychain default and the `URLSession` that never follows a redirect.
@MainActor
final class ReadLaterModel: ObservableObject {
    nonisolated static let credentialService = "com.spokenmargins.read-later"
    private let core: ReadLaterPickerCore

    init(transport: ReadLaterClient.Transport? = nil, credentials: ReadLaterCredentials = .keychain) {
        let resolved: ReadLaterClient.Transport
        if let transport {
            resolved = transport
        } else {
            let session = URLSession(configuration: .ephemeral, delegate: ReadLaterSessionDelegate(), delegateQueue: nil)
            resolved = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EditionError.invalid("Invalid service response.") }
                return (data, http)
            }
        }
        core = ReadLaterPickerCore(transport: resolved, credentials: credentials)
        core.onWillChange = { [weak self] in self?.objectWillChange.send() }
    }

    var service: ReadLaterService {
        get { core.service }
        set { core.service = newValue }
    }
    var token: String {
        get { core.token }
        set { core.token = newValue }
    }
    var documents: [ReadLaterDocument] { core.documents }
    var status: String { core.status }
    /// A failure is drawn with the failure icon, not as ordinary status (#308).
    var statusIsFailure: Bool { core.statusIsFailure }
    /// The icon for the stored-token line (#944): a key for saved, a check for verified.
    var statusSymbol: ReadLaterConnectionPresentation.Symbol? { core.statusSymbol }
    var isLoading: Bool { core.isLoading }
    var nextCursor: String? { core.nextCursor }
    var loaded: Bool { core.loaded }
    var failure: String? { core.failure }
    /// A token is stored. That alone is not "connected" (#944); see `ReadLaterConnectionTracker`.
    var connected: Bool { core.connected }
    /// Why Choose Articles is empty, so it never shows a bare heading (#621).
    var emptyArticlesLine: String? { core.emptyArticlesLine }

    func selectService() { core.selectService() }
    func connect() { core.connect() }
    /// Returns whether the token was removed.
    @discardableResult
    func disconnect() -> Bool { core.disconnect() }
    func refresh(more: Bool = false) { core.refresh(more: more) }
}
