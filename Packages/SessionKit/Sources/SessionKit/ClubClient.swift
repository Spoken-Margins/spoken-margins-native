import Foundation

/// The phone's side of a club mailbox's four calls (#1799, `docs/design/club-mailbox.md` section 5): make a club,
/// post a packet, read what is new. It builds each request and reads each answer. Sending is left to the caller
/// (`Send`), so this file opens no connection; the app wires a transport, and the consent step that must come
/// before the first contact (#2842), when it puts club screens in front of a listener.
///
/// Packets go up and come down as ordinary `.spokenmargins` bytes: ``ClubSealing`` seals each post on the phone,
/// and what ``fetchNew(for:after:)`` returns is the packet exactly as it was posted, which the importer takes in any
/// order and once (#468). A post that does not open (another club's bytes, a flipped byte, a build that cannot
/// read it) is skipped and the cursor still moves past it, so one bad post never blocks a club.
public struct ClubClient: Sendable {
    /// One request, in the terms the server's table uses. The transport turns it into an https request on the
    /// product host with no cookies, no redirects and no identity beyond this bearer value.
    public struct Request: Equatable, Sendable, CustomStringConvertible {
        public var method: String
        /// Path and query: `/api/v1/clubs/<id>/posts?after=3`.
        public var path: String
        /// A proof, sent as `Authorization: Bearer <proof>`.
        public var bearer: String?
        public var body: Data?
        public var contentType: String?

        /// Never prints the bearer proof or the body.
        public var description: String { "\(method) \(path)" }
    }

    public typealias Send = @Sendable (_ request: Request, _ maximumBytes: Int) async throws -> (status: Int, body: Data)

    public enum Failure: Error, Equatable, Sendable {
        /// The phone couldn't reach the server. Worth another try.
        case offline
        /// The server doesn't know this club, or the link's proofs are wrong. It answers the two the same way.
        case notFound
        /// The club ended: 90 days with no use, no post in its first 7 days, or it was taken down.
        case gone
        /// The club holds as many posts or bytes as it may.
        case clubFull
        /// This post is over the 20 MB a post may be.
        case tooLarge
        /// The server is busy or switched off for now, or asked this phone to slow down. Worth trying later.
        case serverProblem
        /// An answer this build doesn't understand.
        case unexpected
        /// The header or a post didn't open with this link's key.
        case incompleteOrDamaged

        public var message: String {
            switch self {
            case .offline: "You're offline. Reconnect and try again."
            case .notFound: "This club link doesn't open a club. Ask your friend to send it again."
            case .gone: "This club has ended."
            case .clubFull: "This club is full. You can start a new one."
            case .tooLarge: "That is too big to post to a club."
            case .serverProblem: "The server had a problem. Try again in a minute."
            case .unexpected: "The server gave an answer this version of the app can't use."
            case .incompleteOrDamaged: ClubSealing.Failure.incompleteOrDamaged.message
            }
        }

        public var isRetryable: Bool {
            switch self {
            case .offline, .serverProblem: true
            case .notFound, .gone, .clubFull, .tooLarge, .unexpected, .incompleteOrDamaged: false
            }
        }
    }

    /// Where a phone has read up to in one club: the number of the last post it dealt with, merged or skipped.
    /// Kept per club on the phone; the server keeps nothing about who has read what.
    public struct Cursor: Codable, Equatable, Sendable {
        public var lastPost: Int

        public init(lastPost: Int = 0) {
            self.lastPost = max(0, lastPost)
        }

