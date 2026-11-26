import Foundation

/// The sender's three calls on a reply box beyond the pickup (#4675, `docs/design/reply-mailbox.md` screens D and E):
/// close it, report one answer, and add the written reason a second report owes. Each is a ``ClubClient/Request`` the
/// app's club transport already knows how to send (`Authorization: Bearer <read proof>`), and each answer is read here.
public enum ReplyBoxRequests {
    public enum Failure: Error, Equatable, Sendable {
        /// The record's saved key is damaged or isn't the box's: nothing can be sent for it.
        case damagedRecord
        /// The post number is not a post (posts start at 1).
        case badPost
    }

    /// `POST /api/v1/clubs/<id>/close` with the read proof.
    public static func close(_ record: ReplyBoxRecord) throws(Failure) -> ClubClient.Request {
        let box = try box(of: record)
        return ClubClient.Request(
            method: "POST", path: "/api/v1/clubs/\(box.id)/close", bearer: box.credentials.readProof,
            body: nil, contentType: nil
        )
    }

    /// `POST /api/v1/clubs/<id>/report`, a form with `category`, `post=<seq>`, `reason` when one was written, and for
    /// abuse material only `link=https://<host>/c/<boxId>#<K>`, so the hold keeps a key. `host` is the product host the
    /// app's club transport sends to (the app passes its own; this file names no server).
    public static func report(
        _ record: ReplyBoxRecord, seq: Int, category: ReplyReportCategory, reason: String?, host: String
    ) throws(Failure) -> ClubClient.Request {
        let box = try box(of: record)
        guard seq >= 1 else { throw .badPost }
        var fields: [(String, String)] = [("category", category.rawValue), ("post", String(seq))]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            fields.append(("reason", reason))
        }
        if category.sendsFullLink {
            fields.append(("link", box.invite.url(host: host).absoluteString))
        }
        return ClubClient.Request(
            method: "POST", path: "/api/v1/clubs/\(box.id)/report", bearer: box.credentials.readProof,
            body: formBody(fields), contentType: formContentType
        )
    }

    /// `POST /api/v1/clubs/<id>/report/reason`, a form with the report's `ref` and the `reason`.
    public static func reportReason(_ record: ReplyBoxRecord, reference: String, reason: String) throws(Failure) -> ClubClient.Request {
        let box = try box(of: record)
        return ClubClient.Request(
            method: "POST", path: "/api/v1/clubs/\(box.id)/report/reason", bearer: box.credentials.readProof,
            body: formBody([("ref", reference), ("reason", reason.trimmingCharacters(in: .whitespacesAndNewlines))]),
            contentType: formContentType
        )
    }

    // MARK: Answers

    public enum CloseOutcome: Equatable, Sendable {
        /// Closed, or it had already closed or ended: either way, done. Save `record.markingClosed(at:)`.
        case closed
        /// Offline or a server problem: "Couldn't stop answers. Check your connection and try again."
        case failed
    }

    public static func closeOutcome(status: Int) -> CloseOutcome {
        switch status {
        case 200, 204, 404, 410: .closed
        default: .failed
        }
    }

    public enum ReportOutcome: Equatable, Sendable {
        /// Filed. Hide the answer; close the box if the toggle is on. `reasonOutstanding` keeps the sheet open for a
        /// written reason, sent with ``reportReason(_:reference:reason:)``.
        case sent(reference: String?, reasonOutstanding: Bool)
        /// `404`: the box ended more than 7 days ago, so nothing is left on the server. Hide the answer on this phone.
        case boxEnded
        /// Offline, rate-limited or refused: the sheet stays open and nothing is hidden or closed.
        case failed
    }

    public static func reportOutcome(status: Int, body: Data) -> ReportOutcome {
        switch status {
        case 200:
            struct Filed: Decodable {
                var filed: Bool?
                var reasonOutstanding: Bool?
                var ref: String?
            }
            guard let filed = try? JSONDecoder().decode(Filed.self, from: body) else { return .failed }
            return .sent(reference: filed.ref, reasonOutstanding: filed.reasonOutstanding ?? false)
        case 404: return .boxEnded
        default: return .failed
        }
    }

    /// Whether the written reason went in: a `200`, which a reason already given also answers.
    public static func reportReasonSucceeded(status: Int) -> Bool { status == 200 }

    // MARK: Wire

    public static let formContentType = "application/x-www-form-urlencoded"

    private static func box(of record: ReplyBoxRecord) throws(Failure) -> ReplyBox {
        guard let box = record.box else { throw .damagedRecord }
        return box
    }

    /// `application/x-www-form-urlencoded`: every byte but the unreserved ones is percent-encoded, so `&`, `=`, `+`,
    /// `#` and spaces in a reason can't split or change a field.
    static func formBody(_ fields: [(String, String)]) -> Data {
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }
}
