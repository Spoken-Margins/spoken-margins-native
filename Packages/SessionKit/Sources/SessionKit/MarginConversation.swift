#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where a shared Margin lives in the packets: the digest of the packet it was shared in, and its
/// package-scoped id there. Every listener who holds that packet names the Margin the same way,
/// so this is how replies find their parent across Libraries (#472).
public struct MarginPacketIdentity: Codable, Hashable, Sendable {
    public let packageDigest: String
    public let packageScopedId: String

    public init(packageDigest: String, packageScopedId: String) {
        self.packageDigest = packageDigest
        self.packageScopedId = packageScopedId
    }
}

/// A reply's link to the shared Margin it answers (owner defaults on #19, 2026-08-22): the
/// conversation it belongs to, and the parent's packet identity. The parent's audio is never
/// re-exported with the reply.
public struct MarginReplyLink: Codable, Hashable, Sendable {
    public let conversationId: String
    public let parentPackageDigest: String
    public let parentPackageScopedId: String

    public init(conversationId: String, parentPackageDigest: String, parentPackageScopedId: String) {
        self.conversationId = conversationId
        self.parentPackageDigest = parentPackageDigest
        self.parentPackageScopedId = parentPackageScopedId
    }

    public var parent: MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: parentPackageDigest, packageScopedId: parentPackageScopedId)
    }

    /// A link for a new reply to `parent`. A reply to a reply stays in its parent's conversation;
    /// a reply to a Margin that starts one gets an id derived from that Margin, so two listeners
    /// who answer the same Margin independently land in the same conversation.
    public static func replying(to parent: MarginPacketIdentity, parentConversationId: String?) -> MarginReplyLink {
        MarginReplyLink(
            conversationId: parentConversationId ?? conversationId(rootedAt: parent),
            parentPackageDigest: parent.packageDigest,
            parentPackageScopedId: parent.packageScopedId
        )
    }

    public static func conversationId(rootedAt root: MarginPacketIdentity) -> String {
        let digest = SHA256.hash(data: Data("\(root.packageDigest)\n\(root.packageScopedId)".utf8))
        return "conversation-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension ImportedCommentaryInterjection {
    /// The link a reply to this imported Margin carries. `layer` is the layer it was imported with.
    public func replyLink(in layer: ImportedCommentaryLayer) -> MarginReplyLink {
        MarginReplyLink.replying(
            to: MarginPacketIdentity(packageDigest: layer.packageDigest, packageScopedId: packageScopedId),
            parentConversationId: replyLinks?.first?.conversationId
        )
    }
}

extension Interjection {
    /// Remembers that this Margin went out in a packet, so replies that come back find it.
    public func recordingShare(as identity: MarginPacketIdentity) -> Interjection {
        var copy = self
        if !(copy.sharedAs ?? []).contains(identity) {
            copy.sharedAs = (copy.sharedAs ?? []) + [identity]
        }
        return copy
    }
}

/// The packet artifact that carries reply links (#472). It is optional (`required: false`), so the
/// last shipped build skips it and imports the replies as ordinary Margins.
public struct MarginConversationArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.margin-conversation.v1"

    public struct Reply: Codable, Equatable, Hashable, Sendable {
        /// The reply's id in this packet's commentary layer.
        public let packageScopedId: String
        public let conversationId: String
        public let parentPackageDigest: String
        public let parentPackageScopedId: String

        public init(packageScopedId: String, link: MarginReplyLink) {
            self.packageScopedId = packageScopedId
            conversationId = link.conversationId
            parentPackageDigest = link.parentPackageDigest
            parentPackageScopedId = link.parentPackageScopedId
        }

        public var link: MarginReplyLink {
            MarginReplyLink(
                conversationId: conversationId,
                parentPackageDigest: parentPackageDigest,
                parentPackageScopedId: parentPackageScopedId
            )
        }
    }

    public let id: String
    public let schemaVersion: String
    public let replies: [Reply]

    public init(
        id: String = "margin-conversation",
        schemaVersion: String = MarginConversationArtifact.schemaVersion,
        replies: [Reply]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.replies = replies
    }

    /// Each reply's distinct links, in packet order. Repeated entries collapse to one; more than
    /// one distinct link is a fork, kept as is.
    public var linksByPackageScopedId: [String: [MarginReplyLink]] {
        var result: [String: [MarginReplyLink]] = [:]
        for reply in replies where !(result[reply.packageScopedId] ?? []).contains(reply.link) {
            result[reply.packageScopedId, default: []].append(reply.link)
        }
        return result
    }
}