        /// A saved cursor that is damaged (negative) starts the club over rather than asking the server for `after=-1`.
        public init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .lastPost)
            self.init(lastPost: value)
        }
    }

    /// One post that opened: its number and the packet's exact bytes.
    public struct Post: Equatable, Sendable {
        public let number: Int
        public let packet: Data
    }

    public struct Fetched: Equatable, Sendable {
        /// Packets that opened, in post order.
        public let posts: [Post]
        /// Numbers of posts that did not open and were passed over.
        public let skipped: [Int]
        /// Pass this back next time. It sits after the last post dealt with, even when `stoppedBy` is set.
        public let cursor: Cursor
        /// Set when a call failed partway: `posts` and `cursor` are what was dealt with before it.
        public let stoppedBy: Failure?
    }

    /// The server's caps, on the sealed bytes: a post is at most 20 MiB (`links.MaxPacketBytes`), a header 16 KiB.
    public static let maximumPostBytes = 20 << 20
    public static let maximumHeaderBytes = 16 << 10
    static let maximumListBytes = 1 << 20
    /// A club holds at most 200 posts (`clubs.DefaultMaxPosts`). A list that names a number far past the cursor is
    /// a faulty or hostile answer, and following it would carry the cursor beyond every real post.
    static let maximumJump = 1_000

    private let send: Send

    public init(send: @escaping Send) {
        self.send = send
    }

    // MARK: Calls

    /// Makes the club on the server with its sealed header. A repeat of the same club (a retry after a lost answer)
    /// is the same success.
    public func create(_ invite: ClubInvite, header: ClubHeader) async throws {
        let sealed: Data
        let body: Data
        do {
            sealed = try invite.sealedHeader(header)
            guard sealed.count <= Self.maximumHeaderBytes else { throw Failure.tooLarge }
            body = try Self.createBody(for: invite, sealedHeader: sealed)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.incompleteOrDamaged
        }
        let response = try await perform(
            Request(method: "POST", path: "/api/v1/clubs", bearer: nil, body: body, contentType: "application/json"),
            maximumBytes: 4 << 10
        )
        switch response.status {
        case 200, 201: return
        default: throw Failure.forStatus(response.status, body: response.body)
        }
    }

    /// Reads the club's name from its sealed header, so a joiner sees what they are joining before anything is sent.
    public func header(of invite: ClubInvite) async throws -> ClubHeader {
        let response = try await perform(item(0, of: invite), maximumBytes: Self.maximumHeaderBytes)
        guard response.status == 200 else { throw Failure.forStatus(response.status, body: response.body) }
        do {
            return try invite.openHeader(response.body)
        } catch {
            throw Failure.incompleteOrDamaged
        }
    }

    /// Seals `packet` and adds it to the club. Returns the number the server gave the post.
    @discardableResult
    public func post(_ packet: Data, to invite: ClubInvite) async throws -> Int {
        let sealed: Data
        do {
            sealed = try ClubSealing.seal(packet, as: .post, in: invite.credentials)
        } catch {
            throw Failure.incompleteOrDamaged
        }
        guard sealed.count <= Self.maximumPostBytes else { throw Failure.tooLarge }
        let response = try await perform(
            Request(
                method: "POST",
                path: "/api/v1/clubs/\(invite.id)/posts",
                bearer: invite.credentials.postProof,
                body: sealed,
                contentType: "application/octet-stream"
            ),
            maximumBytes: 4 << 10
        )
        guard response.status == 201 else { throw Failure.forStatus(response.status, body: response.body) }
        guard let number = try? JSONDecoder().decode(PostedNumber.self, from: response.body).seq, number >= 1 else {
            throw Failure.unexpected
        }
        return number
    }

    /// Everything posted after `cursor`, opened. A post that does not open is skipped; a failed call stops the run
    /// and reports how far it got, so nothing already fetched is lost. A cancelled run throws instead: the caller
    /// keeps its old cursor, so the same posts come again next time.
    ///
    /// A list entry more than ``maximumJump`` past the cursor is ignored, so a hostile list cannot move the cursor
    /// past every real post. A post the list named and the box then answers `404` for is passed over: the real
    /// server only does that for a post removed between the two calls.
    public func fetchNew(for invite: ClubInvite, after cursor: Cursor) async throws -> Fetched {
        let listed = try await perform(
            Request(
                method: "GET",
                path: "/api/v1/clubs/\(invite.id)/posts?after=\(cursor.lastPost)",
                bearer: invite.credentials.readProof,
                body: nil,
                contentType: nil
            ),
            maximumBytes: Self.maximumListBytes
        )
        guard listed.status == 200 else { throw Failure.forStatus(listed.status, body: listed.body) }
        guard let list = try? JSONDecoder().decode(PostList.self, from: listed.body) else { throw Failure.unexpected }
        // Oldest first, each once, and only numbers after the cursor: a server that repeats, reorders or goes
        // backwards cannot make a phone fetch or merge a post twice.
        var seen = Set<Int>()
        let numbers = list.posts.map(\.seq)
            .filter { $0 > cursor.lastPost && $0 <= cursor.lastPost + Self.maximumJump && seen.insert($0).inserted }
            .sorted()

        var posts: [Post] = []
        var skipped: [Int] = []
        var last = cursor.lastPost
        for number in numbers {
            let response: (status: Int, body: Data)
            do {
                response = try await perform(item(number, of: invite), maximumBytes: Self.maximumPostBytes)
            } catch let failure as Failure {
                return Fetched(posts: posts, skipped: skipped, cursor: Cursor(lastPost: last), stoppedBy: failure)
            }
            switch response.status {
            case 200:
                if let packet = try? ClubSealing.open(response.body, as: .post, in: invite.credentials) {
                    posts.append(Post(number: number, packet: packet))
                } else {
                    skipped.append(number)
                }
            case 404:
                // The list named it and the box no longer has it (a post taken down between the two calls):
                // pass over it like one that does not open.
                skipped.append(number)
            default:
                return Fetched(
                    posts: posts, skipped: skipped, cursor: Cursor(lastPost: last),
                    stoppedBy: Failure.forStatus(response.status, body: response.body)
                )
            }
            last = number
        }
        return Fetched(posts: posts, skipped: skipped, cursor: Cursor(lastPost: last), stoppedBy: nil)
    }

    // MARK: Wire

    private struct PostedNumber: Decodable { let seq: Int }
    private struct PostList: Decodable {
        struct Entry: Decodable { let seq: Int }
        let posts: [Entry]
    }
    private struct ErrorBody: Decodable { let error: String }

    static func createBody(for invite: ClubInvite, sealedHeader: Data) throws -> Data {
        struct Body: Encodable {
            let id: String
            let readHash: String
            let postHash: String
            let header: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Body(
            id: invite.id,
            readHash: invite.credentials.readHash,
            postHash: invite.credentials.postHash,
            header: sealedHeader.base64EncodedString()
        ))
    }

    private func item(_ number: Int, of invite: ClubInvite) -> Request {
        Request(
            method: "GET",
            path: "/api/v1/clubs/\(invite.id)/posts/\(number)",
            bearer: invite.credentials.readProof,
            body: nil,
            contentType: nil
        )
    }

    private func perform(_ request: Request, maximumBytes: Int) async throws -> (status: Int, body: Data) {
        do {
            let response = try await send(request, maximumBytes)
            return response
        } catch let failure as Failure {
            throw failure
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let urlError = error as? URLError { throw Failure.forNetworkError(urlError) }
            throw Failure.unexpected
        }
    }
}

extension ClubClient.Failure {
    static func forStatus(_ status: Int, body: Data) -> ClubClient.Failure {
        let code = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        switch (status, code) {
        case (404, _): return .notFound
        case (410, _): return .gone
        case (409, "club_full"): return .clubFull
        case (413, _): return .tooLarge
        case (429, _), (500...599, _): return .serverProblem
        default: return .unexpected
        }
    }

    static func forNetworkError(_ error: URLError) -> ClubClient.Failure {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            .offline
        default:
            .unexpected
        }
    }
}
