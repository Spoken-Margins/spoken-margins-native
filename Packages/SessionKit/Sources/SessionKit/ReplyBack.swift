import Foundation

/// Sending replies back (#3221, step 6-8 of the sharing loop #3216). After a listener has heard a friend's Margins and
/// answered some, the Share action offers "Send replies to <friend>": the replies are chosen, the listener's other new
/// Margins on the item are offered unselected, and nothing the friend sent goes back. The packet itself is the ordinary
/// one; a reply already carries its link to the parent (#472), so Builds 32 and 34 import it as before.
public struct ReplyBackOffer: Equatable, Sendable {
    /// The listener's replies to a friend's Margins: pre-selected.
    public let replies: [Interjection]
    /// The listener's other Margins made since they imported a friend's packet: offered, and selected only when there is
    /// no linked reply (`isPreselected`).
    public let others: [Interjection]
    /// Whose Margins the replies answer, in the order the replies come; with no replies, every friend on the item.
    public let friendLabels: [String]

    public var friendName: String { ReplyBackOffer.names(friendLabels) }
    public var title: String { "Send replies to \(friendName)" }
    /// Every Margin the share sheet lists, in the order they were made.
    public var candidates: [Interjection] { (replies + others).sorted(by: ReplyBackOffer.madeBefore) }
    /// Whether the sheet starts with this Margin included. With linked replies, those and only those (#3221). With none,
    /// the ordinary Share's own rule: the Margins starred for sharing if any candidate is starred, otherwise every
    /// candidate, so the sheet never opens with nothing picked (#3792, Design 2026-11-10, piece 2).
    public func isPreselected(_ interjection: Interjection) -> Bool {
        if !replies.isEmpty { return replyIds.contains(interjection.id) }
        let anyStarred = others.contains { $0.isStarredForSharing == true }
        return !anyStarred || interjection.isStarredForSharing == true
    }

    private var replyIds: Set<String> { Set(replies.map(\.id)) }

    /// The offer for an item, or nil when the listener has made no Margin since they imported a friend's packet.
    ///
    /// `localMargins` are the listener's own. A friend's Margins live in the imported layers, never in that list, so
    /// nothing the friend sent is offered. A friend's packet is a live (not deleted) imported layer.
    public static func make(
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer]
    ) -> ReplyBackOffer? {
        let liveLayers = layers.filter { $0.deletedAt == nil }
        guard let firstImport = liveLayers.map(\.importedAt).min() else { return nil }
        let layerByDigest = Dictionary(liveLayers.map { ($0.packageDigest, $0) }, uniquingKeysWith: { first, _ in first })

        var replies: [Interjection] = []
        var others: [Interjection] = []
        var answered: [ImportedCommentaryLayer] = []
        for margin in localMargins.sorted(by: madeBefore)
        // `sharedAs` is written when the packet file is built, before anything leaves the phone, so it can't tell a
        // reply that was sent from one whose Share sheet was cancelled. A reply stays on offer.
        where margin.status == "active" && margin.targetType == .item {
            if let link = margin.replyTo, let layer = layerByDigest[link.parentPackageDigest] {
                replies.append(margin)
                if !answered.contains(where: { $0.id == layer.id }) { answered.append(layer) }
            } else if margin.createdAt >= firstImport {
                others.append(margin)
            }
        }
        guard !replies.isEmpty || !others.isEmpty else { return nil }
        let friends = answered.isEmpty ? liveLayers.sorted { $0.importedAt < $1.importedAt } : answered
        var labels: [String] = []
        for layer in friends {
            // A friend with no name is "your friend", not "Imported collection".
            if let label = SharedPacketArrival.senderName(layer.displayLabel), !labels.contains(label) { labels.append(label) }
        }
        return ReplyBackOffer(replies: replies, others: others, friendLabels: labels)
    }

    private static func madeBefore(_ lhs: Interjection, _ rhs: Interjection) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }

    static func names(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return "your friend"
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default: return "\(labels[0]), \(labels[1]) and \(labels.count - 2) other\(labels.count == 3 ? "" : "s")"
        }
    }
}

