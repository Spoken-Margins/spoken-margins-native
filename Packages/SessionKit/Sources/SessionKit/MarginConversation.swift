import Foundation

public struct MarginReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var contributionID: String
    public var revisionID: String
    public var id: String { contributionID + "/" + revisionID }
    public init(contributionID: String, revisionID: String) {
        self.contributionID = contributionID; self.revisionID = revisionID
    }
}

/// Listening guidance, never a replacement for source-identification evidence.
public struct MarginListeningContext: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case sourceText, sourceMedia, parent }
    public var kind: Kind
    public var start: Int
    public var end: Int
    public var quote: String?
    public init(kind: Kind, start: Int, end: Int, quote: String? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.quote = quote
    }
}

public struct MarginConversation: Codable, Equatable, Sendable {
    public static let capability = "spoken-margins.conversation.v1"
    public var reference: MarginReference
    public var authorID: String
    public var authorLabel: String
    public var parent: MarginReference?
    public var context: MarginListeningContext?
    public init(reference: MarginReference, authorID: String, authorLabel: String,
                parent: MarginReference? = nil, context: MarginListeningContext? = nil) {
        self.reference = reference; self.authorID = authorID; self.authorLabel = authorLabel
        self.parent = parent; self.context = context
    }
}

/// Immutable content of the exact revision a reply refers to. Paths are local;
/// identity and equality use the audio digest, never container-specific paths.
public struct MarginConversationSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { conversation.reference.id }
    public let itemID: String
    public let conversation: MarginConversation
    public let anchor: PortableAnchorEvidence
    public let transcript: String
    public let audioPath: String?
    public let audioSHA256: String?
    public let audioDurationMs: Int?
    public let createdAt: Date
    public init(itemID: String, conversation: MarginConversation, anchor: PortableAnchorEvidence,
                transcript: String, audioPath: String? = nil, audioSHA256: String? = nil,
                audioDurationMs: Int? = nil, createdAt: Date) {
        self.itemID = itemID; self.conversation = conversation; self.anchor = anchor
        self.transcript = transcript; self.audioPath = audioPath; self.audioSHA256 = audioSHA256
        self.audioDurationMs = audioDurationMs; self.createdAt = createdAt
    }
    public func hasSameContent(as other: Self) -> Bool {
        conversation == other.conversation && anchor.withoutMachineEvidence == other.anchor.withoutMachineEvidence && transcript == other.transcript
            && audioSHA256 == other.audioSHA256 && audioDurationMs == other.audioDurationMs
    }
}

public enum MarginConversationGraph {
    /// Missing ancestors are legitimate when packets arrive out of order.
    /// Contradictory revisions and cycles are rejected before any import writes.
    public static func merge(_ existing: [MarginConversationSnapshot], _ incoming: [MarginConversationSnapshot]) throws -> [MarginConversationSnapshot] {
        var nodes: [String: MarginConversationSnapshot] = [:]
        for node in existing + incoming {
            try validate(node.conversation)
            if let old = nodes[node.id], !old.hasSameContent(as: node) {
                throw SessionKitError.persistenceFailed("conversation_revision_conflict")
            }
            if nodes[node.id] == nil { nodes[node.id] = node }
        }
        for node in nodes.values {
            var path: Set<String> = []
            var current: MarginConversationSnapshot? = node
            while let value = current {
                guard path.insert(value.id).inserted else {
                    throw SessionKitError.persistenceFailed("conversation_reply_cycle")
                }
                current = value.conversation.parent.flatMap { nodes[$0.id] }
            }
        }
        return nodes.values.sorted { $0.id < $1.id }
    }

    public static func validate(_ value: MarginConversation) throws {
        func identifier(_ id: String) -> Bool {
            !id.isEmpty && id.count <= 200 && id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").contains($0) || "-_.:".unicodeScalars.contains($0)
            }
        }
        guard identifier(value.reference.contributionID), identifier(value.reference.revisionID),
              identifier(value.authorID), value.authorLabel.count <= 200,
              value.parent.map({ identifier($0.contributionID) && identifier($0.revisionID)
                  && $0.contributionID != value.reference.contributionID }) ?? true else {
            throw SessionKitError.persistenceFailed("invalid_conversation_identity")
        }
        if let context = value.context {
            guard context.start >= 0, context.end >= context.start,
                  context.end <= 1_000_000_000, (context.quote?.count ?? 0) <= 20_000,
                  context.kind != .parent || value.parent != nil else {
                throw SessionKitError.persistenceFailed("invalid_conversation_context")
            }
        }
    }

    public static func ancestors(of reference: MarginReference, in nodes: [MarginConversationSnapshot]) -> [MarginConversationSnapshot] {
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [MarginConversationSnapshot] = [], visited: Set<String> = []
        var current = lookup[reference.id]
        while let node = current, visited.insert(node.id).inserted {
            result.append(node)
            current = node.conversation.parent.flatMap { lookup[$0.id] }
        }
        return result.reversed()
    }
}

extension ImportedCommentaryInterjection {
    public func conversationSnapshot(itemID: String) -> MarginConversationSnapshot? {
        conversation.map {
            MarginConversationSnapshot(itemID: itemID, conversation: $0, anchor: anchorEvidence,
                transcript: approvedTranscript, audioPath: audioPath, audioSHA256: conversationAudioSHA256,
                audioDurationMs: audioDurationMs, createdAt: createdAt)
        }
    }
}

extension PortableAnchorEvidence {
    /// Machine evidence assets are optional transport attachments, not a change
    /// to the author's contribution when omitted on a later share.
    public var withoutMachineEvidence: Self {
        .init(anchorType: anchorType, startChar: startChar, endChar: endChar, exactText: exactText,
            prefix: prefix, suffix: suffix, mediaTimeMs: mediaTimeMs, roughPercent: roughPercent,
            transcriptSegmentId: transcriptSegmentId, chapterTitle: chapterTitle)
    }
}
