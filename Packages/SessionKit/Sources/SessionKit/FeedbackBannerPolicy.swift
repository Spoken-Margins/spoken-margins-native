import Foundation

/// How long the app's top feedback banner stays, and what may replace it (#310).
///
/// Error banners used to dismiss themselves after 6 seconds, so a listener who looked at the phone
/// late never learned what went wrong. An error now stays until the listener closes it or a newer
/// event replaces it, and an error that offers Retry stays until the listener closes it or retries.
public enum FeedbackBannerPolicy {
    public enum Kind: Equatable, Sendable {
        case success
        case warning
        case error
    }

    /// Seconds before the banner dismisses itself, or nil when only the listener dismisses it.
    public static func autoDismissSeconds(for kind: Kind) -> Double? {
        switch kind {
        case .success: 3
        case .warning: 6
        case .error: nil
        }
    }

    /// Whether a new banner may take the place of the one on screen. Another error always may, so
    /// the newest failure is the one shown. A confirmation or warning may not cover an error that
    /// offers Retry: the listener hasn't acted on it yet.
    public static func mayReplace(currentKind: Kind, currentOffersRetry: Bool, with newKind: Kind) -> Bool {
        guard currentKind == .error, currentOffersRetry else { return true }
        return newKind == .error
    }
}

/// The last failure reported on each item, kept so it stays readable on the item after the banner
/// has gone (#310). It lives for the app run only: nothing is written to the Library.
public struct ItemFailureLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let message: String
        public let occurredAt: Date

        public init(message: String, occurredAt: Date) {
            self.message = message
            self.occurredAt = occurredAt
        }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func record(_ message: String, itemId: String, at date: Date = Date()) {
        guard !itemId.isEmpty else { return }
        entries[itemId] = Entry(message: message, occurredAt: date)
    }

    public func lastFailure(itemId: String) -> Entry? {
        entries[itemId]
    }

    public mutating func clear(itemId: String) {
        entries[itemId] = nil
    }
}