/// A Margin in this listener's Library.
public enum MarginReference: Hashable, Sendable {
    case local(String)
    case imported(String)
}

public struct MarginReplyParent: Equatable, Sendable {
    public let link: MarginReplyLink
    /// The parent in this Library, or nil when the packet it was shared in hasn't been imported.
    public let parent: MarginReference?

    public init(link: MarginReplyLink, parent: MarginReference?) {
        self.link = link
        self.parent = parent
    }
}

public enum MarginReplyState: Equatable, Sendable {
    /// The parent is in this Library.
    case linked(MarginReplyParent)
    /// The parent's packet hasn't been imported yet. The link is kept, so the reply links as soon
    /// as it arrives, in whatever order the packets come.
    case parentMissing(MarginReplyLink)
    /// The packet names more than one parent for this reply. Each is resolved on its own.
    case fork([MarginReplyParent])
}

public struct MarginThreadEdge: Codable, Hashable, Sendable {
    public let reply: MarginPacketIdentity
    public let parent: MarginPacketIdentity

    public init(reply: MarginPacketIdentity, parent: MarginPacketIdentity) {
        self.reply = reply
        self.parent = parent
    }
}

/// Which Margins answer which, worked out from the saved links each time it's asked, so the result
/// doesn't depend on the order packets were imported in (#472).
public struct MarginReplyGraph: Equatable, Sendable {
    /// One state for every reply in the Library, local or imported.
    public let states: [MarginReference: MarginReplyState]
    /// The linked replies between shared Margins, by conversation id. Listeners who hold the same
    /// packets get the same threads.
    public let threads: [String: Set<MarginThreadEdge>]

    public static func build(
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer],
        importedMargins: [ImportedCommentaryInterjection]
    ) -> MarginReplyGraph {
        let liveLayers = Dictionary(
            layers.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nodesByIdentity: [MarginPacketIdentity: MarginReference] = [:]
        var importedIdentity: [String: MarginPacketIdentity] = [:]
        for margin in importedMargins {
            guard let layer = liveLayers[margin.layerId] else { continue }
            let identity = MarginPacketIdentity(packageDigest: layer.packageDigest, packageScopedId: margin.packageScopedId)
            importedIdentity[margin.id] = identity
            nodesByIdentity[identity] = .imported(margin.id)
        }
        // A listener's own Margin wins over a copy of it they imported back.
        for margin in localMargins {
            for identity in margin.sharedAs ?? [] { nodesByIdentity[identity] = .local(margin.id) }
        }

        var states: [MarginReference: MarginReplyState] = [:]
        var threads: [String: Set<MarginThreadEdge>] = [:]
        func resolve(_ reference: MarginReference, links: [MarginReplyLink], identities: [MarginPacketIdentity]) {
            let parents = links.map { link in
                MarginReplyParent(link: link, parent: nodesByIdentity[link.parent].flatMap { $0 == reference ? nil : $0 })
            }
            guard let first = parents.first else { return }
            if parents.count > 1 {
                states[reference] = .fork(parents)
            } else if first.parent != nil {
                states[reference] = .linked(first)
            } else {
                states[reference] = .parentMissing(first.link)
            }
            for parent in parents where parent.parent != nil {
                for identity in identities {
                    threads[parent.link.conversationId, default: []].insert(
                        MarginThreadEdge(reply: identity, parent: parent.link.parent)
                    )
                }
            }
        }
        for margin in importedMargins {
            guard let identity = importedIdentity[margin.id] else { continue }
            resolve(.imported(margin.id), links: margin.replyLinks ?? [], identities: [identity])
        }
        for margin in localMargins {
            resolve(.local(margin.id), links: margin.replyTo.map { [$0] } ?? [], identities: margin.sharedAs ?? [])
        }
        return MarginReplyGraph(states: states, threads: threads)
    }
}
