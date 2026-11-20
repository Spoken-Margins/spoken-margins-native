import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit

/// Every show a list address offers now, including the lists it includes (#4046 PR 6).
public struct ListLinkResolution: Equatable, Sendable {
    /// The file's `<head><title>`.
    public var title: String?
    /// Each show once, in file order: the file's own rows, then each include's.
    public var shows: [ProposedShow]
    /// Some included list was not read: it went deeper than three levels, repeated, or could not be fetched.
    public var leftOut: Bool
    /// Part of the list is unknown, so a show that is missing may only be unread. `leftOut` for a repeat is not this: the
    /// repeat was read once already.
    public var incomplete: Bool
}

/// Reads a list address and says what changed (#4046 PR 6).
///
/// One conditional GET of the file (`ETag`, `Last-Modified`), a 301 or 308 moves the stored address, and the includes inside
/// it are read during the check and never stored: at most three levels deep, each address once, at most 25 files and 500
/// shows, and the parser's own caps on one file (4 MB, 5,000 outlines). Nothing here fetches a feed or follows a show, and
/// nothing runs unless a listener's action called it (`ListLinkRunner`).
///
/// Every outcome that is not a read leaves the shows as they are: a failed check changes the status and its time, and no
/// proposal is written.
public actor ListLinkChecker {
    public static let maximumDepth = 3
    public static let maximumShows = 500
    public static let maximumFiles = 25
    static let accept = "text/x-opml, text/xml, application/xml, text/plain;q=0.5, */*;q=0.1"

    private let session: URLSession
    private let limits: OPMLLimits

    public init(session: URLSession, limits: OPMLLimits = OPMLLimits()) {
        self.session = session
        self.limits = limits
    }

    /// The link after one check, or nil when the check was cancelled (nothing is saved for a cancelled check).
    public func check(_ link: ListLink, now: Date) async -> ListLink? {
        guard let url = URL(string: link.url) else { return failed(link, .notAList, now) }
        let sent = ListLinkTransport.Validators(etag: link.etag, lastModified: link.lastModified)
        let reply: ListLinkTransport.Reply
        do {
            reply = try await ListLinkTransport.get(
                url, accept: Self.accept, validators: sent.etag == nil && sent.lastModified == nil ? nil : sent,
                maximumBytes: limits.maximumBytes, session: session)
        } catch let failure as ListLinkTransport.Failure {
            switch failure {
            case .cancelled: return nil
            case .tooBig: return failed(link, .tooBig, now)
            case .network, .badRedirect: return failed(link, .unreachable, now)
            }
        } catch is CancellationError {
            return nil
        } catch {
            return failed(link, .unreachable, now)
        }

        if reply.status == 304 {
            var unchanged = link
            unchanged.status = .ok
            unchanged.statusAt = now
            unchanged.lastCheckedAt = now
            return unchanged
        }
        guard (200..<300).contains(reply.status) else {
            return failed(link, reply.status == 404 || reply.status == 410 ? .gone : .unreachable, now)
        }

        let document: OPMLDocument
        do {
            document = try OPMLParser.parse(reply.data, limits: limits)
        } catch OPMLError.tooLarge, OPMLError.tooManyOutlines {
            return failed(link, .tooBig, now)
        } catch {
            return failed(link, .notAList, now)
        }

        let resolution: ListLinkResolution
        do {
            resolution = try await resolve(document, at: reply.finalURL)
        } catch is CancellationError {
            return nil
        } catch {
            return failed(link, .tooBig, now)
        }

        var checked = link
        if let moved = reply.permanentURL { checked.url = moved.absoluteString }
        // A 304 says nothing about the lists a file includes, so a file with includes is read in full every time.
        let keepsValidators = document.includes.isEmpty
        checked.etag = keepsValidators ? reply.validators.etag : nil
        checked.lastModified = keepsValidators ? reply.validators.lastModified : nil
        checked.status = .ok
        checked.statusAt = now
        checked.lastCheckedAt = now
        checked.pending = ListLinkDiff.proposal(
            resolved: resolution.shows, accepted: link.acceptedMembers, rejected: link.rejectedMembers,
            suppressRemovals: resolution.incomplete, checkedAt: now)
        return checked
    }

    /// A failed check moves only the status and when it was set. The shows, the waiting change, the validators and the
    /// time of the last good read stay.
    private func failed(_ link: ListLink, _ status: ListLink.Status, _ now: Date) -> ListLink {
        var result = link
        result.status = status
        result.statusAt = now
        return result
    }

    /// The shows in a parsed file and in the lists it includes. Throws `Overflow` past 500 shows.
    func resolve(_ document: OPMLDocument, at rootURL: URL) async throws -> ListLinkResolution {
        let state = ResolveState(rootKey: FeedURLKey.make(rootURL.absoluteString))
        try state.add(document.feeds, via: nil)
        try await visit(document.includes, depth: 1, topTitle: nil, state: state)
        return ListLinkResolution(title: document.title, shows: state.shows, leftOut: state.leftOut, incomplete: state.incomplete)
    }

    private func visit(_ includes: [OPMLInclude], depth: Int, topTitle: String?, state: ResolveState) async throws {
        for include in includes {
            try Task.checkCancellation()
            guard depth <= Self.maximumDepth else {
                state.leftOut = true
                state.incomplete = true
                continue
            }
            guard let url = URL(string: include.url), let key = FeedURLKey.make(include.url) else {
                state.leftOut = true
                state.incomplete = true
                continue
            }
            // A list met twice is read once: the second is a repeat or a cycle.
            guard state.visited.insert(key).inserted else {
                state.leftOut = true
                continue
            }
            guard state.files < Self.maximumFiles else {
                state.leftOut = true
                state.incomplete = true
                continue
            }
            state.files += 1
            let via = topTitle ?? include.title
            let included: OPMLDocument
            do {
                let reply = try await ListLinkTransport.get(url, accept: Self.accept, maximumBytes: limits.maximumBytes, session: session)
                guard (200..<300).contains(reply.status) else { throw ListLinkTransport.Failure.network }
                included = try OPMLParser.parse(reply.data, limits: limits)
            } catch ListLinkTransport.Failure.cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A list that can't be read now doesn't make its shows removals, and doesn't stop the others.
                state.leftOut = true
                state.incomplete = true
                continue
            }
            try state.add(included.feeds, via: via)
            try await visit(included.includes, depth: depth + 1, topTitle: via, state: state)
        }
    }

    /// More than 500 shows. The whole list is too big to offer.
    struct Overflow: Error {}

    private final class ResolveState {
        var shows: [ProposedShow] = []
        var visited: Set<String>
        var files = 1
        var leftOut = false
        var incomplete = false
        private var byKey: [String: Int] = [:]
        private var byGUID: [String: Int] = [:]

        init(rootKey: String?) {
            visited = rootKey.map { [$0] } ?? []
        }

        func add(_ feeds: [OPMLFeed], via: String?) throws {
            for feed in feeds {
                guard let key = FeedURLKey.make(feed.feedURL) else { continue }
                let member = ListMember(feedKey: key, podcastGUID: feed.podcastGUID)
                let guid = member.podcastGUID?.lowercased()
                let viaTitle = via ?? feed.sm.via
                if let index = byKey[key] ?? guid.flatMap({ byGUID[$0] }) {
                    if shows[index].member.podcastGUID == nil, let guid {
                        shows[index].member.podcastGUID = member.podcastGUID
                        byGUID[guid] = index
                    }
                    if shows[index].viaTitle == nil { shows[index].viaTitle = viaTitle }
                    byKey[key] = index
                    continue
                }
                guard shows.count < ListLinkChecker.maximumShows else { throw Overflow() }
                byKey[key] = shows.count
                if let guid { byGUID[guid] = shows.count }
                shows.append(ProposedShow(member: member, feedURL: feed.feedURL, title: feed.title, viaTitle: viaTitle))
            }
        }
    }
}