extension SharedMarginReview {
    /// What a friend's reply answers, for "Reply to your Margin at 12:34" (#3221).
    public struct ReplyContext: Sendable, Equatable {
        public enum Parent: Sendable, Equatable {
            /// The listener's own Margin: the common case, when a friend answers what was sent to them.
            case yours(interjectionId: String, mediaTimeMs: Int?)
            /// Another shared Margin in this Library.
            case shared(marginId: String, label: String, mediaTimeMs: Int?)
            /// The parent's packet isn't in this Library (yet).
            case missing
        }

        public let parent: Parent

        /// The id of the listener's own Margin this answers, when the parent is theirs: the one test for "a reply to
        /// you", shared by the item screen's words (#3889) and anything else that counts replies.
        public var yoursParentId: String? {
            if case .yours(let id, _) = parent { return id }
            return nil
        }

        public var caption: String {
            switch parent {
            case .yours(_, let ms): return "Reply to your Margin" + Self.at(ms)
            case .shared(_, let label, let ms):
                let whose = SharedPacketArrival.senderName(label).map { "\($0)'s" } ?? "a friend's"
                return "Reply to \(whose) Margin" + Self.at(ms)
            case .missing: return "Reply to a Margin that isn't on this phone"
            }
        }

        /// "12:34", or "1:02:03" past the hour.
        public static func clock(_ ms: Int) -> String {
            let seconds = max(0, ms) / 1_000
            return seconds >= 3_600
                ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        private static func at(_ ms: Int?) -> String { ms.map { " at \(clock($0))" } ?? "" }
    }

    /// One thing the review plays: a friend's Margin, or the listener's own Margin that a reply answers.
    public struct Step: Sendable, Equatable {
        public let anchor: MarginMomentAnchor
        /// The friend's Margin, nil for a parent step.
        public let entry: Entry?
        /// The listener's own Margin, played first so the reply is heard in context. Nil for a friend's Margin.
        public let ownParent: Interjection?
    }

