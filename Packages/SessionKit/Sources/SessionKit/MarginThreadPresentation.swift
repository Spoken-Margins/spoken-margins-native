import Foundation

/// How replies show under the Margin they answer (#473): the rows for the Margins list and the
/// Timeline detail, and what to play before a reply so a thread is heard as a conversation.
///
/// Built from `MarginReplyGraph` each time it's asked, so it follows whatever order packets
/// arrived in. A reply whose parent isn't in this Library is shown on its own and says so.
public enum MarginThreadPresentation {
    public static let missingParentNote = "reply to a Margin you don't have"

    public struct Row: Equatable, Sendable, Identifiable {
        public let reference: MarginReference
        /// 0 for a Margin that starts a thread (or a reply whose parent is missing), 1 for a reply to it, and so on.
        public let depth: Int
        public let senderLabel: String
        public let text: String
        public let createdAt: Date
        /// Source time in the listener's copy; nil when the Margin is not placed.
        public let timeMs: Int?
        /// Set on a reply whose parent isn't in this Library.
        public let note: String?
        /// The reply names more than one parent. It shows under the first one that is here.
        public let isFork: Bool

        public var id: String {
            switch reference {
            case .local(let id): return "local-\(id)"
            case .imported(let id): return "imported-\(id)"
            }
        }
    }

    /// The Margin a reply answers, for naming it before the reply plays.
    public struct ParentContext: Equatable, Sendable {
        public let parent: MarginReference
        public let senderLabel: String
        public let text: String

        public init(parent: MarginReference, senderLabel: String, text: String) {
            self.parent = parent
            self.senderLabel = senderLabel
            self.text = text
        }
    }

    /// Every active Margin of the item in thread order: threads by the time of their first Margin
    /// (unplaced last), then creation time; replies directly under their parent, oldest first.
    public static func rows(
        itemId: String,
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer],
        importedMargins: [ImportedCommentaryInterjection]
    ) -> [Row] {
        let graph = MarginReplyGraph.build(localMargins: localMargins, layers: layers, importedMargins: importedMargins)
        let nodes = self.nodes(itemId: itemId, localMargins: localMargins, layers: layers, importedMargins: importedMargins)

        var children: [MarginReference: [MarginReference]] = [:]
        var roots: [MarginReference] = []
        for node in nodes.values {
            switch graph.states[node.reference] {
            case .linked(let parent):
                if let target = parent.parent, nodes[target] != nil {
                    children[target, default: []].append(node.reference)
                } else {
                    roots.append(node.reference)
                }
            case .fork(let parents):
                if let target = parents.compactMap(\.parent).first(where: { nodes[$0] != nil }) {
                    children[target, default: []].append(node.reference)
                } else {
                    roots.append(node.reference)
                }
            case .parentMissing, nil:
                roots.append(node.reference)
            }
        }

        func before(_ a: MarginReference, _ b: MarginReference) -> Bool {
            guard let x = nodes[a], let y = nodes[b] else { return false }
            switch (x.timeMs, y.timeMs) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
            return x.sortKey < y.sortKey
        }
        func byCreation(_ a: MarginReference, _ b: MarginReference) -> Bool {
            guard let x = nodes[a], let y = nodes[b] else { return false }
            if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
            return x.sortKey < y.sortKey
        }

        var rows: [Row] = []
        var visited = Set<MarginReference>()
        func walk(_ reference: MarginReference, depth: Int) {
            guard visited.insert(reference).inserted, let node = nodes[reference] else { return }
            let state = graph.states[reference]
            var isFork = false
            if case .fork = state { isFork = true }
            let note = depth == 0 && state != nil ? missingParentNote : nil
            rows.append(Row(
                reference: reference, depth: depth, senderLabel: node.senderLabel, text: node.text,
                createdAt: node.createdAt, timeMs: node.timeMs, note: note, isFork: isFork
            ))
            for child in (children[reference] ?? []).sorted(by: byCreation) { walk(child, depth: depth + 1) }
        }
        for root in roots.sorted(by: before) { walk(root, depth: 0) }
        // A cycle (two packets each naming the other as parent) has no root; show those on their own.
        for reference in nodes.keys.sorted(by: before) where !visited.contains(reference) { walk(reference, depth: 0) }
        return rows
    }

    /// The Margin to name or play first when `reference` is a reply whose parent is in this Library.
    public static func parentContext(
        of reference: MarginReference,
        itemId: String,
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer],
        importedMargins: [ImportedCommentaryInterjection]
    ) -> ParentContext? {
        let graph = MarginReplyGraph.build(localMargins: localMargins, layers: layers, importedMargins: importedMargins)
        let nodes = self.nodes(itemId: itemId, localMargins: localMargins, layers: layers, importedMargins: importedMargins)
        let parent: MarginReference?
        switch graph.states[reference] {
        case .linked(let linked): parent = linked.parent
        case .fork(let parents): parent = parents.compactMap(\.parent).first(where: { nodes[$0] != nil })
        case .parentMissing, nil: parent = nil
        }
        guard let parent, let node = nodes[parent] else { return nil }
        return ParentContext(parent: parent, senderLabel: node.senderLabel, text: node.text)
    }

    private struct Node {
        let reference: MarginReference
        let senderLabel: String
        let text: String
        let createdAt: Date
        let timeMs: Int?
        var sortKey: String {
            switch reference {
            case .local(let id): return "local-\(id)"
            case .imported(let id): return "imported-\(id)"
            }
        }
    }

    private static func nodes(
        itemId: String,
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer],
        importedMargins: [ImportedCommentaryInterjection]
    ) -> [MarginReference: Node] {
        let liveLayers = Dictionary(
            layers.filter { $0.itemId == itemId && $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [MarginReference: Node] = [:]
        for margin in localMargins where margin.itemId == itemId && margin.status == "active" {
            let reference = MarginReference.local(margin.id)
            result[reference] = Node(
                reference: reference,
                senderLabel: MarginLayerSynthesis.ownSenderLabel,
                text: margin.displayText ?? margin.cleanedTranscript ?? margin.transcript ?? "",
                createdAt: margin.createdAt,
                timeMs: margin.anchor.mediaTimeMs.flatMap { $0 >= 0 ? $0 : nil }
            )
        }
        for margin in importedMargins {
            guard let layer = liveLayers[margin.layerId] else { continue }
            let reference = MarginReference.imported(margin.id)
            result[reference] = Node(
                reference: reference,
                senderLabel: MarginLayerSynthesis.label(layer.displayLabel),
                text: margin.approvedTranscript,
                createdAt: margin.createdAt,
                timeMs: MarginLayerSynthesis.placedTime(margin.resolution)
            )
        }
        return result
    }
}

extension Interjection {
    /// This Margin as a reply to a Margin shared in `layer`'s packet. Only the link is set; the
    /// position and audio are whatever the normal recorder saved.
    public func answering(_ parent: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Interjection {
        var copy = self
        copy.replyTo = parent.replyLink(in: layer)
        return copy
    }
}
