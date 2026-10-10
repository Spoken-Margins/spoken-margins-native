import Foundation

/// What the Read Later screen knows about a service's access token (#944). A token in the Keychain is
/// only "saved"; "Connected" needs an authenticated response from the service for that very token.
public enum ReadLaterConnectionCheck: Equatable, Sendable {
    /// No authenticated response has been seen for the current token this session.
    case notChecked
    /// The service answered an authenticated request for the current token.
    case verified
    /// The service answered 401 or 403 for the current token.
    case rejected
}

/// How one request ended, as far as the token is concerned.
public enum ReadLaterCheckOutcome: Equatable, Sendable {
    case succeeded
    case rejected
    /// No answer about the token: offline, rate limited, a server error, a bad response.
    case inconclusive
}

public struct ReadLaterConnectionPresentation: Equatable, Sendable {
    public enum Symbol: String, Equatable, Sendable {
        case saved = "key"
        case connected = "checkmark.circle"
        case rejected = "exclamationmark.triangle"
    }
    public let text: String
    public let symbol: Symbol
    public var isFailure: Bool { symbol == .rejected }
}

/// Remembers, per service and in memory only, whether the stored token was accepted or rejected, so
/// switching the picker away and back neither forgets a rejection nor invents a success. A request
/// carries the credential generation it started with; an answer for a token that has since been
/// replaced or removed is ignored.
public struct ReadLaterConnectionTracker: Sendable {
    private struct Record: Sendable {
        var generation = 0
        var check = ReadLaterConnectionCheck.notChecked
    }
    private var records: [ReadLaterService: Record] = [:]

    public init() {}

    public func check(for service: ReadLaterService) -> ReadLaterConnectionCheck {
        records[service]?.check ?? .notChecked
    }

    /// The token was saved, replaced or removed: whatever was known about the old one is void.
    /// Returns the generation to attach to the next request.
    @discardableResult
    public mutating func credentialChanged(for service: ReadLaterService) -> Int {
        var record = records[service] ?? Record()
        record.generation += 1
        record.check = .notChecked
        records[service] = record
        return record.generation
    }

    public func generation(for service: ReadLaterService) -> Int {
        records[service]?.generation ?? 0
    }

    /// Records an answer. Returns false when it was for a replaced token and so changed nothing.
    /// An inconclusive answer keeps what was known: a rejected token stays rejected, a verified one
    /// stays verified.
    @discardableResult
    public mutating func record(_ outcome: ReadLaterCheckOutcome, for service: ReadLaterService, generation: Int) -> Bool {
        var record = records[service] ?? Record()
        guard record.generation == generation else { return false }
        switch outcome {
        case .succeeded: record.check = .verified
        case .rejected: record.check = .rejected
        case .inconclusive: break
        }
        records[service] = record
        return true
    }

    /// The line and icon for a service whose token is stored (`hasToken`), or nil when nothing is.
    public func presentation(for service: ReadLaterService, hasToken: Bool) -> ReadLaterConnectionPresentation? {
        guard hasToken else { return nil }
        switch check(for: service) {
        case .verified:
            return ReadLaterConnectionPresentation(text: "Connected. Refresh to choose articles.", symbol: .connected)
        case .rejected:
            return ReadLaterConnectionPresentation(text: "Access rejected — reconnect with a valid token.", symbol: .rejected)
        case .notChecked:
            return ReadLaterConnectionPresentation(text: "Token saved — connection not checked. Refresh to choose articles.", symbol: .saved)
        }
    }

    /// Classifies a failed request by the message the client gave it: only a 401 or 403 says anything
    /// about the token.
    public static func outcome(forFailureMessage message: String?) -> ReadLaterCheckOutcome {
        message == ReadLaterClient.accessRejectedMessage ? .rejected : .inconclusive
    }
}
