import Foundation

// The sender check before a share link (#2239 step 3). `POST /api/v1/links/sender` is attested and carries no
// content (research/B4/server/internal/api/sender.go). The answer is the install's standing on the strike ladder and,
// when sharing is allowed, a one-use permit the upload then sends in `X-SM-Link-Permit`. The server ties the new link
// to a keyed hash of the install until the link expires, so a report of that link can count toward the ladder.
//
// What the sender is told is deliberately small and the same for every report category: one line when a link was
// taken down, and a plain pause or end message. No button, no category, no way to dispute (owner, 2026-10-20).

/// The one line shown when a link the sender made was taken down after a report. It never names a category: an
/// abuse-material report reads the same as any other. The words are the app's own; the server only says whether to
/// show them, so a changed server answer can't put anything else on the screen.
public enum ShareLinkTakedownNotice {
    public static let text = "A link you shared was taken down after a report"
}

/// What the server said about this install as a sender.
public struct ShareLinkSenderStanding: Equatable, Sendable {
    /// Present only when sharing is allowed; spent by one upload and good for about ten minutes.
    public var permit: String?
    public var sharingPausedUntil: Date?
    public var sharingEnded: Bool
    /// A link was taken down since the last check. Shown once, then the server forgets it.
    public var hasTakedownNotice: Bool

    public var sharingAllowed: Bool { permit != nil }
}

public enum ShareLinkSenderCheckOutcome: Equatable, Sendable {
    case standing(ShareLinkSenderStanding)
    /// The standing could not be established on this phone, so there is nothing to check: it can't attest (the
    /// Simulator, a few older devices), Apple's call failed (the app has no App Attest entitlement until the owner
    /// enables the capability), or the server did not accept the registration or the request. What happens next is the
    /// fault policy's call (`ShareLinkFaultPolicy`, #4134): with refuse mode off, as today, the link is made without a
    /// permit, because the server does not require one until a real phone has proven the path (#1593); with it on, the
    /// reason picks the line the sender sees.
    case notChecked(ShareLinkUncheckedReason)
    /// The check could not be made and no link should be: the reason, as the sender screen already says it.
    case failed(ShareLinkFallback)
}

/// Why the sender check has no standing (#4134). One case per fault in the Design's table, so each can be mapped on its
/// own in refuse mode and tested.
public enum ShareLinkUncheckedReason: Equatable, Sendable, CaseIterable {
    /// The phone can't attest (`AppAttestFailure.unsupported`).
    case cannotAttest
    /// Apple's attest call, the registration or the gate timed out or failed: may pass on a later try.
    case attestFailed
    /// A registration failed recently and the client is waiting before it tries again (up to 6 hours, in memory).
    case registrationWaiting
    /// 401 `clock_skew`: the phone's clock is more than five minutes from the server's.
    case clockSkew
    /// 401 `unknown_key` after the client's one key replacement.
    case unknownKey
    /// 401 `invalid_assertion` past the bounded re-attest.
    case invalidAssertion
    /// 401 `missing_assertion`, or a 401 the app can't read.
    case missingAssertion
    /// 400, 404 or any other answer the sender endpoint shouldn't give.
    case rejected
    /// 503 `disabled`: the server operator turned the attest service or the sender ledger off, which means "make the
    /// link unattributed" (smserver: "without it links still work, unattributed").
    case operatorDisabled
    /// Any other 5xx.
    case serverError
}

public enum ShareLinkSenderCheck {
    public static let path = "/api/v1/links/sender"

    /// Asks the server for the install's standing. Never throws: every failure is an outcome the screen handles.
    public static func check(using client: AttestedServerClient) async -> ShareLinkSenderCheckOutcome {
        let answer: (status: Int, body: Data)
        do {
            answer = try await client.send(path: path, body: Data())
        } catch AppAttestFailure.unsupported {
            return .notChecked(.cannotAttest)
        } catch AppAttestFailure.offline {
            return .failed(.offline)
        } catch AppAttestFailure.needsConsent {
            return .failed(.unavailable)
        } catch AppAttestFailure.refused {
            // This install is blocked. The server says nothing more, and neither does the app.
            return .failed(.unavailable)
        } catch AppAttestFailure.registrationWaiting {
            return .notChecked(.registrationWaiting)
        } catch {
            // Apple's call or the registration failed: no standing could be established, and none is assumed.
            return .notChecked(.attestFailed)
        }
        switch answer.status {
        case 200:
            guard let standing = decode(answer.body) else { return .failed(.failed) }
            return .standing(standing)
        case 429: return .failed(.busy)
        default: return .notChecked(uncheckedReason(status: answer.status, body: answer.body))
        }
    }

    /// The reason for an answer that is neither a standing nor a failure the screen already says (#4134). The error
    /// codes are the attested middleware's (`research/B4/server/internal/api/api.go`, `attested`).
    static func uncheckedReason(status: Int, body: Data) -> ShareLinkUncheckedReason {
        let code = AttestedServerClient.errorCode(body)
        switch status {
        case 401:
            switch code {
            case "clock_skew": return .clockSkew
            case "unknown_key": return .unknownKey
            case "invalid_assertion": return .invalidAssertion
            default: return .missingAssertion
            }
        // 503 `disabled` is the attest service or the sender ledger being off, which the server means as "make the link
        // unattributed". If links themselves are off, the upload's own 503 says so.
        case 503 where code == "disabled": return .operatorDisabled
        case 500...599: return .serverError
        default: return .rejected
        }
    }

    static func decode(_ body: Data) -> ShareLinkSenderStanding? {
        struct Answer: Decodable {
            var sharingAllowed: Bool
            var sharingEnded: Bool
            var notice: String?
            var sharingPausedUntil: String?
            var permit: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: body) else { return nil }
        // An allowed answer without a permit, or a permit on a refusal, is not an answer this app understands.
        let permit = answer.permit.flatMap { $0.isEmpty ? nil : $0 }
        guard answer.sharingAllowed == (permit != nil) else { return nil }
        return ShareLinkSenderStanding(
            permit: permit,
            sharingPausedUntil: answer.sharingPausedUntil.flatMap(parseDate),
            sharingEnded: answer.sharingEnded,
            hasTakedownNotice: !(answer.notice ?? "").isEmpty
        )
    }

    /// Go writes RFC 3339 with up to nanoseconds; accept it with or without a fraction.
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Nanosecond fractions are longer than the formatter takes: cut the fraction to milliseconds.
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        let fraction = text[text.index(after: dot)..<zone].prefix(3)
        return fractional.date(from: String(text[..<dot]) + "." + fraction + String(text[zone...]))
    }
}

/// The takedown line, kept until the sender's screen has shown it. The server marks a notice shown the moment it
/// sends it, so a notice the phone drops would be lost; the phone keeps it until a screen has had it on show.
public final class ShareLinkTakedownNoticeStore: @unchecked Sendable {
    public static let defaultsKey = "shareLinkTakedownNotice.pending"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isPending: Bool { defaults.bool(forKey: Self.defaultsKey) }
    public func setPending() { defaults.set(true, forKey: Self.defaultsKey) }
    public func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}
