import Foundation
import SessionKit

/// The browser text link for this build flavor. The parsing and building live in SessionKit's `BrowserTextHandoffURL`;
/// this picks the scheme, which the legacy flavor changes.
enum Gate5BrowserTextHandoffURL {
    #if SPOKEN_MARGINS_LEGACY
    static let scheme = "spokenmargins-legacy"
    #else
    static let scheme = "spokenmargins"
    #endif
    static let host = BrowserTextHandoffURL.host

    private static let codec = BrowserTextHandoffURL(scheme: scheme)

    static func isBrowserTextURL(_ url: URL) -> Bool {
        codec.isBrowserTextURL(url)
    }

    static func payloadID(from url: URL) -> String? {
        codec.payloadID(from: url)
    }

    static func handoff(from url: URL) -> BrowserTextHandoff? {
        codec.handoff(from: url)
    }

    static func handoff(from url: URL, store: Gate5BrowserTextHandoffStore) throws -> BrowserTextHandoff {
        try codec.handoff(from: url, store: store)
    }

    static func url(for handoff: BrowserTextHandoff) -> URL {
        codec.url(for: handoff)
    }

    static func url(forPayloadID payloadID: String) -> URL {
        codec.url(forPayloadID: payloadID)
    }
}
