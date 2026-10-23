import Foundation

/// A link handed over by the Safari extension or the share sheet is downloaded by the app. Offline, that
/// download failed and the payload was quarantined for good, with no message and no retry (#1546). These
/// rules tell a network failure, which should wait and retry, from a failure that retrying won't fix.
public enum PendingHandoffRetryPolicy {
    /// URL loading codes that mean "no usable connection right now": retrying later can succeed.
    public static let transientURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .timedOut,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .dataNotAllowed,
        .internationalRoamingOff,
        .callIsActive
    ]

    #if os(Linux)
    // swift-corelibs-foundation doesn't define the constant; nothing there fills it, so only tests use this.
    static let multipleUnderlyingErrorsKey = "NSMultipleUnderlyingErrorsKey"
    #else
    static let multipleUnderlyingErrorsKey = NSMultipleUnderlyingErrorsKey
    #endif

    /// True when `error`, or an error it wraps, is a connection failure. Follows `NSUnderlyingErrorKey`
    /// chains and the article extractor's wrapped error, a few levels deep.
    public static func isTransientNetworkFailure(_ error: any Error) -> Bool {
        isTransient(error, depth: 0)
    }

    private static func isTransient(_ error: any Error, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }
        if let wrapped = error as? LinkArticleFallbackError, let inner = wrapped.extractorError {
            return isTransient(inner, depth: depth + 1)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return transientURLErrorCodes.contains { $0.rawValue == nsError.code }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error,
           isTransient(underlying, depth: depth + 1) {
            return true
        }
        if let many = nsError.userInfo[multipleUnderlyingErrorsKey] as? [any Error] {
            return many.contains { isTransient($0, depth: depth + 1) }
        }
        return false
    }

    /// What to do with a payload whose import threw `error`. `storeOutcome` maps the handoff store's own
    /// errors (invalid or missing payload) first, so they keep their existing handling.
    public static func outcome(
        for error: any Error,
        storeOutcome: (any Error) -> PendingHandoffOutcome? = { _ in nil }
    ) -> PendingHandoffOutcome {
        if let mapped = storeOutcome(error) { return mapped }
        if isTransientNetworkFailure(error) { return .waitingForNetwork }
        if let notPlayable = error as? SourceLinkNotPlayableError { return .notPlayable(reason: notPlayable.message) }
        return .quarantined(reason: readableReason(for: error))
    }

    /// The error's own words, without the internal `persistence_failed:` code a `SessionKitError` prints.
    public static func readableReason(for error: any Error) -> String {
        if case SessionKitError.persistenceFailed(let message)? = error as? SessionKitError { return message }
        return error.localizedDescription
    }

    /// The Library's one line while links wait, e.g. "1 link waiting for a connection". Nil when none wait.
    public static func waitingLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) link\(count == 1 ? "" : "s") waiting for a connection"
    }
}

/// The link resolved, but to something Spoken Margins can't play (a Spotify-only episode, a page with no audio).
/// The share worked as designed, so it goes to the Import Inbox with `message` and raises no error.
public struct SourceLinkNotPlayableError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

public enum PendingHandoffOutcome: Equatable, Sendable {
    case imported
    /// Left pending: the next activation, or the network coming back, retries it.
    case waitingForNetwork
    /// Moved to the failed inbox; the listener is told.
    case quarantined(reason: String)
    /// Moved to the failed inbox with a readable reason, and no error is raised: the link is simply unsupported.
    case notPlayable(reason: String)
    case deletedInvalidPayload
    case missing

    /// The value written to diagnostics under `pendingSourceLinkPayload:<id>`.
    public var diagnosticValue: String {
        switch self {
        case .imported: return "imported"
        case .waitingForNetwork: return "waiting_for_network"
        case .quarantined(let reason), .notPlayable(let reason): return "quarantined:\(reason)"
        case .deletedInvalidPayload: return "deleted_invalid_payload"
        case .missing: return "missing"
        }
    }
}

/// One pass over the pending handoffs, in order. The store and the importer are closures so the app passes
/// its App Group store and a host test passes a temporary one. Runs on the caller's actor.
public enum PendingHandoffDrain {
    public struct Report: Equatable, Sendable {
        public var outcomes: [(id: String, outcome: PendingHandoffOutcome)]
        public var waitingCount: Int { outcomes.filter { $0.outcome == .waitingForNetwork }.count }
        public var quarantinedCount: Int {
            outcomes.filter {
                switch $0.outcome {
                case .quarantined, .notPlayable: return true
                default: return false
                }
            }.count
        }

        /// The reasons the listener is told about: links that failed for good, not ones that are simply unsupported.
        public var announcedFailures: [String] {
            outcomes.compactMap { entry -> String? in
                if case .quarantined(let reason) = entry.outcome { return reason } else { return nil }
            }
        }

        public init(outcomes: [(id: String, outcome: PendingHandoffOutcome)] = []) {
            self.outcomes = outcomes
        }

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.outcomes.map(\.id) == rhs.outcomes.map(\.id) && lhs.outcomes.map(\.outcome) == rhs.outcomes.map(\.outcome)
        }
    }

    public static func run(
        payloadIDs: [String],
        isolation: isolated (any Actor)? = #isolation,
        importPayload: (String) async throws -> Void,
        deletePayload: (String) async throws -> Void,
        quarantine: (String, String) async throws -> Void,
        storeOutcome: (any Error) -> PendingHandoffOutcome? = { _ in nil },
        record: (String, PendingHandoffOutcome) -> Void = { _, _ in }
    ) async -> Report {
        var report = Report()
        for payloadID in payloadIDs {
            let outcome: PendingHandoffOutcome
            do {
                try await importPayload(payloadID)
                try await deletePayload(payloadID)
                outcome = .imported
            } catch {
                let decided = PendingHandoffRetryPolicy.outcome(for: error, storeOutcome: storeOutcome)
                switch decided {
                case .deletedInvalidPayload:
                    try? await deletePayload(payloadID)
                case .quarantined(let reason), .notPlayable(let reason):
                    try? await quarantine(payloadID, reason)
                case .imported, .waitingForNetwork, .missing:
                    break
                }
                outcome = decided
            }
            record(payloadID, outcome)
            report.outcomes.append((payloadID, outcome))
        }
        return report
    }
}
