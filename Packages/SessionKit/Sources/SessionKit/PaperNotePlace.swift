import Foundation

/// Where a Paper note answer written after the fact sits in the paper (#4340).
///
/// The Write sheet offers three places: where the listener is, the start of the paper, and the start of a page they
/// pick. This turns the choice into a character offset into the item's text, the unit `Anchor.startChar` uses, for
/// `SessionEngine.addWrittenInterjection`. Pure functions over the item, its structured document and its sessions,
/// so host tests can check every fact without a player.
public enum PaperNotePlace {
    public enum Choice: Equatable, Sendable {
        /// The place Continue would resume, or the last sentence when the paper was heard to its end.
        case whereYouAre
        /// The first sentence of the paper.
        case startOfPaper
        /// The first text of this page. One-based, the number a reader cites ("p. 4"): `Segment.pageIndex + 1`.
        case startOfPage(Int)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The item has no text to place an answer in.
        case noText
        /// "Where you are" needs a listening session, and the listener has not started this paper.
        case noSession
        /// The page is not one of the paper's pages, or the document has no text on it or after it (so a last page
        /// with no text of its own is refused).
        case noSuchPage(Int)
        /// The session is playing a generated answer or summary, whose saved place counts characters of that
        /// turn, not of the paper. The caller offers the other two places.
        case placeNotInPaper
    }

    /// The session "Where you are" reads: the one Continue would resume, by the same rules as Play. An item added
    /// again leaves out the listening that finished before it (#4183). Nil when the paper was never started.
    public static func session(addedAgainAt: Date?, sessions: [Session]) -> Session? {
        SessionContinuation.preferredContinuationSession(
            in: ItemFinishedRule.continuationSessions(addedAgainAt: addedAgainAt, sessions: sessions)
        )
    }

    /// The character offset where an answer for `choice` starts.
    ///
    /// - `whereYouAre`: the session's saved place. A session at 99% or more (`ItemFinishedRule.listenedPercent`), or
    ///   one whose place is at the end of the text, gives the last sentence: the end itself is not a sentence an
    ///   answer can sit on. A paper the listener marked finished part way still has its own place, so it gives that.
    /// - `startOfPaper`: the first sentence, past any leading white space.
    /// - `startOfPage(n)`: the start of the first segment that begins on page `n`, leaving out page headers and
    ///   footers. A page with no text of its own (a full-page figure) gives the first text after it.
    public static func resolve(item: Item, document: StructuredDocument?, session: Session?, choice: Choice) throws -> Int {
        guard let text = item.text, !text.isEmpty else { throw Failure.noText }
        let characters = Array(text)
        let sentences = SentenceBounds.ranges(in: characters)
        switch choice {
        case .startOfPaper:
            return sentences.first?.lowerBound ?? 0
        case .whereYouAre:
            guard let session else { throw Failure.noSession }
            guard session.currentTargetType != .assistantTurnTTS, session.currentTargetType != .summaryTurnTTS else {
                throw Failure.placeNotInPaper
            }
            let place = max(0, session.position.charOffset)
            if session.completionPercent >= ItemFinishedRule.listenedPercent || place >= characters.count {
                return sentences.last?.lowerBound ?? 0
            }
            return place
        case .startOfPage(let page):
            guard page >= 1, let document else { throw Failure.noSuchPage(page) }
            let wanted = page - 1
            let first = document.segments
                .filter { segment in
                    guard let pageIndex = segment.pageIndex, pageIndex >= wanted else { return false }
                    return segment.role != .pageHeader && segment.role != .pageFooter
                        && segment.range.length > 0 && segment.range.start < characters.count
                }
                .min { lhs, rhs in
                    // The earliest page first, then the earliest text on it.
                    (lhs.pageIndex ?? 0, lhs.range.start) < (rhs.pageIndex ?? 0, rhs.range.start)
                }
            guard let first else { throw Failure.noSuchPage(page) }
            var start = max(0, first.range.start)
            while start < characters.count - 1, characters[start].isWhitespace { start += 1 }
            return start
        }
    }
}
