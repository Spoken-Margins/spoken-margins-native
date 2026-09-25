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
    public static let multipleTargetsCapability = "spoken-margins.conversation.v2"
    public var reference: MarginReference
    public var authorID: String
    public var authorLabel: String
    private var parentReferences: [MarginReference]
    public var parents: [MarginReference] {
        get { parentReferences }
        set { parentReferences = newValue }
    }
    /// Source compatibility for the original one-parent capture flow.
    public var parent: MarginReference? {
        get { parentReferences.first }
        set { parentReferences = newValue.map { [$0] } ?? [] }
    }
    public var context: MarginListeningContext?
    public init(reference: MarginReference, authorID: String, authorLabel: String,
                parent: MarginReference? = nil, context: MarginListeningContext? = nil) {
        self.reference = reference; self.authorID = authorID; self.authorLabel = authorLabel
        self.parentReferences = parent.map { [$0] } ?? []; self.context = context
    }
    public init(reference: MarginReference, authorID: String, authorLabel: String,
                parents: [MarginReference], context: MarginListeningContext? = nil) {
        self.reference = reference; self.authorID = authorID; self.authorLabel = authorLabel
        self.parentReferences = parents; self.context = context
    }

    private enum CodingKeys: String, CodingKey { case reference, authorID, authorLabel, parent, parents, context }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reference = try values.decode(MarginReference.self, forKey: .reference)
        authorID = try values.decode(String.self, forKey: .authorID)
        authorLabel = try values.decode(String.self, forKey: .authorLabel)
        context = try values.decodeIfPresent(MarginListeningContext.self, forKey: .context)
        guard !values.contains(.parent) || !values.contains(.parents) else {
            throw DecodingError.dataCorruptedError(forKey: .parents, in: values, debugDescription: "parent and parents cannot coexist")
        }
        parentReferences = values.contains(.parents)
            ? try values.decode([MarginReference].self, forKey: .parents)
            : try values.decodeIfPresent(MarginReference.self, forKey: .parent).map { [$0] } ?? []
        if values.contains(.parents), parentReferences.count < 2 || parentReferences.count > 4 {
            throw DecodingError.dataCorruptedError(forKey: .parents, in: values, debugDescription: "parents must contain two to four references")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reference, forKey: .reference)
        try values.encode(authorID, forKey: .authorID)
        try values.encode(authorLabel, forKey: .authorLabel)
        if parentReferences.count > 1 { try values.encode(parentReferences, forKey: .parents) }
        else { try values.encodeIfPresent(parentReferences.first, forKey: .parent) }
        try values.encodeIfPresent(context, forKey: .context)
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
        var finished: Set<String> = []
        func visit(_ node: MarginConversationSnapshot, path: inout Set<String>) throws {
            guard !finished.contains(node.id) else { return }
            guard path.insert(node.id).inserted else { throw SessionKitError.persistenceFailed("conversation_reply_cycle") }
            for reference in node.conversation.parents {
                guard let parent = nodes[reference.id] else { continue }
                guard node.itemID.isEmpty || parent.itemID.isEmpty || node.itemID == parent.itemID else {
                    throw SessionKitError.persistenceFailed("conversation_cross_item_reply")
                }
                try visit(parent, path: &path)
            }
            path.remove(node.id)
            finished.insert(node.id)
        }
        for node in nodes.values { var path: Set<String> = []; try visit(node, path: &path) }
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
              value.parents.count <= 4,
              Set(value.parents).count == value.parents.count,
              value.parents.allSatisfy({ identifier($0.contributionID) && identifier($0.revisionID)
                  && $0.contributionID != value.reference.contributionID }) else {
            throw SessionKitError.persistenceFailed("invalid_conversation_identity")
        }
        if let context = value.context {
            guard context.start >= 0, context.end >= context.start,
                  context.end <= 1_000_000_000, (context.quote?.count ?? 0) <= 20_000,
                  context.kind != .parent || !value.parents.isEmpty else {
                throw SessionKitError.persistenceFailed("invalid_conversation_context")
            }
        }
    }

    public static func ancestors(of reference: MarginReference, in nodes: [MarginConversationSnapshot]) -> [MarginConversationSnapshot] {
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [MarginConversationSnapshot] = [], visited: Set<String> = []
        func append(_ reference: MarginReference) {
            guard let node = lookup[reference.id], visited.insert(node.id).inserted else { return }
            for parent in node.conversation.parents { append(parent) }
            result.append(node)
        }
        append(reference)
        return result
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
