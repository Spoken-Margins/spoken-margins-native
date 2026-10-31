import Foundation

/// A Spoken Margins share link the app was opened with: `https://<host>/l/<id>#<key>` (#488).
///
/// Only that exact shape parses. Another host, another path (`/l/<id>/packet`, `/l/<id>/report`), a bad id, a
/// user, password or odd port all give nil. The `#` part carries the key that opens the sealed packet
/// (``ShareLinkSealing``); a link that lost it still parses, and opening it fails as damaged.
public struct ShareLinkURL: Equatable, Sendable {
    /// The server's link ids are 32 lowercase hex characters (`links.ValidID` in `research/B4`).
    public static let idLength = 32

    public let id: String
    public let key: ShareLinkSealing.Key?

    public init?(url: URL) {
        guard Self.isOnShareHost(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "l" else { return nil }
        let id = String(parts[2])
        guard id.utf8.count == Self.idLength,
              id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        self.id = id
        self.key = ShareLinkSealing.key(inLink: url)
    }

    /// True for any https URL on the share host, whether or not it is a link the app can open.
    ///
    /// Links people send always name the real host, so a Debug build pointed elsewhere (``ProductServer``)
    /// still recognises them; their packet is then fetched from the host in use, and fails like a down server.
    public static func isOnShareHost(_ url: URL) -> Bool {
        isOnShareHost(url, hosts: shareHosts + [ProductServer.productionHost, ProductServer.host])
    }

    /// The hosts a share link may name (#3062). The product moved to `spokenmargins.com`; links made under
    /// the old address keep opening, and the server answers `/l/` on both. Exact hosts only: `www.` is
    /// not listed (it redirects and is not in the app's Associated Domains), and neither is any suffix match.
    public static let shareHosts = ["spokenmargins.com", "spokenmargins.proximitytoprogress.com"]

    static func isOnShareHost(_ url: URL, hosts: [String]) -> Bool {
        hosts.contains { host in
            var policy = BridgeManifestPolicy.production
            policy.trustedHost = host
            return policy.isTrusted(url)
        }
    }

    /// Where the sealed packet is downloaded from.
    public var packetURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = BridgeManifestPolicy.production.trustedHost
        components.path = "/l/\(id)/packet"
        return components.url!
    }
}

/// Downloads a share link's sealed packet and opens it on the phone.
///
/// The packet is fetched anonymously from the pinned host (no cookies, no redirects, a byte cap), opened with
/// the key from the link, and written to a temporary file. That file is byte-identical to the file share, so
/// the usual import review takes it from there.
public struct ShareLinkPacketDownloader: Sendable {
    public typealias Fetch = @Sendable (_ url: URL, _ maximumBytes: Int) async throws -> (status: Int, body: Data)

    public enum Failure: Error, Equatable, Sendable {
        /// The phone couldn't reach the server (no connection, a timeout, a dropped connection). Worth another tap.
        case offline
        /// The server says the link is gone: expired, removed or switched off.
        case expired
        /// The server answered with a fault of its own (too many requests, a 5xx). Worth trying again later.
        case serverProblem
        /// Anything else that stopped the download: an odd answer, an oversized body, a failed secure connection.
        case expiredOrUnreachable
        /// No key, a flipped byte, or a part that isn't a sealed packet.
        case incompleteOrDamaged

        public var message: String {
            switch self {
            case .offline: "You're offline. Reconnect, then tap the link again."
            case .expired: "This link has expired. Ask your friend to share it again."
            case .serverProblem: "The server had a problem. Try again in a minute."
            case .expiredOrUnreachable: "This link has expired or can't be reached."
            case .incompleteOrDamaged: ShareLinkSealing.Failure.incompleteOrDamaged.message
            }
        }

        /// True when the same link may well open on another try, so the app offers a Retry button.
        public var isRetryable: Bool {
            switch self {
            case .offline, .serverProblem: true
            case .expired, .expiredOrUnreachable, .incompleteOrDamaged: false
            }
        }

        static func forStatus(_ status: Int) -> Failure {
            switch status {
            case 404, 410: .expired
            case 429, 500...599: .serverProblem
            default: .expiredOrUnreachable
            }
        }

        static func forNetworkError(_ error: URLError) -> Failure {
            switch error.code {
            case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                .offline
            default:
                .expiredOrUnreachable
            }
        }
    }

    /// The server takes packets up to 20 MB; sealing adds the header, nonce and tag.
    public static let maximumSealedBytes = (20 << 20) + 1024

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Time allowed for the whole download. The largest packet takes about 170 seconds at 1 Mbps, so the public
    /// transport's 30-second cap for small files would call a slow but valid link expired.
    static let resourceTimeout: TimeInterval = 300

    #if !canImport(FoundationNetworking)
    /// The anonymous public transport (no cookies, no redirects, pinned host) with a whole-download cap sized
    /// for `maximumSealedBytes`.
    static func liveConfiguration() -> URLSessionConfiguration {
        BridgePublicTransport.configuration(resourceTimeout: resourceTimeout)
    }

    public static let live = ShareLinkPacketDownloader(fetch: {
        try await BridgePublicTransport.fetch($0, $1, configuration: liveConfiguration())
    })
    #endif

    /// Downloads, opens and writes `<id>.spokenmargins` into `directory`, which is created if needed.
    public func download(_ link: ShareLinkURL, into directory: URL) async throws -> URL {
        // Without the key nothing can open, so don't ask the server for bytes.
        guard let key = link.key else { throw Failure.incompleteOrDamaged }
        let sealed: Data
        do {
            let response = try await fetch(link.packetURL, Self.maximumSealedBytes)
            guard response.status == 200 else { throw Failure.forStatus(response.status) }
            sealed = response.body
        } catch let failure as Failure {
            throw failure
        } catch {
            // A superseded or abandoned download surfaces as URLError.cancelled; callers treat it as a plain cancellation.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let urlError = error as? URLError { throw Failure.forNetworkError(urlError) }
            throw Failure.expiredOrUnreachable
        }
        let packet: Data
        do {
            packet = try ShareLinkSealing.open(sealed, as: .packet, key: key)
        } catch {
            throw Failure.incompleteOrDamaged
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(link.id).spokenmargins")
        try packet.write(to: file, options: .atomic)
        return file
    }
}
