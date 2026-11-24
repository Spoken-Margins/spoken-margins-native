import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit

/// A list address read for the "Add <list>" preview (#4046 PR 7a), before any list or link exists. The same request,
/// limits and include rules as a check: one anonymous GET, includes three deep, 25 files, 500 shows.
public struct ListLinkFetch: Equatable, Sendable {
    public var resolution: ListLinkResolution
    /// The address to store: where a run of permanent redirects (301, 308) ended, else the address as given.
    public var url: String
    /// Kept only for a file with no includes, as a check does: a 304 says nothing about the lists a file includes.
    public var etag: String?
    public var lastModified: String?
}

/// Why a list address could not be previewed, in the words the Follow sheet shows.
public enum ListLinkFetchFailure: Error, Equatable, Sendable {
    /// Offline, a timeout, a refused connection, a bad redirect, an error status.
    case unreachable
    /// The address answered and it is not an OPML list.
    case notAList
    /// Over 4 MB, 5,000 outlines or 500 shows.
    case tooBig

    public var message: String {
        switch self {
        case .unreachable: ListLinkWords.unreachable
        case .notAList: ListLinkWords.notAListOrFeed
        case .tooBig: ListLinkWords.tooBigToAdd
        }
    }
}

extension ListLinkChecker {
    /// Reads a list address once for the preview. Throws `ListLinkFetchFailure`, or `CancellationError` when the
    /// listener tapped Cancel.
    public func fetch(_ url: URL) async throws -> ListLinkFetch {
        let reply: ListLinkTransport.Reply
        do {
            reply = try await ListLinkTransport.get(url, accept: Self.accept, maximumBytes: limits.maximumBytes, session: session)
        } catch let failure as ListLinkTransport.Failure {
            switch failure {
            case .cancelled: throw CancellationError()
            case .tooBig: throw ListLinkFetchFailure.tooBig
            case .network, .badRedirect: throw ListLinkFetchFailure.unreachable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ListLinkFetchFailure.unreachable
        }
        guard (200..<300).contains(reply.status) else { throw ListLinkFetchFailure.unreachable }
        let document: OPMLDocument
        do {
            document = try OPMLParser.parse(reply.data, limits: limits)
        } catch OPMLError.tooLarge, OPMLError.tooManyOutlines {
            throw ListLinkFetchFailure.tooBig
        } catch {
            throw ListLinkFetchFailure.notAList
        }
        let resolution: ListLinkResolution
        do {
            resolution = try await resolve(document, at: reply.finalURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ListLinkFetchFailure.tooBig
        }
        let keepsValidators = document.includes.isEmpty
        return ListLinkFetch(
            resolution: resolution,
            url: (reply.permanentURL ?? url).absoluteString,
            etag: keepsValidators ? reply.validators.etag : nil,
            lastModified: keepsValidators ? reply.validators.lastModified : nil
        )
    }
}
