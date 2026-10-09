/// Shared Margins that were crossed together (a 500 ms tick can cross several, from one layer or
/// from several friends) and are waiting their turn. Only one is offered at a time; the rest wait
/// here and are offered, in listening order, once the one before has been heard or dismissed (#918).
public struct SharedMarginOfferQueue: Equatable {
    public private(set) var waitingIDs: [String] = []

    public init() {}

    public var isEmpty: Bool { waitingIDs.isEmpty }

    /// Adds crossed prompts behind any already waiting. A Margin already waiting is not added twice.
    public mutating func append(_ prompts: [ImportedCommentaryPrompt]) {
        for prompt in prompts where !waitingIDs.contains(prompt.id) {
            waitingIDs.append(prompt.id)
        }
    }

    /// The next waiting Margin that can still be offered. `offerable` is the current list of
    /// prompts the listener may be offered (deleted, disabled or replaced Margins are absent),
    /// so one that went away while waiting is dropped instead of offered.
    public mutating func next(from offerable: [ImportedCommentaryPrompt]) -> ImportedCommentaryPrompt? {
        while !waitingIDs.isEmpty {
            let id = waitingIDs.removeFirst()
            if let prompt = offerable.first(where: { $0.id == id }) { return prompt }
        }
        return nil
    }

    /// One tick's decision: queue what just crossed (Margins in `fresh` reveal mode are never
    /// offered), then return the Margin to offer now, if any. `announced` is the current prompt
    /// list including ones already announced, since a waiting Margin was announced when it crossed.
    public mutating func nextOffer(
        crossed: [ImportedCommentaryPrompt],
        announced: [ImportedCommentaryPrompt]
    ) -> ImportedCommentaryPrompt? {
        append(crossed.filter { $0.layer.revealMode != .fresh })
        return next(from: announced.filter { $0.layer.revealMode != .fresh })
    }

    public mutating func removeAll() {
        waitingIDs.removeAll()
    }
}