    /// The review's steps: each reply to one of the listener's own spoken Margins is preceded by that Margin, so the
    /// order is the lead-in, the parent, then the reply (default taken on #3221). A parent plays once, before the first
    /// reply to it, and sits at the reply's place so the review makes no extra hop. A parent with no saved voice (a
    /// written Margin) can't be played and is left out.
    ///
    /// A reply placed only by a clock or a map (`isApproximate`) is the exception (#3611): the friend's clock can be
    /// off by the ad difference between two copies of an episode, while the listener's own Margin sits at its exact
    /// place on this copy. The parent then keeps its own place, exact, and the reply follows it there (still marked
    /// approximate: how far after the parent the friend spoke isn't known).
    public static func playlist(for entries: [Entry], ownMargins: [Interjection]) -> [Step] {
        let own = Dictionary(ownMargins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parentPlaces: [String: Int] = [:]  // where each played parent's step sits, for its later replies
        var steps: [Step] = []
        for entry in entries {
            var replyAnchor = entry.anchor
            if case .yours(let id, let ms)? = entry.replyContext?.parent, let parent = own[id], parent.isSpokenItemMargin {
                // A guessed reply goes where its parent plays: the parent's own place on this copy, or where an earlier
                // reply already put the parent's step.
                let place = parentPlaces[id] ?? (entry.isApproximate ? parent.anchor.mediaTimeMs : nil)
                if parentPlaces[id] == nil {
                    let caption = "Your Margin" + (ms.map { " at \(ReplyContext.clock($0))" } ?? "")
                    let at = place ?? entry.mediaTimeMs
                    parentPlaces[id] = at
                    steps.append(Step(
                        anchor: MarginMomentAnchor(
                            marginId: parentMarginId(id), mediaTimeMs: at,
                            isApproximate: place == nil && entry.isApproximate, caption: caption, isYours: true
                        ),
                        entry: nil, ownParent: parent
                    ))
                }
                if entry.isApproximate, let place = parentPlaces[id] {
                    replyAnchor = MarginMomentAnchor(
                        marginId: entry.marginId, mediaTimeMs: place, label: entry.senderLabel, isApproximate: true,
                        caption: entry.replyContext?.caption, isReadAloud: entry.interjection.isWritten
                    )
                }
            }
            steps.append(Step(anchor: replyAnchor, entry: entry, ownParent: nil))
        }
        // `entries` are in the friends' clock order; a step moved to its parent's place may now be out of order, and
        // the sequence plays a step that isn't ahead of the last one at once, with no lead-in. Stable, so a parent
        // stays directly before its reply.
        return steps.enumerated()
            .sorted { ($0.element.anchor.mediaTimeMs, $0.offset) < ($1.element.anchor.mediaTimeMs, $1.offset) }
            .map(\.element)
    }

    /// The Margins whose arrival is announced with the chime: the first Margin of each stretch the listener hears,
    /// so a reply that follows its parent isn't announced a second time. A muted layer's Margins stay silent (#932).
    public static func chimedMarginIds(_ steps: [Step]) -> Set<String> {
        var chimed = Set<String>()
        for (index, step) in steps.enumerated() {
            if step.ownParent != nil {
                // The parent plays for the reply after it, so the reply's layer decides.
                if index + 1 < steps.count, steps[index + 1].entry?.layer.isMuted == false { chimed.insert(step.anchor.marginId) }
            } else if let entry = step.entry, !entry.layer.isMuted, index == 0 || steps[index - 1].ownParent == nil {
                chimed.insert(step.anchor.marginId)
            }
        }
        return chimed
    }

    /// The identity a review gives the listener's own Margin when it plays it ahead of a reply.
    public static func parentMarginId(_ interjectionId: String) -> String { "reply-parent::\(interjectionId)" }

    /// The context of each reply among the layers' Margins, by the Margin's id. Worked out from the saved links
    /// (`MarginReplyGraph`), so it doesn't depend on the order the packets were imported in.
    static func replyContexts(
        layers: [ImportedCommentaryLayer],
        records: [String: [ImportedCommentaryInterjection]],
        ownMargins: [Interjection]
    ) -> [String: ReplyContext] {
        let all = layers.flatMap { records[$0.id] ?? [] }
        guard all.contains(where: { !($0.replyLinks ?? []).isEmpty }) else { return [:] }
        let graph = MarginReplyGraph.build(localMargins: ownMargins, layers: layers, importedMargins: all)
        let own = Dictionary(ownMargins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let layerById = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let importedById = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func context(_ parent: MarginReplyParent) -> ReplyContext {
            switch parent.parent {
            case .local(let id)?:
                return ReplyContext(parent: .yours(interjectionId: id, mediaTimeMs: own[id]?.anchor.mediaTimeMs))
            case .imported(let id)?:
                guard let margin = importedById[id], let layer = layerById[margin.layerId] else { return ReplyContext(parent: .missing) }
                return ReplyContext(parent: .shared(
                    marginId: marginId(layerId: layer.id, interjectionId: margin.id),
                    label: senderLabel(of: layer), mediaTimeMs: margin.resolution.localMediaTimeMs
                ))
            case nil:
                return ReplyContext(parent: .missing)
            }
        }
        var result: [String: ReplyContext] = [:]
        for margin in all {
            switch graph.states[.imported(margin.id)] {
            case .linked(let parent)?: result[margin.id] = context(parent)
            case .fork(let parents)?:
                // A reply that names several parents: the first one that is in this Library.
                result[margin.id] = parents.first { $0.parent != nil }.map(context) ?? ReplyContext(parent: .missing)
            case .parentMissing?: result[margin.id] = ReplyContext(parent: .missing)
            case nil: break
            }
        }
        return result
    }
}
